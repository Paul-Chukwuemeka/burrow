// The Dart-vs-Rust EPUB parity differ and divergence ledger (Task 9).
//
// `classify` compares two `ParsedDocument`s field by field — per chapter the
// body, run boundaries/styles, image offsets/`source_key`, and titles, plus
// the book-level metadata — and sorts every difference against the ledger.
// The gate is "zero unclassified diffs", not zero diffs: accepted improvements
// (e.g. Rust deriving untitled-chapter titles) and known Rust bugs are
// recorded with a reason; anything else fails the gate.
//
// Two deliberate blind spots, both structural rather than accidental:
// * `ImageRun.bytes` is excluded: the Rust engine defers bytes across the FFI
//   by reference (D15) and hydrates them on demand, while the Dart engine
//   materialises them at parse time. Comparing bytes would flag every image.
// * `FontFaceInfo.bytes` is excluded for the same reason; families compare by
//   name and `src` only.
import 'dart:convert';

import 'package:burrow/models/style_run.dart';
import 'package:burrow/services/document_parser.dart';
import 'package:burrow/services/epub_css_parser.dart';

import 'epub_engine.dart';

/// One observable Dart-vs-Rust difference.
///
/// [chapter] is the zero-based chapter index, or null for book-level fields
/// (`chapterCount`, `parse`, `metadata.*`). Chapter-level [field] is one of
/// `title`, `body`, `runs`, `images`.
class ParityDiff {
  const ParityDiff({
    required this.fixture,
    required this.chapter,
    required this.field,
    required this.dartValue,
    required this.rustValue,
  });

  final String fixture;
  final int? chapter;
  final String field;
  final String dartValue;
  final String rustValue;

  @override
  bool operator ==(Object other) =>
      other is ParityDiff &&
      other.fixture == fixture &&
      other.chapter == chapter &&
      other.field == field &&
      other.dartValue == dartValue &&
      other.rustValue == rustValue;

  @override
  int get hashCode =>
      Object.hash(fixture, chapter, field, dartValue, rustValue);
}

/// One ledger entry: `{fixture, chapter, field, classification, reason}`.
///
/// [fixture] is a corpus basename or `*` for every fixture; [chapter] is an
/// index or null for any chapter (and always null for book-level fields).
/// [classification] is `bug` or `accepted`.
class LedgerEntry {
  const LedgerEntry({
    required this.fixture,
    required this.chapter,
    required this.field,
    required this.classification,
    required this.reason,
  });

  final String fixture;
  final int? chapter;
  final String field;
  final String classification;
  final String reason;

  /// True when this entry classifies [diff]. The first matching entry in
  /// ledger order supplies the reported reason, so fixture-specific entries
  /// must precede `*` wildcards.
  bool matches(ParityDiff diff) =>
      (fixture == '*' || fixture == diff.fixture) &&
      (chapter == null || chapter == diff.chapter) &&
      field == diff.field;
}

/// The classified comparison of one fixture.
class DiffReport {
  const DiffReport({
    required this.fixture,
    required this.diffs,
    required this.ledger,
  });

  final String fixture;
  final List<ParityDiff> diffs;
  final List<LedgerEntry> ledger;

  /// The ledger entry classifying [diff], or null when it is unclassified.
  LedgerEntry? entryFor(ParityDiff diff) =>
      ledger.where((e) => e.matches(diff)).firstOrNull;

  /// Diffs with no ledger entry. The CI gate requires this to be empty.
  List<ParityDiff> get unclassified =>
      diffs.where((e) => entryFor(e) == null).toList();
}

