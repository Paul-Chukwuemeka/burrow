import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/reader_settings.dart';
import '../models/style_run.dart';

/// A page of text, as a [start, end) character range of the source string.
@immutable
class TextPage {
  const TextPage(this.start, this.end);
  final int start;
  final int end;
}

/// Drives chapter pagination incrementally, yielding control between chunks
/// to keep the UI responsive on large books.
///
/// Create one per chapter, call [nextChunk] repeatedly until [isDone], then
/// call [toPaginator] to get the final result. Dispose when done.
class ChapterPaginationDriver {
  ChapterPaginationDriver({
    required String text,
    required TextStyle style,
    required double maxWidth,
    required double maxHeight,
    required TextDirection direction,
    double firstPageInset = 0,
    TextScaler textScaler = TextScaler.noScaling,
    List<StyleRun> runs = const [],
    List<ImageRun> images = const [],
    ReaderSettings? settings,
    ReaderTheme? theme,
  })  : _text = text,
        _runs = runs,
        _images = images,
        _imageHeights = [
          for (final img in images)
            img.renderedHeight(maxWidth, maxHeight: maxHeight),
        ],
        _settings = settings,
        _theme = theme,
        _firstBudget = maxHeight - firstPageInset - _slack,
        _restBudget = maxHeight - _slack,
        _minBudget =
            textScaler.scale(style.fontSize ?? 16) * 1.4,
        _tp = TextPainter(textDirection: direction, textScaler: textScaler),
        _style = style,
        _maxWidth = maxWidth;

  static const double _slack = 6.0;

  final String _text;
  final List<StyleRun> _runs;

  /// Images in this chapter, sorted by ascending [ImageRun.offset] (as the
  /// parser emits them). Sortedness lets [_sliceHeight] scan only the images
  /// that actually fall in a candidate slice instead of the whole chapter.
  final List<ImageRun> _images;
  final List<double> _imageHeights;
  final ReaderSettings? _settings;
  final ReaderTheme? _theme;
  final TextStyle _style;
  final double _maxWidth;
  final double _firstBudget;
  final double _restBudget;
  final double _minBudget;
  final TextPainter _tp;

  final List<TextPage> _pages = [];
  int _offset = 0;
  bool _isFirst = true;
  int _seed = 1024;

  List<TextPage> get pages => _pages;
  bool get isDone => _offset >= _text.length || _text.isEmpty;

  /// Produce up to [count] more pages. Returns the pages added in this chunk.
  List<TextPage> nextChunk(int count) {
    if (isDone) return const [];

    final added = <TextPage>[];
    var produced = 0;
    while (produced < count && !isDone) {
      final page = _paginateOnePage();
      if (page == null) break;
      _pages.add(page);
      added.add(page);
      produced++;
    }
    return added;
  }

  TextPage? _paginateOnePage() {
    if (_offset >= _text.length) return null;

    final budget = math.max(
      _isFirst ? _firstBudget : _restBudget,
      _minBudget,
    );

    int end;
    if (_sliceHeight(_offset, _offset + 1) > budget) {
      end = _offset + 1;
      if (end < _text.length &&
          (_text.codeUnitAt(end) & 0xFC00) == 0xDC00) {
        end++;
      }
    } else {
      var bound = _offset + 1;
      var step = math.min(_seed, 1 << 16);
      while (bound + step < _text.length &&
          _sliceHeight(_offset, bound + step) <= budget) {
        bound += step;
        step = math.min(step * 2, 1 << 16);
      }
      var lo = bound;
      var hi = math.min(bound + step, _text.length);
      while (lo < hi) {
        final mid = lo + (hi - lo + 1) ~/ 2;
        if (_sliceHeight(_offset, mid) <= budget) {
          lo = mid;
        } else {
          hi = mid - 1;
        }
      }
      end = lo;
      while (end > _offset + 1 && _sliceHeight(_offset, end) > budget) {
        end--;
      }
    }

    if (end < _text.length &&
        !_isWhitespaceAt(end) &&
        !_isWhitespaceAt(end - 1)) {
      var w = end;
      while (w > _offset + 1 && !_isWhitespaceAt(w - 1)) {
        w--;
      }
      if (w > _offset && _isWhitespaceAt(w - 1)) {
        end = w;
      }
    }
    while (end > _offset + 1 && _isWhitespaceAt(end - 1)) {
      end--;
    }

    final page = TextPage(_offset, end);
    _isFirst = false;
    _seed = math.max(1, end - _offset);
    _offset = _nextContentStart(end);
    return page;
  }

