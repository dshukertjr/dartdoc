// Copyright (c) 2022, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';
import 'dart:html';
import 'dart:js_util' as js_util;

final String _htmlBase = () {
  final body = document.querySelector('body')!;

  // If dartdoc did not add a base-href tag, we will need to add the relative
  // path ourselves.
  if (body.attributes['data-using-base-href'] == 'false') {
    // Dartdoc stores the htmlBase in 'body[data-base-href]'.
    return body.attributes['data-base-href'] ?? '';
  } else {
    return '';
  }
}();

void init() {
  var searchBox = document.getElementById('search-box') as InputElement?;
  var searchBody = document.getElementById('search-body') as InputElement?;
  var searchSidebar =
      document.getElementById('search-sidebar') as InputElement?;

  void disableSearch() {
    print('Could not activate search functionality.');

    searchBox?.placeholder = 'Failed to initialize search';
    searchBody?.placeholder = 'Failed to initialize search';
    searchSidebar?.placeholder = 'Failed to initialize search';
  }

  window.fetch('${_htmlBase}index.json').then((response) async {
    int code = js_util.getProperty(response, 'status');
    if (code == 404) {
      disableSearch();
      return;
    }

    var textPromise = js_util.callMethod<Object>(response, 'text', []);
    var text = await promiseToFuture<String>(textPromise);
    var jsonIndex = (jsonDecode(text) as List).cast<Map<String, dynamic>>();
    final index = jsonIndex.map(_IndexItem.fromMap).toList();

    // Navigate to the first result from the 'search' query parameter
    // if specified and found.
    final url = Uri.parse(window.location.toString());
    final search = url.queryParameters['search'];
    if (search != null) {
      final matches = _findMatches(index, search);
      if (matches.isNotEmpty) {
        final href = matches.first.href;
        if (href != null) {
          window.location.assign('$_htmlBase$href');
          return;
        }
      }
    }

    // Initialize all three search fields.
    if (searchBox != null) {
      _initializeSearch(searchBox, index);
    }
    if (searchBody != null) {
      _initializeSearch(searchBody, index);
    }
    if (searchSidebar != null) {
      _initializeSearch(searchSidebar, index);
    }
  });
}

const _weights = {
  'library': 2,
  'class': 2,
  'mixin': 3,
  'extension': 3,
  'typedef': 3,
  'method': 4,
  'accessor': 4,
  'operator': 4,
  'constant': 4,
  'property': 4,
  'constructor': 4,
};

List<_IndexItem> _findMatches(List<_IndexItem> index, String query) {
  if (query.isEmpty) {
    return [];
  }

  var allMatches = <_SearchMatch>[];

  for (var element in index) {
    void score(int value) {
      value -= (element.overriddenDepth ?? 0) * 10;
      var weightFactor = _weights[element.type] ?? 4;
      allMatches.add(_SearchMatch(element, value / weightFactor));
    }

    var name = element.name;
    var qualifiedName = element.qualifiedName;
    var lowerName = name.toLowerCase();
    var lowerQualifiedName = qualifiedName.toLowerCase();
    var lowerQuery = query.toLowerCase();

    if (name == query || qualifiedName == query || name == 'dart:$query') {
      score(2000);
    } else if (lowerName == 'dart:$lowerQuery') {
      score(1800);
    } else if (lowerName == lowerQuery || lowerQualifiedName == lowerQuery) {
      score(1700);
    } else if (query.length > 1) {
      if (name.startsWith(query) || qualifiedName.startsWith(query)) {
        score(750);
      } else if (lowerName.startsWith(lowerQuery) ||
          lowerQualifiedName.startsWith(lowerQuery)) {
        score(650);
      } else if (name.contains(query) || qualifiedName.contains(query)) {
        score(500);
      } else if (lowerName.contains(lowerQuery) ||
          lowerQualifiedName.contains(query)) {
        score(400);
      }
    }
  }

  allMatches.sort((_SearchMatch a, _SearchMatch b) {
    var x = (b.score - a.score).round();
    if (x == 0) {
      return a.element.name.length - b.element.name.length;
    }
    return x;
  });

  return allMatches.map((match) => match.element).toList();
}

const _minLength = 1;
int _suggestionLimit = 10;
int _suggestionLength = 0;
const _htmlEscape = HtmlEscape();

final _containerMap = <String, Element>{};