/// Compares [dart] against [rust] per the parity contract.
///
/// [fixture] is the corpus basename used for ledger matching (e.g.
/// `minimal.epub`).
DiffReport classify(
  ParsedDocument dart,
  ParsedDocument rust, {
  String fixture = '',
  List<LedgerEntry> ledger = const [],
}) {
  final diffs = <ParityDiff>[];
  void diff(int? chapter, String field, String dartValue, String rustValue) {
    if (dartValue != rustValue) {
      diffs.add(
        ParityDiff(
          fixture: fixture,
          chapter: chapter,
          field: field,
          dartValue: dartValue,
          rustValue: rustValue,
        ),
      );
    }
  }

  diff(null, 'metadata.title', dart.title, rust.title);
  diff(null, 'metadata.author', dart.author, rust.author);
  diff(
    null,
    'metadata.description',
    '${dart.description}',
    '${rust.description}',
  );
  diff(null, 'metadata.annotation', '${dart.annotation}', '${rust.annotation}');
  diff(null, 'metadata.language', '${dart.language}', '${rust.language}');
  diff(null, 'metadata.publisher', '${dart.publisher}', '${rust.publisher}');
  diff(null, 'metadata.genre', '${dart.genre}', '${rust.genre}');
  diff(null, 'metadata.isbn', '${dart.isbn}', '${rust.isbn}');
  diff(null, 'metadata.seriesName', '${dart.seriesName}', '${rust.seriesName}');
  diff(
    null,
    'metadata.seriesIndex',
    '${dart.seriesIndex}',
    '${rust.seriesIndex}',
  );
  diff(
    null,
    'metadata.publicationDate',
    '${dart.publicationDate}',
    '${rust.publicationDate}',
  );
  diff(null, 'metadata.rights', '${dart.rights}', '${rust.rights}');
  diff(null, 'metadata.type', '${dart.type}', '${rust.type}');
  diff(null, 'metadata.source', '${dart.source}', '${rust.source}');
  diff(null, 'metadata.titleSort', '${dart.titleSort}', '${rust.titleSort}');
  diff(null, 'metadata.authorSort', '${dart.authorSort}', '${rust.authorSort}');
  diff(
    null,
    'metadata.cover',
    _coverSummary(dart.coverBytes),
    _coverSummary(rust.coverBytes),
  );
  diff(
    null,
    'metadata.fontFaces',
    _fontFacesSummary(dart.fontFaces),
    _fontFacesSummary(rust.fontFaces),
  );

  diff(
    null,
    'chapterCount',
    '${dart.chapters.length}',
    '${rust.chapters.length}',
  );
  final count = dart.chapters.length < rust.chapters.length
      ? dart.chapters.length
      : rust.chapters.length;
  for (var i = 0; i < count; i++) {
    final d = dart.chapters[i];
    final r = rust.chapters[i];
    diff(i, 'title', d.title, r.title);
    // Bodies compare in full; only the reported values are truncated, so a
    // difference past the truncation limit can never slip through the gate.
    if (d.body != r.body) {
      diffs.add(
        ParityDiff(
          fixture: fixture,
          chapter: i,
          field: 'body',
          dartValue: _truncated(d.body),
          rustValue: _truncated(r.body),
        ),
      );
    }
    diff(i, 'runs', _runsSummary(d.runs), _runsSummary(r.runs));
    diff(i, 'images', _imagesSummary(d.images), _imagesSummary(r.images));
  }
  return DiffReport(fixture: fixture, diffs: diffs, ledger: ledger);
}

/// Builds a report for a fixture where one engine failed to parse: a single
/// book-level `parse` diff carrying the error against the other's outcome.
DiffReport classifyParseError({
  required String fixture,
  required String? dartError,
  required String? rustError,
  int? dartChapters,
  int? rustChapters,
  List<LedgerEntry> ledger = const [],
}) {
  return DiffReport(
    fixture: fixture,
    diffs: [
      ParityDiff(
        fixture: fixture,
        chapter: null,
        field: 'parse',
        dartValue: dartError ?? '$dartChapters chapters',
        rustValue: rustError ?? '$rustChapters chapters',
      ),
    ],
    ledger: ledger,
  );
}

