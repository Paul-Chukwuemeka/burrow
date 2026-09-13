import '../models/book.dart';

/// Cache for displayTitle to avoid re-running 7 regexes per access.
final Map<String, String> _displayTitleCache = <String, String>{};

/// Filename cruft stripped from imported titles before display.
///
/// Sideloading sites commonly name files like
/// `_OceanofPDF.com_The_Forever_Hero_by_John_Doe.pdf`; this removes the site
/// tokens, bracketed format tags, underscore separators and dangling glue so
/// titles read as book names.
const _siteNoise = [
  'oceanofpdf.com',
  'oceanofpdf',
  'z-lib.org',
  'z-library',
  'libgen.li',
  'libgen.is',
  'libgen.rs',
  'pdfroom.com',
  'annas-archive.org',
  'annas-archive',
  'ebookhunter.net',
  'vk.com',
];

final RegExp _siteNoiseRe = RegExp(
  _siteNoise.map(RegExp.escape).join('|'),
  caseSensitive: false,
);

/// Bracketed tags such as `[PDF]`, `(EPUB+MOBI)`, `{_r.v}`.
final RegExp _formatTagRe = RegExp(
  r'[\[\(\{]\s*[^\]\)\}]*(pdf|epub|mobi|azw|rtf|lit)[^\]\)\}]*[\]\)\}]',
  caseSensitive: false,
);

final RegExp _underscoreRe = RegExp(r'[_\uFF3F]+');
final RegExp _glueRe = RegExp(r'\s*[-–—:|]+\s*$');
final RegExp _leadGlueRe = RegExp(r'^\s*[-–—:|]+\s*');
final RegExp _spaceRunRe = RegExp(r'\s{2,}');
final RegExp _bySuffixRe = RegExp(
  r"\s+by\s+(?:[A-Z][\w.'-]*\s+){0,4}[A-Z][\w.'-]*\.?\s*$",
  caseSensitive: false,
);

/// Document extensions recognized when a full filename is passed in.
const _knownExtensions = {
  'epub',
  'pdf',
  'txt',
  'mobi',
  'azw',
  'azw3',
  'rtf',
  'doc',
  'docx',
};

/// Cleans a raw filename-derived title into something presentable.
String cleanBookTitle(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return s;

  // Strip the extension when someone passed a full filename.
  final dot = s.lastIndexOf('.');
  if (dot > 0 &&
      _knownExtensions.contains(s.substring(dot + 1).toLowerCase())) {
    s = s.substring(0, dot);
  }

  // Underscores are word separators in scraped filenames; spaces first so the
  // site tokens written either way both match.
  s = s.replaceAll(_siteNoiseRe, ' ');
  s = s.replaceAll(_formatTagRe, ' ');
  s = s.replaceAll(_underscoreRe, ' ');

  // Drop "by John A. Doe" author tails only when enough title remains.
  final byMatch = _bySuffixRe.firstMatch(s);
  if (byMatch != null && byMatch.start >= 6) {
    s = s.substring(0, byMatch.start);
  }

  s = s
      .replaceAll(_leadGlueRe, '')
      .replaceAll(_glueRe, '')
      .replaceAll(_spaceRunRe, ' ')
      .trim()
      .replaceAll(RegExp(r'^[\W_]+|[\W_]+$'), '');

  // All-caps scraped titles are unreadable; sentence-case them.
  if (s.length > 3 && s == s.toUpperCase() && RegExp(r'[A-Z]{4}').hasMatch(s)) {
    s = s[0] + s.substring(1).toLowerCase();
  }
  return s;
}

extension BookDisplayTitle on Book {
  /// Cleaned display title; memoized to avoid re-running regex on every access.
  String get displayTitle =>
      _displayTitleCache[title] ??= cleanBookTitle(title);
}