// TODO(srawlins): Break up this huge function into smaller parts. One big trick
// here is maintaining how `selectedElement` is used. I suspect a class with
// fields maintaining state would be a good solution. Another big trick is
// testing. Perhaps testing should be added first :(.
void _initializeSearch(
  InputElement input,
  List<_IndexItem> index,
) {
  final uri = Uri.parse(window.location.href);

  input.disabled = false;
  input.setAttribute('placeholder', 'Search API Docs');
  // Handle grabbing focus when the users types / outside of the input
  document.addEventListener('keydown', (Event event) {
    if (event is! KeyboardEvent) {
      return;
    }
    if (event.key == '/' && document.activeElement is! InputElement) {
      event.preventDefault();
      input.focus();
    }
  });

  // Prepare elements.
  var wrapper = document.createElement('div');
  wrapper.classes.add('tt-wrapper');
  input.replaceWith(wrapper);

  input.setAttribute('autocomplete', 'off');
  input.setAttribute('spellcheck', 'false');
  input.classes.add('tt-input');

  wrapper.append(input);

  var listBox = document.createElement('div');
  listBox.setAttribute('role', 'listbox');
  listBox.setAttribute('aria-expanded', 'false');
  listBox.style.display = 'none';
  listBox.classes.add('tt-menu');

  // Element use in listbox to inform the functionality of hitting enter in search box.
  var moreResults = document.createElement('div');
  moreResults.classes.add('enter-search-message');
  listBox.append(moreResults);

  // Element that contains the search suggestions in a new format.
  var searchResults = document.createElement('div');
  searchResults.classes.add('tt-search-results');
  listBox.append(searchResults);

  wrapper.append(listBox);

  String? storedValue;
  var actualValue = '';

  final suggestionElements = <Element>[];
  var suggestionsInfo = <_IndexItem>[];
  int? selectedElement;

  void showSuggestions() {
    if (searchResults.hasChildNodes()) {
      listBox.style.display = 'block';
      listBox.setAttribute('aria-expanded', 'true');
    }
  }

  /// Creates the content displayed in the main-content element, for the search
  /// results page.
  void showSearchResultPage(String searchText) {
    final mainContent = document.getElementById('dartdoc-main-content');

    if (mainContent == null) {
      return;
    }

    mainContent
      ..text = ''
      ..append(document.createElement('section')..classes.add('search-summary'))
      ..append(document.createElement('h2')..innerHtml = 'Search Results')
      ..append(document.createElement('div')
        ..classes.add('search-summary')
        ..innerHtml = '$_suggestionLength results for "$searchText"');

    if (_containerMap.isNotEmpty) {
      for (final element in _containerMap.values) {
        mainContent.append(element);
      }
    } else {
      var noResults = document.createElement('div')
        ..classes.add('search-summary')
        ..innerHtml =
            'There was not a match for "$searchText". Want to try searching '
                'from additional Dart-related sites? ';

      var buildLink = Uri.parse(
              'https://dart.dev/search?cx=011220921317074318178%3A_yy-tmb5t_i&ie=UTF-8&hl=en&q=')
          .replace(queryParameters: {'q': searchText});
      var link = document.createElement('a')
        ..setAttribute('href', buildLink.toString())
        ..classes.add('seach-options')
        ..text = 'Search on dart.dev.';
      noResults.append(link);
      mainContent.append(noResults);
    }
  }

  void hideSuggestions() {
    listBox.style.display = 'none';
    listBox.setAttribute('aria-expanded', 'false');
  }

  void showEnterMessage() {
    moreResults.text = _suggestionLength > 10
        ? 'Press "Enter" key to see all $_suggestionLength results'
        : '';
  }

  void updateSuggestions(String query, List<_IndexItem> suggestions) {
    suggestionsInfo = [];
    suggestionElements.clear();
    _containerMap.clear();
    searchResults.text = '';

    if (suggestions.length < _minLength) {
      hideSuggestions();
      return;
    }

    for (final suggestion in suggestions) {
      suggestionElements.add(_createSuggestion(query, suggestion));
    }

    for (final element in _containerMap.values) {
      searchResults.append(element);
    }
    suggestionsInfo = suggestions;

    selectedElement = null;

    showSuggestions();
    showEnterMessage();
  }

  /// Handles [searchText] by generating suggestions.
  void handleSearch(String? searchText, {bool forceUpdate = false}) {
    if (actualValue == searchText && !forceUpdate) {
      return;
    }

    if (searchText == null || searchText.isEmpty) {
      updateSuggestions('', []);
      return;
    }

    var suggestions = _findMatches(index, searchText);
    _suggestionLength = suggestions.length;
    if (suggestions.length > _suggestionLimit) {
      suggestions = suggestions.sublist(0, _suggestionLimit);
    }

    actualValue = searchText;
    updateSuggestions(searchText, suggestions);
  }

  // Hook up events.
  input.addEventListener('focus', (Event event) {
    handleSearch(input.value, forceUpdate: true);
  });

  input.addEventListener('blur', (Event event) {
    selectedElement = null;
    if (storedValue != null) {
      input.value = storedValue;
      storedValue = null;
    }
    hideSuggestions();
  });

  input.addEventListener('input', (event) {
    handleSearch(input.value);
  });

  input.addEventListener('keydown', (Event event) {
    if (event.type != 'keydown') {
      return;
    }

    event = event as KeyboardEvent;

    if (event.code == 'Enter') {
      event.preventDefault();
      if (selectedElement != null) {
        var selectingElement = selectedElement ?? 0;
        var href = suggestionElements[selectingElement].dataset['href'];
        if (href != null) {
          window.location.assign('$_htmlBase$href');
        }
        return;
      }
      // If there is no search suggestion selected, then change the window
      // location to `search.html`.
      else {
        var query = _htmlEscape.convert(actualValue);
        var searchPath = _relativePath.replace(queryParameters: {'q': query});
        window.location.assign(searchPath.toString());
        return;
      }
    }

    var lastIndex = suggestionElements.length - 1;
    var previousSelectedElement = selectedElement;

    if (event.code == 'ArrowUp') {
      if (selectedElement == null) {
        selectedElement = lastIndex;
      } else if (selectedElement == 0) {
        selectedElement = null;
      } else {
        selectedElement = selectedElement! - 1;
      }
    } else if (event.code == 'ArrowDown') {
      if (selectedElement == null) {
        selectedElement = 0;
      } else if (selectedElement == lastIndex) {
        selectedElement = null;
      } else {
        selectedElement = selectedElement! + 1;
      }
    } else {
      if (storedValue != null) {
        storedValue = null;
        handleSearch(input.value);
      }
      return;
    }

    if (previousSelectedElement != null) {
      suggestionElements[previousSelectedElement].classes.remove('tt-cursor');
    }

    if (selectedElement != null) {
      var selected = suggestionElements[selectedElement!];
      selected.classes.add('tt-cursor');

      // Guarantee the selected element is visible
      if (selectedElement == 0) {
        listBox.scrollTop = 0;
      } else if (selectedElement == lastIndex) {
        listBox.scrollTop = listBox.scrollHeight;
      } else {
        var offsetTop = selected.offsetTop;
        var parentOffsetHeight = listBox.offsetHeight;
        if (offsetTop < parentOffsetHeight ||
            parentOffsetHeight < (offsetTop + selected.offsetHeight)) {
          selected.scrollIntoView();
        }
      }

      // Store the actual input value to display their currently selected item.
      storedValue ??= input.value;
      input.value = suggestionsInfo[selectedElement!].name;
    } else if (storedValue != null && previousSelectedElement != null) {
      // They are moving back to the input field, so return the stored value.
      input.value = storedValue;
      storedValue = null;
    }

    event.preventDefault();
  });

  // Verifying the href to check if the search html was called to generate the main content elements that are going to be displayed.
  if (window.location.href.contains('search.html')) {
    var input = uri.queryParameters['q'];
    if (input == null) {
      return;
    }
    input = _htmlEscape.convert(input);
    _suggestionLimit = _suggestionLength;
    handleSearch(input);
    showSearchResultPage(input);
    hideSuggestions();
    _suggestionLimit = 10;
  }
}