/// Parses both engines over [path] and classifies the result, turning a parse
/// failure on either side into a `parse` diff instead of throwing.
Future<DiffReport> compareEngines(
  String path, {
  required EpubEngine dartEngine,
  required EpubEngine rustEngine,
  List<LedgerEntry> ledger = const [],
}) async {
  final fixture = path.split(RegExp(r'[/\\]')).last;
  ParsedDocument? dartDoc;
  String? dartError;
  try {
    dartDoc = await dartEngine.parse(path);
  } catch (e) {
    dartError = '$e';
  }
  ParsedDocument? rustDoc;
  String? rustError;
  try {
    rustDoc = await rustEngine.parse(path);
  } catch (e) {
    rustError = '$e';
  }
  if (dartDoc == null || rustDoc == null) {
    return classifyParseError(
      fixture: fixture,
      dartError: dartError,
      rustError: rustError,
      dartChapters: dartDoc?.chapters.length,
      rustChapters: rustDoc?.chapters.length,
      ledger: ledger,
    );
  }
  return classify(dartDoc, rustDoc, fixture: fixture, ledger: ledger);
}

/// Parses ledger JSON of the shape
/// `{"version":1,"entries":[{fixture,chapter,field,classification,reason}]}`.
///
/// `chapter` is an int index or null (any chapter). Throws [FormatException]
/// on any structural problem, including a classification other than
/// `bug`/`accepted`.
List<LedgerEntry> parseLedger(String jsonText) {
  final decoded = jsonDecode(jsonText);
  if (decoded is! Map || decoded['entries'] is! List) {
    throw const FormatException('ledger must be {version, entries: [...]}');
  }
  final entries = <LedgerEntry>[];
  for (final raw in (decoded['entries'] as List)) {
    if (raw is! Map) {
      throw const FormatException('ledger entry must be an object');
    }
    final fixture = raw['fixture'];
    final field = raw['field'];
    final classification = raw['classification'];
    final reason = raw['reason'];
    final chapter = raw['chapter'];
    if (fixture is! String ||
        field is! String ||
        classification is! String ||
        reason is! String ||
        (chapter != null && chapter is! int)) {
      throw const FormatException(
        'ledger entry needs {fixture, chapter, field, classification, reason}',
      );
    }
    if (classification != 'bug' && classification != 'accepted') {
      throw FormatException('unknown classification: $classification');
    }
    entries.add(
      LedgerEntry(
        fixture: fixture,
        chapter: chapter as int?,
        field: field,
        classification: classification,
        reason: reason,
      ),
    );
  }
  return entries;
}

String _coverSummary(List<int>? bytes) =>
    bytes == null ? '<null>' : '${bytes.length} bytes';

String _fontFacesSummary(Map<String, FontFaceInfo> faces) {
  final keys = faces.keys.toList()..sort();
  return '{${keys.map((k) => '$k@${faces[k]!.src}').join(', ')}}';
}

String _truncated(String s, [int limit = 120]) =>
    'len=${s.length} ${s.length <= limit ? s : '${s.substring(0, limit)}…'}';

String _runsSummary(List<StyleRun> runs) => runs
    .map(
      (r) =>
          '${r.start}-${r.end}:'
          '${r.bold ? 'b' : ''}${r.italic ? 'i' : ''}${r.quote ? 'q' : ''}:'
          '${r.css == null ? '-' : jsonEncode(r.css!.toJson())}',
    )
    .join('|');

String _imagesSummary(List<ImageRun> images) => images
    .map(
      (im) =>
          '@${im.offset} key=${im.sourceKey} ${im.intrinsicWidth}x${im.intrinsicHeight} '
          'alt=${im.alt} fullWidth=${im.fullWidth} id=${im.elementId} '
          'html=${im.htmlWidth}x${im.htmlHeight} src=${im.imgSrc} '
          'class=${im.imgClass} css=${im.css == null ? '-' : jsonEncode(im.css!.toJson())}',
    )
    .join('|');
