import 'dart:async';

import 'package:flutter/foundation.dart';

import 'document_parser.dart';

/// A single match in a book.
@immutable
class SearchResult {
  const SearchResult({
    required this.chapter,
    required this.offset,
    required this.length,
    required this.snippet,
  });

  /// Chapter index in the document.
  final int chapter;

  /// Character offset within the chapter body.
  final int offset;

  /// Length of the match in characters.
  final int length;

  /// Surrounding text for display in the results list.
  final String snippet;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SearchResult &&
          chapter == other.chapter &&
          offset == other.offset &&
          length == other.length;

  @override
  int get hashCode => Object.hash(chapter, offset, length);
}

/// Incremental, case-insensitive in-memory book search.
///
/// Scans chapter body text for [query] matches, yielding results in batches
/// to keep the UI responsive on large books.
class BookSearch {
  BookSearch({
    required this.chapters,
    required this.onResults,
    required this.onDone,
  });

  final List<Chapter> chapters;
  final ValueChanged<List<SearchResult>> onResults;
  final VoidCallback onDone;

  Timer? _debounce;
  String _query = '';
  String _lastQuery = '';
  bool _running = false;
  List<SearchResult> _allResults = [];

  /// All results from the last completed search.
  List<SearchResult> get allResults => _allResults;

  /// Start a debounced search. Rapid keystrokes cancel prior scans.
  void search(String query) {
    _query = query.trim();
    _debounce?.cancel();
    if (_query.isEmpty) {
      _allResults = [];
      onResults([]);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), _startScan);
  }

  /// Run a full search immediately (used for submit/enter).
  void searchImmediate(String query) {
    _query = query.trim();
    _debounce?.cancel();
    if (_query.isEmpty) {
      _allResults = [];
      onResults([]);
      return;
    }
    _startScan();
  }

  void _startScan() {
    if (_running) return;
    _running = true;
    _lastQuery = _query;
    _allResults = [];
    _scanIncrementally(0);
  }

  void _scanIncrementally(int chapterIndex) {
    if (chapterIndex >= chapters.length || _lastQuery != _query) {
      _running = false;
      if (_lastQuery == _query) onDone();
      return;
    }

    final body = chapters[chapterIndex].body;
    final lower = body.toLowerCase();
    final queryLower = _lastQuery.toLowerCase();
    final batch = <SearchResult>[];
    var start = 0;

    while (start <= body.length - queryLower.length) {
      final idx = lower.indexOf(queryLower, start);
      if (idx == -1) break;

      // Extract snippet: ~30 chars before + match + ~30 chars after.
      final snippetStart = (idx - 30).clamp(0, body.length);
      final snippetEnd = (idx + queryLower.length + 30).clamp(0, body.length);
      final raw = body.substring(snippetStart, snippetEnd);
      final snippet =
          '${snippetStart > 0 ? '…' : ''}$raw${snippetEnd < body.length ? '…' : ''}';

      batch.add(SearchResult(
        chapter: chapterIndex,
        offset: idx,
        length: queryLower.length,
        snippet: snippet,
      ));
      start = idx + queryLower.length;
    }

    _allResults.addAll(batch);
    onResults(_allResults);

    // Yield to the event loop, then scan next chapter.
    Future.microtask(() => _scanIncrementally(chapterIndex + 1));
  }

  /// Finds which result index contains the given chapter + offset, or -1.
  int findResultIndex(int chapter, int offset) {
    for (var i = 0; i < _allResults.length; i++) {
      final r = _allResults[i];
      if (r.chapter == chapter && r.offset == offset) return i;
    }
    return -1;
  }

  /// Returns the set of match offsets that overlap a page's char range.
  List<SearchResult> matchesForPage(int chapter, int pageStart, int pageEnd) {
    if (_query.isEmpty || _allResults.isEmpty) return const [];
    return _allResults.where((r) {
      if (r.chapter != chapter) return false;
      return r.offset + r.length > pageStart && r.offset < pageEnd;
    }).toList();
  }

  void dispose() {
    _debounce?.cancel();
    _running = false;
  }
}