  double _sliceHeight(int start, int end) {
    if (end <= start) return 0;
    // Images are sorted by offset, so only those landing in [start, end) are
    // summed. Precomputed heights avoid re-measuring on every probe.
    var imageExtra = 0.0;
    for (var i = _firstImageAtOrAfter(start);
        i < _images.length && _images[i].offset < end;
        i++) {
      imageExtra += _imageHeights[i];
    }
    // If the slice contains images, strip the \uFFFC so TextPainter doesn't
    // measure them as zero-height characters, then add the real heights.
    final span = _spanFor(start, end);
    if (imageExtra > 0) {
      // Rebuild span with \uFFFC replaced by newlines (line break height is
      // negligible vs the image we'll add back).
      final cleanText = _text.substring(start, end).replaceAll('\uFFFC', '\n');
      final cleanSpan = _runs.isEmpty
          ? TextSpan(text: cleanText, style: _style)
          : TextSpan(
              style: _style,
              children: buildStyledSpans(
                cleanText,
                _runs,
                _style,
                0,
                cleanText.length,
                quoteColor: _theme?.muted,
                settings: _settings,
              ),
            );
      _tp.text = cleanSpan;
    } else {
      _tp.text = span;
    }
    _tp.layout(maxWidth: _maxWidth);
    return _tp.height + imageExtra;
  }

  /// Index of the first image whose offset is >= [offset], assuming [_images]
  /// is sorted by offset. Returns [_images].length when none qualify.
  int _firstImageAtOrAfter(int offset) {
    var lo = 0, hi = _images.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_images[mid].offset < offset) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// The exact span the reader renders for this range — measurement and
  /// rendering must never diverge.
  TextSpan _spanFor(int start, int end) {
    if (_runs.isEmpty) {
      return TextSpan(text: _text.substring(start, end), style: _style);
    }
    return TextSpan(
      style: _style,
      children: buildStyledSpans(
        _text,
        _runs,
        _style,
        start,
        end,
        quoteColor: _theme?.muted,
        settings: _settings,
      ),
    );
  }

  bool _isWhitespaceAt(int i) {
    final c = _text.codeUnitAt(i);
    return c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D;
  }

  int _nextContentStart(int from) {
    var i = from;
    while (i < _text.length && _isWhitespaceAt(i)) {
      i++;
    }
    return i;
  }

  Paginator toPaginator() => Paginator._(List.unmodifiable(_pages));

  void dispose() => _tp.dispose();
}

/// Splits a chapter's text into pages that fit a given viewport and style.
///
/// Strategy: each page is built by finding the largest slice starting at the
/// current offset whose own [TextPainter] layout fits the page's vertical
/// budget (exponential bound + binary search). Because every page is measured
/// exactly as it is sliced, re-wrap drift between a whole-chapter layout and
/// isolated page slices cannot cause overflow by construction.
///
/// Slice boundaries snap to word/paragraph edges, and the whitespace at a
/// boundary belongs to neither page: slices never begin or end with a
/// newline, which would otherwise render a phantom empty line and skew the
/// measurement. Consecutive pages therefore tile the text with gaps that are
/// whitespace only.
class Paginator {
  Paginator._(this.pages);

  final List<TextPage> pages;

  static Paginator paginate({
    required String text,
    required TextStyle style,
    required double maxWidth,
    required double maxHeight,
    required TextDirection direction,
    double firstPageInset = 0,
    TextScaler textScaler = TextScaler.noScaling,
    List<StyleRun> runs = const [],
    List<ImageRun> images = const [],
    ReaderSettings? settings,
    ReaderTheme? theme,
  }) {
    if (text.isEmpty) {
      return Paginator._(const [TextPage(0, 0)]);
    }

    // One-shot pagination is just the incremental driver run to completion.
    // Sharing one implementation guarantees identical page boundaries.
    final driver = ChapterPaginationDriver(
      text: text,
      style: style,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      direction: direction,
      firstPageInset: firstPageInset,
      textScaler: textScaler,
      runs: runs,
      images: images,
      settings: settings,
      theme: theme,
    );
    while (!driver.isDone) {
      driver.nextChunk(64);
    }
    final result = driver.toPaginator();
    driver.dispose();
    return result;
  }

  /// Page index containing [offset]; clamps to valid range.
  ///
  /// Offsets that fall in a whitespace gap between pages — or past the last
  /// page entirely — resolve to the page that follows the gap.
  int pageIndexFor(int offset) {
    var lo = 0, hi = pages.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (pages[mid].end <= offset) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo < pages.length ? lo : pages.length - 1;
  }
}