Element _createSuggestion(String query, _IndexItem match) {
  final suggestion = document.createElement('div')
    ..setAttribute('data-href', match.href ?? '')
    ..classes.add('tt-suggestion');

  final suggestionTitle = document.createElement('span')
    ..classes.add('tt-suggestion-title')
    ..innerHtml =
        _highlight('${match.name} ${match.type.toLowerCase()}', query);
  suggestion.append(suggestionTitle);

  final enclosingElement = match.enclosedBy;
  if (enclosingElement != null) {
    suggestion.append(document.createElement('span')
      ..classes.add('tt-suggestion-container')
      ..innerHtml = '(in ${_highlight(enclosingElement.name, query)})');
  }

  // The one line description to use in the search suggestions.
  if (match.desc != '') {
    final inputDescription = document.createElement('blockquote')
      ..classes.add('one-line-description')
      ..attributes['title'] = _decodeHtml(match.desc.toString())
      ..innerHtml = _highlight(match.desc.toString(), query);
    suggestion.append(inputDescription);
  }

  suggestion.addEventListener('mousedown', (event) {
    event.preventDefault();
  });

  suggestion.addEventListener('click', (event) {
    if (match.href != null) {
      window.location.assign('$_htmlBase${match.href}');
      event.preventDefault();
    }
  });

  if (enclosingElement != null) {
    _mapToContainer(
      _createContainer(
        '${enclosingElement.name} ${enclosingElement.type}',
        enclosingElement.href,
      ),
      suggestion,
    );
  }
  return suggestion;
}

