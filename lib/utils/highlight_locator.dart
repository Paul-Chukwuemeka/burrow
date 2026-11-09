/// Pure helpers for converting between flat document offsets and the
/// chapter-local offsets stored by highlights.
///
/// Reflowable highlights are anchored to a chapter and two offsets inside that
/// chapter's body. Keeping them chapter-local means changing font size, line
/// height, margins, theme, or pagination never moves a highlight.
///
/// All offsets are UTF-16 code units. [charsBefore] holds the flat offset at
/// which each chapter body begins.
library;

/// The chapter containing [flat] and the offset inside that chapter.
({int chapter, int offset}) splitFlatOffset(int flat, List<int> charsBefore) {
  if (charsBefore.isEmpty) return (chapter: 0, offset: 0);

  var lo = 0;
  var hi = charsBefore.length - 1;
  var chapter = 0;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    if (charsBefore[mid] <= flat) {
      chapter = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }

  final offset = flat - charsBefore[chapter];
  return (chapter: chapter, offset: offset < 0 ? 0 : offset);
}

/// The flat offset for a chapter-local [offset].
int flatOffsetFor(int chapter, int offset, List<int> charsBefore) {
  if (charsBefore.isEmpty) return 0;
  final c = chapter.clamp(0, charsBefore.length - 1);
  return charsBefore[c] + (offset < 0 ? 0 : offset);
}

/// Builds a chapter-local locator from a flat selection.
///
/// [end] is exclusive. A selection that ends exactly at the start of the next
/// chapter is stored against that next chapter with offset 0.
({int chapter, int startOffset, int endChapter, int endOffset})
reflowableLocatorFromFlat({
  required int start,
  required int end,
  required List<int> charsBefore,
}) {
  final s = start < 0 ? 0 : start;
  final e = end <= s ? s + 1 : end;
  final startLoc = splitFlatOffset(s, charsBefore);
  final endLoc = splitFlatOffset(e, charsBefore);
  return (
    chapter: startLoc.chapter,
    startOffset: startLoc.offset,
    endChapter: endLoc.chapter,
    endOffset: endLoc.offset,
  );
}

/// Clamps a stored reflowable locator to the current parse.
///
/// Returns the start chapter and a non-empty range inside it, or `null` when
/// the start chapter no longer exists or its body has no room at the stored
/// offset. Callers keep the stored row either way; this only decides whether a
/// jump is possible.
({int chapter, int start, int end})? clampReflowableLocator({
  required int chapter,
  required int startOffset,
  required int endChapter,
  required int endOffset,
  required int chapterCount,
  required int Function(int chapter) chapterLength,
}) {
  if (chapter < 0 || chapter >= chapterCount) return null;
  if (endChapter < chapter) return null;

  final length = chapterLength(chapter);
  if (length <= 0) return null;

  final start = startOffset.clamp(0, length);
  if (start >= length) return null;

  if (endChapter > chapter) {
    return (chapter: chapter, start: start, end: length);
  }

  final end = endOffset.clamp(start, length);
  if (end <= start) return null;
  return (chapter: chapter, start: start, end: end);
}

/// Clips a highlight to the part visible on one page.
///
/// Page bounds are chapter-local. Returns `null` when the highlight does not
/// overlap the page.
({int start, int end})? clipHighlightToPage({
  required int highlightChapter,
  required int startOffset,
  required int endChapter,
  required int endOffset,
  required int chapter,
  required int pageStart,
  required int pageEnd,
  required int chapterLength,
}) {
  if (chapter < highlightChapter || chapter > endChapter) return null;

  final start = chapter == highlightChapter
      ? startOffset.clamp(0, chapterLength)
      : 0;
  final end = chapter == endChapter
      ? endOffset.clamp(0, chapterLength)
      : chapterLength;

  final s = start > pageStart ? start : pageStart;
  final e = end < pageEnd ? end : pageEnd;
  if (e <= s) return null;
  return (start: s, end: e);
}
