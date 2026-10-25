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

/// A single laid-out line: the source range it covers plus its rendered
/// height. Synthetic blank lines (paragraph breaks) have `start == end`.
class _Line {
  const _Line(this.start, this.end, this.height);
  final int start;
  final int end;
  final double height;
}

/// Drives chapter pagination incrementally, yielding control between chunks
/// to keep the UI responsive on large books.
///
/// Create one per chapter, call [nextChunk] (or [nextChunkUntil]) repeatedly
/// until [isDone], then call [toPaginator] to get the final result. Dispose
/// when done.
///
/// ## Layout model
///
/// The chapter is laid out one paragraph at a time. Forced breaks at `\n`
/// make paragraphs independent for line breaking, so laying each one out in
/// isolation yields exactly the same lines as laying out the whole chapter at
/// once — but lets the driver yield between paragraphs instead of blocking a
/// frame on a single huge layout. Each paragraph's `TextPainter` line metrics
/// give the line boundaries and heights directly, so a page is simply the run
/// of lines that fits the vertical budget. Line breaking (including CJK and
/// grapheme clusters) is delegated to Flutter's ICU line breaker, so no manual
/// whitespace or code-unit snapping is needed or correct.
///
/// Inline images are `\uFFFC` placeholders in the body; their rendered size is
/// supplied to `TextPainter.setPlaceholderDimensions` so measurement and the
/// `WidgetSpan`s that actually render them agree exactly. This is also cheaper
/// and more accurate than substituting the placeholder for a newline.
///
/// Known limitation: the body is modelled as one styled string with inline
/// placeholders, so block-level structure (lists, tables, nested margins) is
/// not represented. Fine for narrative prose; revisit for textbook-style EPUBs.
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
  }) : _text = text,
       _runs = runs,
       _images = images,
       _settings = settings,
       _theme = theme,
       _maxHeight = maxHeight,
       _firstBudget = maxHeight - firstPageInset - _slack,
       _restBudget = maxHeight - _slack,
       _minBudget = textScaler.scale(style.fontSize ?? 16) * 1.4,
       _tp = TextPainter(textDirection: direction, textScaler: textScaler),
       _style = style,
       _maxWidth = maxWidth;

  static const double _slack = 6.0;

  final String _text;
  final List<StyleRun> _runs;

  /// Images in this chapter, sorted by ascending [ImageRun.offset] (as the
  /// parser emits them), matching the order of `\uFFFC` in [_text].
  final List<ImageRun> _images;
  final ReaderSettings? _settings;
  final ReaderTheme? _theme;
  final TextStyle _style;
  final double _maxWidth;
  final double _maxHeight;
  final double _firstBudget;
  final double _restBudget;
  final double _minBudget;
  final TextPainter _tp;

  final List<TextPage> _pages = [];

  /// Laid-out lines not yet consumed by a page, in reading order.
  final List<_Line> _pending = [];

  /// Next source offset whose paragraph has not been laid out yet.
  int _cursor = 0;

  /// Index into [_runs] of the first run at or after [_cursor]. Advanced as
  /// paragraphs are laid out so per-paragraph span building does not rescan the
  /// whole run list from zero.
  int _runStart = 0;

  /// Test-only: how many style runs were examined across all paragraphs.
  @visibleForTesting
  int debugRunVisits = 0;

  /// Test-only: heights of the lines selected for each built page. Appended by
  /// [ChapterPaginationDriver._buildNextPage], so a test can compare what
  /// pagination counted per page with what the page actually renders.
  @visibleForTesting
  final List<List<double>> debugPageLineHeights = [];

  bool _exhausted = false;
  bool _isFirst = true;
  bool _done = false;

  /// Height of a blank line, measured once from the base style. Used as the
  /// fallback for a paragraph break (`\n\n`) that no style run covers.
  late final double _baseLineHeight = _measureBaseLineHeight();

  /// Cached line heights of resolved spans, keyed by their [TextStyle] (value
  /// equality): a chapter's paragraph breaks almost always share one style.
  final Map<TextStyle, double> _lineHeightCache = {};

  /// Index into [_runs] of the first run not ending before the last scanned
  /// paragraph break, so warming the blank-line styles stays linear in the
  /// run count across a chapter.
  int _blankRunStart = 0;

  List<TextPage> get pages => _pages;
  bool get isDone => _done || _text.isEmpty;

  /// Produce up to [count] more pages. Deterministic: page boundaries do not
  /// depend on how the work is chunked.
  List<TextPage> nextChunk(int count) {
    final added = <TextPage>[];
    while (added.length < count && !_done) {
      final page = _buildNextPage();
      if (page == null) break;
      _pages.add(page);
      added.add(page);
    }
    return added;
  }

  /// Produce pages until at least [minPages] are added or [budget] elapses.
  /// Used to yield between frames without assuming uniform page cost.
  List<TextPage> nextChunkUntil({
    int minPages = 1,
    Duration budget = const Duration(milliseconds: 8),
  }) {
    final stopwatch = Stopwatch()..start();
    final added = <TextPage>[];
    while (!_done && (added.length < minPages || stopwatch.elapsed < budget)) {
      final page = _buildNextPage();
      if (page == null) break;
      _pages.add(page);
      added.add(page);
    }
    return added;
  }

  TextPage? _buildNextPage() {
    while (true) {
      // Drop whitespace-only lines at a page boundary so pages never begin
      // with a phantom empty line.
      while (_pending.isNotEmpty && _isBlankLine(_pending.first)) {
        _pending.removeAt(0);
      }
      _fillPending(_restBudget);
      while (_pending.isEmpty && !_exhausted) {
        _layoutNextParagraph();
        _fillPending(_restBudget);
      }
      if (_pending.isEmpty) {
        _done = true;
        return null;
      }

      final budget = math.max(
        _isFirst ? _firstBudget : _restBudget,
        _minBudget,
      );

      var height = 0.0;
      var last = -1;
      for (var i = 0; i < _pending.length; i++) {
        final line = _pending[i];
        if (last >= 0 && height + line.height > budget) break;
        height += line.height;
        last = i;
      }

      final start = _pending.first.start;
      var end = _pending[last].end;
      debugPageLineHeights.add(
        [for (var j = 0; j <= last; j++) _pending[j].height],
      );
      _pending.removeRange(0, last + 1);

      // Trailing whitespace belongs to no page; leaving it out avoids a
      // phantom empty line when the slice renders on its own.
      while (end > start && _isWhitespaceAt(end - 1)) {
        end--;
      }

      if (end <= start) continue;

      _isFirst = false;
      return TextPage(start, end);
    }
  }

  /// Lay out paragraphs until the pending line buffer holds at least [needed]
  /// vertical pixels, or the chapter is exhausted.
  void _fillPending(double needed) {
    while (!_exhausted) {
      var total = 0.0;
      for (final line in _pending) {
        total += line.height;
      }
      if (total >= needed) return;
      _layoutNextParagraph();
    }
  }

  /// Lay out the paragraph starting at [_cursor] and append its lines to
  /// [_pending]. Paragraphs are separated by `\n`; an empty segment between two
  /// newlines contributes one blank line, while a trailing newline does not.
  void _layoutNextParagraph() {
    if (_exhausted) return;
    if (_cursor >= _text.length) {
      _exhausted = true;
      return;
    }

    final newline = _text.indexOf('\n', _cursor);
    final segEnd = newline == -1 ? _text.length : newline;
    final hasBreak = newline != -1;

    if (segEnd > _cursor) {
      _pending.addAll(_layoutText(_cursor, segEnd));
    } else if (hasBreak) {
      // Empty paragraph between two newlines — one blank line. Attribute it to
      // the newline so it participates in whitespace trimming, and size it
      // with the style run covering that newline: the rendered empty line is
      // as tall as the run's style (typically the book's CSS), not the
      // reader's settings base style. Sizing it from the base style reserved
      // ~10px per paragraph the renderer never used and ended every page
      // short of the bottom.
      _pending.add(_Line(newline, newline, _blankLineHeightAt(newline)));
    }

    _cursor = hasBreak ? newline + 1 : _text.length;
    if (_cursor >= _text.length) _exhausted = true;
  }

  /// Lay out `text[start:end)` with the chapter's styles and images, returning
  /// one [_Line] per rendered line, in source order.
  List<_Line> _layoutText(int start, int end) {
    _tp.text = TextSpan(style: _style, children: _measureChildren(start, end));
    _tp.setPlaceholderDimensions(_placeholdersIn(start, end));
    _tp.layout(maxWidth: _maxWidth);

    final metrics = _tp.computeLineMetrics();
    if (metrics.isEmpty) return const [];

    // Start offset of each line, probed at the line's vertical midpoint.
    final starts = <int>[];
    for (final m in metrics) {
      final top = m.baseline - m.ascent;
      final bottom = m.baseline + m.descent;
      final y = ((top + bottom) / 2)
          .clamp(0.0, math.max(0.0, _tp.height - 0.001))
          .toDouble();
      starts.add(_tp.getPositionForOffset(Offset(0, y)).offset);
    }
    for (var i = 1; i < starts.length; i++) {
      if (starts[i] < starts[i - 1]) starts[i] = starts[i - 1];
    }

    final length = end - start;
    final lines = <_Line>[];
    for (var i = 0; i < metrics.length; i++) {
      final localStart = starts[i];
      final localEnd = i + 1 < starts.length ? starts[i + 1] : length;
      lines.add(
        _Line(
          start + localStart,
          start + math.max(localEnd, localStart),
          metrics[i].height,
        ),
      );
    }
    return lines;
  }

  /// Builds the measurement span tree for `[start, end)`, turning each
  /// `\uFFFC` image placeholder into a [WidgetSpan] so its box participates in
  /// line layout. The actual size comes from [_placeholdersIn]; the dummy child
  /// is never built by [TextPainter].
  List<InlineSpan> _measureChildren(int start, int end) {
    // Advance past runs that end before this paragraph so each run is examined
    // ~once across the chapter, not once per paragraph.
    while (_runStart < _runs.length && _runs[_runStart].end <= start) {
      _runStart++;
    }
    for (var i = _runStart; i < _runs.length && _runs[i].start < end; i++) {
      debugRunVisits++;
    }
    final source = buildStyledSpans(
      _text,
      _runs,
      _style,
      start,
      end,
      quoteColor: _theme?.muted,
      settings: _settings,
      fromIndex: _runStart,
    );
    final children = <InlineSpan>[];
    for (final span in source) {
      final text = span.text ?? '';
      if (text.isEmpty) {
        children.add(span);
        continue;
      }
      var cursor = 0;
      while (true) {
        final idx = text.indexOf('\uFFFC', cursor);
        if (idx == -1) {
          children.add(
            TextSpan(text: text.substring(cursor), style: span.style),
          );
          break;
        }
        if (idx > cursor) {
          children.add(
            TextSpan(text: text.substring(cursor, idx), style: span.style),
          );
        }
        children.add(
          const WidgetSpan(
            child: SizedBox.shrink(),
            alignment: PlaceholderAlignment.middle,
          ),
        );
        cursor = idx + 1;
      }
    }
    return children;
  }

  /// Placeholder dimensions for the `\uFFFC` images inside `[start, end)`, in
  /// the order they appear in the text. Sizes match the `WidgetSpan`s built by
  /// `buildPageSpans`, including the vertical padding it applies.
  List<PlaceholderDimensions> _placeholdersIn(int start, int end) {
    final dims = <PlaceholderDimensions>[];
    for (final img in _images) {
      if (img.offset < start) continue;
      if (img.offset >= end) break;
      // Cap the image so the placeholder line (height + 2 * verticalPadding)
      // still fits the page box: sizing against the raw page height made
      // full-page images measure/render one image larger than the page and
      // clip. Must mirror buildPageSpans below.
      final size = img.renderedSize(
        _maxWidth,
        maxHeight: _maxHeight - 2 * ImageRun.verticalPadding,
      );
      // A marker alone on its line gets a full-column placeholder cell so
      // the rendered image centers in the column. The line's height is
      // unchanged, and the marker's line holds nothing else, so wrapping
      // (and therefore pagination) is identical to a shrink-wrapped box.
      // Must mirror buildPageSpans below.
      final width = ImageRun.standaloneIn(_text, img.offset)
          ? _maxWidth
          : size.width;
      dims.add(
        PlaceholderDimensions(
          size: Size(width, size.height + 2 * ImageRun.verticalPadding),
          alignment: PlaceholderAlignment.middle,
        ),
      );
    }
    return dims;
  }

  /// Height of the blank line a paragraph break contributes at [newline].
  ///
  /// The break's newline character is covered by the same style runs as the
  /// body text, and the rendered empty line is as tall as the tallest span on
  /// it. Resolving those runs through [styleForRun] (exactly what
  /// `buildPageSpans` does when rendering) keeps measurement and rendering in
  /// agreement. Books without runs covering the break keep the base-style
  /// height.
  double _blankLineHeightAt(int newline) {
    while (_blankRunStart < _runs.length &&
        _runs[_blankRunStart].end <= newline) {
      _blankRunStart++;
    }
    // A run that began before the break can still cover its newline.
    var i = _blankRunStart;
    for (var j = _blankRunStart - 1; j >= 0 && _runs[j].end > newline; j--) {
      i = j;
    }
    var height = 0.0;
    for (; i < _runs.length && _runs[i].start <= newline; i++) {
      final run = _runs[i];
      if (run.end <= newline) continue;
      // Mirror `buildStyledSpans`: without settings, CSS is ignored and only
      // emphasis applies, so measurement matches the rendered spans.
      final style = _settings == null
          ? _style.copyWith(
              fontWeight: run.bold ? FontWeight.w700 : null,
              fontStyle: run.italic || run.quote ? FontStyle.italic : null,
            )
          : styleForRun(
              _style,
              run,
              settings: _settings,
              quoteColor: _theme?.muted,
            );
      height = math.max(height, _lineHeightFor(style));
    }
    return height > 0 ? height : _baseLineHeight;
  }

  /// Height one text line occupies under [style], measured the same way
  /// [_layoutText] measures paragraph lines.
  double _lineHeightFor(TextStyle style) {
    final cached = _lineHeightCache[style];
    if (cached != null) return cached;
    final probe = TextPainter(
      text: TextSpan(text: 'X', style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    final metrics = probe.computeLineMetrics();
    final height = metrics.isNotEmpty
        ? metrics.first.height
        : (style.fontSize ?? 16) * (style.height ?? 1.2);
    probe.dispose();
    _lineHeightCache[style] = height;
    return height;
  }

  double _measureBaseLineHeight() => _lineHeightFor(_style);

  bool _isBlankLine(_Line line) {
    if (line.start == line.end) return true;
    for (var i = line.start; i < line.end; i++) {
      if (!_isWhitespaceAt(i)) return false;
    }
    return true;
  }

  bool _isWhitespaceAt(int i) {
    final c = _text.codeUnitAt(i);
    return c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D;
  }

  Paginator toPaginator() => Paginator._(
        List.unmodifiable(_pages),
        List.unmodifiable(debugPageLineHeights),
      );

  void dispose() => _tp.dispose();
}

/// Splits a chapter's text into pages that fit a given viewport and style.
///
/// Strategy: paragraphs are laid out once each (see [ChapterPaginationDriver])
/// and their line metrics are accumulated until the page's vertical budget is
/// exceeded. Because line breaking is a pure function of width and every page
/// ends on a line boundary, an isolated page slice wraps exactly as it did in
/// the full-chapter layout. Line breaks come from Flutter's ICU line breaker,
/// so word, CJK, and grapheme boundaries are handled correctly without manual
/// snapping.
///
/// Whitespace at a boundary belongs to neither page: pages never begin or end
/// with whitespace, which would otherwise render a phantom empty line and skew
/// the measurement. Consecutive pages therefore tile the text with gaps that
/// are whitespace only.
class Paginator {
  final List<TextPage> pages;

  /// Per-page measured line heights (parallel to [pages]); test-only
  /// diagnostic for comparing what pagination counted with what renders.
  final List<List<double>> pageLineHeights;

  Paginator._(this.pages, [this.pageLineHeights = const []]);

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
