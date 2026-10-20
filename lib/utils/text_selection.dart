/// Pure helpers for word-level text selection over the EPUB reader's pages.
///
/// All offsets are "flat document offsets": the concatenation of every chapter
/// body in reading order. [charsBefore] holds the flat offset at which each
/// chapter body begins, so chapter `c` occupies
/// `[charsBefore[c], charsBefore[c] + chapterBodies[c].length)`.
///
/// Selection is whole-word only — there is no character-level selection.
/// Everything here is dependency-free so it can be unit tested and shared by
/// the selection model, the renderer, and the gesture layer.
library;

/// Unicode letters and digits, the base of a word.
final RegExp _letterOrDigit = RegExp(r'[\p{L}\p{Nd}]', unicode: true);

/// ASCII apostrophe (0x27).
const int _asciiApostrophe = 0x27;

/// Right single quotation mark (U+2019), used as the typographic apostrophe.
const int _unicodeApostrophe = 0x2019;

/// The object-replacement character the reader stores for inline images.
const String _imagePlaceholder = '\uFFFC';

/// Whether [rune] can appear inside a word.
///
/// A word character is a Unicode letter or digit, or an apostrophe (`'` U+0027
/// or `’` U+2019), which may only appear as an *in-word* character. Em-dashes,
/// curly double quotes as punctuation, and the image placeholder (`\uFFFC`) are
/// never word characters.
bool isWordChar(int rune) {
  if (rune == _asciiApostrophe || rune == _unicodeApostrophe) return true;
  return _letterOrDigit.hasMatch(String.fromCharCode(rune));
}

bool _isLetterOrDigit(int rune) =>
    _letterOrDigit.hasMatch(String.fromCharCode(rune));

bool _isApostrophe(int rune) =>
    rune == _asciiApostrophe || rune == _unicodeApostrophe;

/// Returns the index of the chapter that contains the flat offset [flat].
///
/// Looks up the last `i` with `charsBefore[i] <= flat`; when [flat] lies past
/// the end of every chapter, the last index is returned. An empty list yields 0.
int chapterForOffset(int flat, List<int> charsBefore) {
  if (charsBefore.isEmpty) return 0;
  var lo = 0;
  var hi = charsBefore.length - 1;
  var result = 0;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    if (charsBefore[mid] <= flat) {
      result = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return result;
}

/// The whole-word range containing the flat offset [flat], or `null`.
///
/// [chapterBody] is the chapter's text and [chapterStartFlat] is the flat offset
/// at which it begins. The search window defaults to the whole chapter and can
/// be narrowed to a page with [loFlat] / [hiFlat] (also flat offsets, `hiFlat`
/// exclusive). [flat] is clamped inside the window before the scan so a press
/// near a page edge cannot drag in a word from the adjacent page.
///
/// The scan expands outward while [isWordChar], then trims leading/trailing
/// apostrophes. It returns `null` when the result is empty or an edge rune is
/// not a letter or digit. Returned offsets are flat.
({int start, int end})? wordBoundsAt(
  int flat,
  String chapterBody,
  int chapterStartFlat, {
  int? loFlat,
  int? hiFlat,
}) {
  final length = chapterBody.length;
  if (length == 0) return null;

  // Window in chapter-local code-unit coordinates.
  var lo = (loFlat ?? chapterStartFlat) - chapterStartFlat;
  var hi = (hiFlat ?? chapterStartFlat + length) - chapterStartFlat;
  if (lo < 0) lo = 0;
  if (hi > length) hi = length;
  if (lo >= hi) return null;

  // Align the window to rune boundaries: an edge landing on the low half of a
  // surrogate pair would otherwise expose half a rune. This mirrors the old
  // rune-index window, which started at the first rune beginning at or after
  // `lo` and stopped before any rune beginning at or after `hi`.
  if (lo > 0 && lo < length && _isLowSurrogate(chapterBody.codeUnitAt(lo))) {
    lo++;
  }
  if (hi > lo && hi < length && _isLowSurrogate(chapterBody.codeUnitAt(hi))) {
    hi--;
  }
  if (lo >= hi) return null;

  var press = flat - chapterStartFlat;
  if (press < lo) press = lo;
  if (press >= hi) press = hi - 1;

  // Offsets are code units, so a press that lands on the low half of a
  // surrogate pair steps back to the rune's first unit. The scan itself is
  // bounded to the window: no whole-chapter rune arrays are allocated.
  if (press > lo &&
      _isLowSurrogate(chapterBody.codeUnitAt(press)) &&
      _isHighSurrogate(chapterBody.codeUnitAt(press - 1))) {
    press--;
  }

  // A press on whitespace, punctuation, or an image selects nothing: the
  // selection only starts once the finger is over an in-word character.
  if (!isWordChar(_runeAt(chapterBody, press))) return null;

  var start = press;
  while (start > lo) {
    final prev = _runeStartBefore(chapterBody, start);
    if (prev < lo || !isWordChar(_runeAt(chapterBody, prev))) break;
    start = prev;
  }

  var end = press + _runeLengthAt(chapterBody, press);
  while (end < hi) {
    if (!isWordChar(_runeAt(chapterBody, end))) break;
    end += _runeLengthAt(chapterBody, end);
  }

  // Apostrophes are word characters, but only in-word: trim them from the edges.
  while (start < end && _isApostrophe(_runeAt(chapterBody, start))) {
    start += _runeLengthAt(chapterBody, start);
  }
  while (end > start &&
      _isApostrophe(_runeAt(chapterBody, _runeStartBefore(chapterBody, end)))) {
    end = _runeStartBefore(chapterBody, end);
  }
  if (start >= end) return null;

  // The press itself must survive trimming: a finger on a word-edge apostrophe
  // selects nothing.
  if (press < start || press >= end) return null;

  // An edge rune must be a letter or digit (e.g. a word of only apostrophes).
  if (!_isLetterOrDigit(_runeAt(chapterBody, start)) ||
      !_isLetterOrDigit(
        _runeAt(chapterBody, _runeStartBefore(chapterBody, end)),
      )) {
    return null;
  }

  return (start: start + chapterStartFlat, end: end + chapterStartFlat);
}

bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;

bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;

/// The number of code units occupied by the rune starting at [offset].
int _runeLengthAt(String text, int offset) {
  final unit = text.codeUnitAt(offset);
  if (_isHighSurrogate(unit) &&
      offset + 1 < text.length &&
      _isLowSurrogate(text.codeUnitAt(offset + 1))) {
    return 2;
  }
  return 1;
}

/// The rune starting at the code-unit [offset].
int _runeAt(String text, int offset) {
  final unit = text.codeUnitAt(offset);
  if (_isHighSurrogate(unit) &&
      offset + 1 < text.length &&
      _isLowSurrogate(text.codeUnitAt(offset + 1))) {
    final low = text.codeUnitAt(offset + 1);
    return 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00);
  }
  return unit;
}