/// Maps a suggestion library/class [Element] to the other suggestions, if any.
void _mapToContainer(Element containerElement, Element suggestion) {
  final input = containerElement.innerHtml;

  if (input == null) {
    return;
  }

  final element = _containerMap[input];
  if (element != null) {
    element.append(suggestion);
  } else {
    containerElement.append(suggestion);
    _containerMap[input] = containerElement;
  }
}

/// Creates an `<a>` [Element] for enclosing library/class.
Element _createContainer(String encloser, String href) =>
    document.createElement('div')
      ..classes.add('tt-container')
      ..append(document.createElement('p')
        ..text = 'Results from '
        ..classes.add('tt-container-text')
        ..append(document.createElement('a')
          ..setAttribute('href', href)
          ..innerHtml = encloser));

/// Wraps each instance of [query] in [text] with a `<strong>` tag, as HTML
/// text.
String _highlight(String text, String query) => text.replaceAllMapped(
      RegExp(query, caseSensitive: false),
      (match) => "<strong class='tt-highlight'>${match[0]}</strong>",
    );

/// Decodes HTML entities (like `&lt;`) into their HTML elements (like `<`).
///
/// This is safe for use in an HTML attribute like `title`.
String _decodeHtml(String html) {
  return ((document.createElement('textarea') as TextAreaElement)
        ..innerHtml = html)
      .value!;
}

final _relativePath = () {
  var body = document.querySelector('body')!;
  var relativePath = '';
  if (body.getAttribute('data-using-base-href') == 'true') {
    relativePath = body.getAttribute('href')!;
  } else if (body.getAttribute('data-base-href') == '') {
    relativePath = './';
  } else {
    relativePath = body.getAttribute('data-base-href')!;
  }
  var href = Uri.parse(window.location.href);
  var base = href.resolve(relativePath);
  var search = Uri.parse('${base}search.html');
  return search;
}();

class _SearchMatch {
  final _IndexItem element;
  final double score;

  _SearchMatch(this.element, this.score);
}

class _IndexItem {
  final String name;
  final String qualifiedName;
  final String type;
  final String? href;
  final int? overriddenDepth;
  final String? desc;
  final _EnclosedBy? enclosedBy;

  _IndexItem._({
    required this.name,
    required this.qualifiedName,
    required this.type,
    this.desc,
    this.href,
    this.overriddenDepth,
    this.enclosedBy,
  });

  // "name":"dartdoc",
  // "qualifiedName":"dartdoc",
  // "href":"dartdoc/dartdoc-library.html",
  // "type":"library",
  // "overriddenDepth":0,
  // "packageName":"dartdoc"
  // ["enclosedBy":{"name":"Accessor","type":"class"}]

  factory _IndexItem.fromMap(Map<String, dynamic> data) {
    // Note that this map also contains 'packageName', but we're not currently
    // using that info.

    _EnclosedBy? enclosedBy;
    if (data['enclosedBy'] != null) {
      final map = data['enclosedBy'] as Map<String, dynamic>;
      enclosedBy = _EnclosedBy._(
          name: map['name'], type: map['type'], href: map['href']);
    }

    return _IndexItem._(
      name: data['name'],
      qualifiedName: data['qualifiedName'],
      href: data['href'],
      type: data['type'],
      overriddenDepth: data['overriddenDepth'],
      desc: data['desc'],
      enclosedBy: enclosedBy,
    );
  }
}

class _EnclosedBy {
  final String name;
  final String type;
  final String href;

  // Built from JSON structure:
  // ["enclosedBy":{"name":"Accessor","type":"class","href":"link"}]
  _EnclosedBy._({required this.name, required this.type, required this.href});
}
