import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/document.dart';

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
///
/// Each query change starts a new epoch. Batches from an older epoch are
/// discarded, so a slow scan can never overwrite the results of a newer
/// query or repopulate a field the reader has already cleared.
class BookSearch {
  BookSearch({
    required this.chapters,
    required this.onResults,
    required this.onDone,
  });

  /// Maximum results kept per search. A one-letter query on a large book
  /// would otherwise build 100k+ results with snippets and freeze the UI.
  static const maxResults = 500;

  /// Matches scanned before yielding to the event loop inside a single huge
  /// chapter (which otherwise never yields and freezes the UI).
  static const _yieldEveryMatches = 200;

  final List<Chapter> chapters;
  final ValueChanged<List<SearchResult>> onResults;
  final VoidCallback onDone;

  Timer? _debounce;
  String _query = '';
  int _epoch = 0;
  bool _running = false;
  bool _pendingStart = false;
  bool _disposed = false;
  bool _truncated = false;
  List<SearchResult> _allResults = [];

  /// Lower-cased chapter bodies, computed once per chapter for the lifetime
  /// of this search and reused by later queries.
  final Map<int, String> _lowerCache = {};

  /// All results from the last completed search.
  List<SearchResult> get allResults => _allResults;

  /// True when the scan stopped at [maxResults] and may have skipped matches.
  bool get isTruncated => _truncated;

  /// Start a debounced search. Rapid keystrokes cancel prior scans.
  void search(String query) {
    if (_disposed) return;
    final q = query.trim();
    _debounce?.cancel();
    _pendingStart = false;
    _query = q;
    _epoch++;
    _truncated = false;
    _allResults = [];
    onResults(const []);
    if (q.isEmpty) return;
    _debounce = Timer(const Duration(milliseconds: 300), _requestScan);
  }

  /// Run a full search immediately (used for submit/enter).
  void searchImmediate(String query) {
    if (_disposed) return;
    final q = query.trim();
    _debounce?.cancel();
    _pendingStart = false;
    _query = q;
    _epoch++;
    _truncated = false;
    _allResults = [];
    onResults(const []);
    if (q.isEmpty) return;
    _requestScan();
  }

  /// Stop any in-flight scan and clear all results.
  ///
  /// The scan's callbacks are invalidated by the epoch bump, so nothing from
  /// the cancelled query can arrive after this returns.
  void cancel() {
    if (_disposed) return;
    _debounce?.cancel();
    _pendingStart = false;
    _query = '';
    _epoch++;
    _truncated = false;
    _allResults = [];
    onResults(const []);
  }

  void _requestScan() {
    if (_disposed || _query.isEmpty) return;
    if (_running) {
      // The current scan will notice the epoch change and finish. Start this
      // query as soon as it has released the scanner.
      _pendingStart = true;
      return;
    }
    _running = true;
    _pendingStart = false;
    unawaited(_scanIncrementally(0, _epoch));
  }

  Future<void> _scanIncrementally(int chapterIndex, int epoch) async {
    if (_disposed || epoch != _epoch) {
      _finish(epoch);
      return;
    }
    if (_allResults.length >= maxResults) {
      _truncated = true;
      _finish(epoch);
      return;
    }
    if (chapterIndex >= chapters.length) {
      _finish(epoch);
      return;
    }

    final body = chapters[chapterIndex].body;
    final queryLower = _query.toLowerCase();
    final lower = _lowerCache.putIfAbsent(
      chapterIndex,
      () => body.toLowerCase(),
    );
    final batch = <SearchResult>[];
    var start = 0;
    var sinceYield = 0;

    while (start <= body.length - queryLower.length) {
      if (_disposed || epoch != _epoch) break;
      if (_allResults.length + batch.length >= maxResults) break;
      final idx = lower.indexOf(queryLower, start);
      if (idx == -1) break;

      // Extract snippet: ~30 chars before + match + ~30 chars after, without
      // splitting a surrogate pair at either edge.
      final snippetStart = _clampStart(
        body,
        (idx - 30).clamp(0, body.length),
        idx,
      );
      final snippetEnd = _clampEnd(
        body,
        (idx + queryLower.length + 30).clamp(0, body.length),
        idx + queryLower.length,
      );
      final raw = body.substring(snippetStart, snippetEnd);
      final snippet =
          '${snippetStart > 0 ? '…' : ''}$raw${snippetEnd < body.length ? '…' : ''}';

      batch.add(
        SearchResult(
          chapter: chapterIndex,
          offset: idx,
          length: queryLower.length,
          snippet: snippet,
        ),
      );
      start = idx + queryLower.length;
      if (++sinceYield >= _yieldEveryMatches) {
        sinceYield = 0;
        // Yield so a single huge chapter never freezes the UI.
        await Future<void>.delayed(Duration.zero);
      }
    }

    if (_disposed || epoch != _epoch) {
      _finish(epoch);
      return;
    }

    _allResults.addAll(batch);
    // Pass a snapshot so callers never observe the live mutable list.
    onResults(List.of(_allResults));

    if (_allResults.length >= maxResults) {
      _truncated = true;
      _finish(epoch);
      return;
    }

    // Yield to the event loop, then scan next chapter.
    await Future<void>.delayed(Duration.zero);
    if (_disposed || epoch != _epoch) {
      _finish(epoch);
      return;
    }
    await _scanIncrementally(chapterIndex + 1, epoch);
  }

  void _finish(int epoch) {
    if (!_running) return;
    _running = false;
    if (_disposed) return;
    if (epoch == _epoch) {
      if (_query.isNotEmpty) onDone();
      return;
    }
    if (_pendingStart) {
      _pendingStart = false;
      _requestScan();
    }
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
    _disposed = true;
    _debounce?.cancel();
    _running = false;
    _pendingStart = false;
    _lowerCache.clear();
  }
}

bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;

bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;

/// Moves a snippet start forward when it lands on the low half of a pair.
int _clampStart(String text, int index, int matchStart) {
  var result = index;
  if (result > 0 &&
      result < text.length &&
      _isLowSurrogate(text.codeUnitAt(result)) &&
      _isHighSurrogate(text.codeUnitAt(result - 1))) {
    result++;
  }
  return result > matchStart ? matchStart : result;
}

/// Moves a snippet end back when it would split a surrogate pair.
int _clampEnd(String text, int index, int matchEnd) {
  var result = index;
  if (result > 0 &&
      result < text.length &&
      _isHighSurrogate(text.codeUnitAt(result - 1))) {
    result--;
  }
  return result < matchEnd ? matchEnd : result;
}