/// The code-unit offset where the rune ending at [offset] (exclusive) begins.
int _runeStartBefore(String text, int offset) {
  var index = offset - 1;
  if (_isLowSurrogate(text.codeUnitAt(index)) &&
      index > 0 &&
      _isHighSurrogate(text.codeUnitAt(index - 1))) {
    index--;
  }
  return index;
}

/// Whether the selection's end handle should render on the current page.
///
/// Handles render only on the reader's current flat page. When the selection's
/// end lies on the previous page — including the whitespace the paginator drops
/// between pages and trailing punctuation the word scan excludes — the end
/// handle waits at the top of the current (next) page.
bool showsSelectionEndHandle({
  required bool isCurrentPage,
  required int? selectionEnd,
  required int pageFlatStart,
  required int pageFlatEnd,
  required int? previousPageFlatStart,
  required bool isLastPage,
}) {
  if (!isCurrentPage || selectionEnd == null) return false;
  if (selectionEnd >= pageFlatStart) {
    return selectionEnd < pageFlatEnd ||
        (selectionEnd == pageFlatEnd && isLastPage);
  }
  return previousPageFlatStart != null && selectionEnd >= previousPageFlatStart;
}

/// The plain-text of the flat range `[start, end)`, joining chapters with `\n`.
///
/// Each chapter contributes the part of its body that overlaps the range; the
/// image placeholder (`\uFFFC`) is stripped so copied text is plain. Chapters
/// are joined with a newline, including when the range spans chapter gaps.
String selectionText({
  required int start,
  required int end,
  required List<String> chapterBodies,
  required List<int> charsBefore,
}) {
  final parts = <String>[];
  final count = chapterBodies.length < charsBefore.length
      ? chapterBodies.length
      : charsBefore.length;
  for (var c = 0; c < count; c++) {
    final body = chapterBodies[c];
    final chapterStart = charsBefore[c];
    final chapterEnd = chapterStart + body.length;
    final lo = start > chapterStart ? start : chapterStart;
    final hi = end < chapterEnd ? end : chapterEnd;
    if (hi <= lo) continue;
    final piece = body
        .substring(lo - chapterStart, hi - chapterStart)
        .replaceAll(_imagePlaceholder, '');
    // An image-only slice would otherwise contribute an empty part and split
    // the joined text with a blank line.
    if (piece.isEmpty) continue;
    parts.add(piece);
  }
  return parts.join('\n');
}

/// Clips the flat selection `[selectionStart, selectionEnd)` to one page.
///
/// [pageStart] / [pageEnd] are chapter-local offsets (relative to
/// [chapterStartFlat]), `pageEnd` exclusive. Returns `null` when the selection
/// does not overlap the page. Returned offsets are chapter-local.
({int start, int end})? pageLocalRange({
  required int selectionStart,
  required int selectionEnd,
  required int chapterStartFlat,
  required int pageStart,
  required int pageEnd,
}) {
  final localStart = selectionStart - chapterStartFlat;
  final localEnd = selectionEnd - chapterStartFlat;
  final s = localStart > pageStart ? localStart : pageStart;
  final e = localEnd < pageEnd ? localEnd : pageEnd;
  if (e <= s) return null;
  return (start: s, end: e);
}

/// Whether the flat range `[start, end)` is exactly one whole word.
bool isSingleWordRange({
  required int start,
  required int end,
  required List<String> chapterBodies,
  required List<int> charsBefore,
}) {
  if (chapterBodies.isEmpty || charsBefore.isEmpty) return false;
  final chapter = chapterForOffset(start, charsBefore);
  if (chapter < 0 || chapter >= chapterBodies.length) return false;
  final bounds = wordBoundsAt(
    start,
    chapterBodies[chapter],
    charsBefore[chapter],
  );
  return bounds != null && bounds.start == start && bounds.end == end;
}
