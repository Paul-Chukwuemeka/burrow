import 'dart:collection';

import 'package:burrow/models/reader_settings.dart';
import 'package:burrow/models/style_run.dart';
import 'package:burrow/services/book_search.dart';
import 'package:flutter/material.dart';

/// Builds the [InlineSpan] children for the page covering `text[start:end)`,
/// merging style runs (emphasis, blockquotes) with search-match highlights
/// and inline images.
///
/// Returns spans that tile the whole range: unstyled segments are emitted with
/// [base] so no text is ever dropped. Images are rendered as [WidgetSpan]
/// children sized to fit [renderWidth] while preserving aspect ratio, and
/// capped vertically by [maxHeight] so decorative art does not dominate.
List<InlineSpan> buildPageSpans({
  required String text,
  required int start,
  required int end,
  required TextStyle base,
  required ReaderTheme theme,
  required ReaderSettings settings,
  List<StyleRun> runs = const [],
  List<ImageRun> images = const [],
  double renderWidth = 300,
  double maxHeight = double.infinity,
  double devicePixelRatio = 1.0,
  List<SearchResult> matches = const [],
  SearchResult? currentMatch,
  ({int start, int end})? selectedRange,
}) {
  final slice = text.substring(start, end);
  if (runs.isEmpty &&
      matches.isEmpty &&
      images.isEmpty &&
      selectedRange == null) {
    return [TextSpan(text: slice, style: base)];
  }

  // Build a map from offset -> ImageRun for quick lookup.
  final imageMap = <int, ImageRun>{};
  for (final img in images) {
    if (img.offset >= start && img.offset < end) {
      imageMap[img.offset] = img;
    }
  }

  // Cut points: range bounds plus every run/match/image boundary inside it.
  final cuts = SplayTreeSet<int>()..addAll([start, end]);
  for (final r in runs) {
    if (r.start > start && r.start < end) cuts.add(r.start);
    if (r.end > start && r.end < end) cuts.add(r.end);
  }
  for (final m in matches) {
    final ms = m.offset.clamp(start, end);
    final me = (m.offset + m.length).clamp(start, end);
    if (ms >= me) continue;
    cuts.add(ms);
    cuts.add(me);
  }
  for (final imgOff in imageMap.keys) {
    cuts.add(imgOff);
    cuts.add(imgOff + 1); // \uFFFC is one character
  }
  if (selectedRange != null) {
    final rs = selectedRange.start.clamp(start, end);
    final re = selectedRange.end.clamp(start, end);
    if (rs < re) {
      cuts.add(rs);
      cuts.add(re);
    }
  }
  final boundaries = cuts.toList(growable: false);

  // Copy before sorting: callers pass immutable or shared lists.
  final sortedRuns = List<StyleRun>.of(runs)
    ..sort((a, b) => a.start.compareTo(b.start));
  final sortedMatches = List<SearchResult>.of(matches)
    ..sort((a, b) => a.offset.compareTo(b.offset));

  var runIdx = 0;
  var matchIdx = 0;
  final children = <InlineSpan>[];
  for (var i = 0; i < boundaries.length - 1; i++) {
    final segStart = boundaries[i];
    final segEnd = boundaries[i + 1];

    // Check if this segment is an image placeholder.
    if (segEnd == segStart + 1 && imageMap.containsKey(segStart)) {
      final img = imageMap[segStart]!;
      final size = img.renderedSize(renderWidth, maxHeight: maxHeight);
      Widget imageWidget;
      if (img.bytes.isEmpty) {
        // Deferred (not yet hydrated) or unreadable image: reserve the exact
        // space without asking the engine to decode empty bytes.
        imageWidget = SizedBox(width: size.width, height: size.height);
      } else {
        imageWidget = Image.memory(
          img.bytes,
          width: size.width,
          height: size.height,
          // Decode at display resolution (physical pixels) instead of the
          // source's full size, which can be many times larger.
          cacheWidth: (size.width * devicePixelRatio).round().clamp(1, 1 << 14),
          cacheHeight: (size.height * devicePixelRatio)
              .round()
              .clamp(1, 1 << 14),
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => Container(
            width: size.width,
            height: size.height,
            decoration: BoxDecoration(
              color: theme.muted.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Icon(
              Icons.broken_image_outlined,
              color: theme.muted,
              size: 24,
            ),
          ),
        );
        // A tap on a not-yet-hydrated image must not open the popup with no
        // bytes to show.
        if (img.onTap != null) {
          imageWidget = GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: img.onTap,
            child: imageWidget,
          );
        }
      }
      children.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              vertical: ImageRun.verticalPadding,
            ),
            child: Center(child: imageWidget),
          ),
        ),
      );
      continue;
    }

    // Advance pointers past spans that end before this segment starts.
    while (runIdx < sortedRuns.length && sortedRuns[runIdx].end <= segStart) {
      runIdx++;
    }
    while (matchIdx < sortedMatches.length &&
        sortedMatches[matchIdx].offset + sortedMatches[matchIdx].length <=
            segStart) {
      matchIdx++;
    }

    final run =
        runIdx < sortedRuns.length && sortedRuns[runIdx].start <= segStart
        ? sortedRuns[runIdx]
        : null;
    final match =
        matchIdx < sortedMatches.length &&
            sortedMatches[matchIdx].offset <= segStart
        ? sortedMatches[matchIdx]
        : null;

    var segStyle = styleForRun(
      base,
      run,
      settings: settings,
      quoteColor: theme.muted,
    );
    if (match != null) {
      final isCurrent = match == currentMatch;
      segStyle = segStyle.copyWith(
        backgroundColor: theme.accent.withValues(
          alpha: isCurrent ? 0.35 : 0.15,
        ),
        color: isCurrent ? theme.accent : null,
        fontWeight: isCurrent ? FontWeight.w700 : null,
      );
    }
    if (selectedRange != null) {
      final rs = selectedRange.start.clamp(start, end);
      final re = selectedRange.end.clamp(start, end);
      if (segStart >= rs && segEnd <= re) {
        segStyle = segStyle.copyWith(
          backgroundColor: theme.accent.withValues(alpha: 0.25),
        );
      }
    }
    final textContent = slice.substring(segStart - start, segEnd - start);
    // Skip if this is just the \uFFFC placeholder text (shouldn't reach here
    // normally, but guard against it).
    if (!textContent.contains('\uFFFC')) {
      children.add(TextSpan(text: textContent, style: segStyle));
    }
  }

  if (children.isEmpty) {
    return [TextSpan(text: slice, style: base)];
  }
  return children;
}
