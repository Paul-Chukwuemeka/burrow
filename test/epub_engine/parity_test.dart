// Parity harness for the Rust EPUB engine (Task 9).
//
// The gate is "zero unclassified diffs", not zero diffs: `classify` reports
// every observable Dart-vs-Rust difference, and the divergence ledger
// (`test/fixtures/epub/ledger.json`) classifies each known one as `accepted`
// (an improvement, with a reason) or `bug`. CI fails on unclassified diffs.
//
// `RustLib.init()` dlopens the host build from `rust/target/release/`;
// `test/flutter_test_config.dart` builds it on demand. The corpus directory,
// ledger path, and gate flag come from the environment so `tool/epub_parity.dart`
// can drive this suite without code changes:
//   EPUB_PARITY_CORPUS (default `test/fixtures/epub`)
//   EPUB_PARITY_LEDGER (default `test/fixtures/epub/ledger.json`)
//   EPUB_PARITY_FAIL_ON_UNCLASSIFIED (`1` makes the corpus gate fail)
import 'dart:io';
import 'dart:typed_data';

import 'package:burrow/models/style_run.dart';
import 'package:burrow/services/document_parser.dart';
import 'package:burrow/services/epub/dart_epub_engine.dart';
import 'package:burrow/services/epub/epub_parity.dart';
import 'package:burrow/services/epub/rust_epub_engine.dart';
import 'package:burrow/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';

String _env(String key, String fallback) =>
    Platform.environment[key] ?? fallback;

bool get _failOnUnclassified =>
    _env('EPUB_PARITY_FAIL_ON_UNCLASSIFIED', '') == '1';

// The D11 pin and the stale-ledger check only make sense against the committed
// synthetic corpus (with its ledger); the nightly real-book job skips them and
// runs the corpus gate in report mode.
bool get _isSyntheticCorpus =>
    _env('EPUB_PARITY_CORPUS', 'test/fixtures/epub') == 'test/fixtures/epub';

List<LedgerEntry> _loadLedger() {
  final file = File(
    _env('EPUB_PARITY_LEDGER', 'test/fixtures/epub/ledger.json'),
  );
  return parseLedger(file.readAsStringSync());
}

List<String> _corpus() {
  final dir = Directory(_env('EPUB_PARITY_CORPUS', 'test/fixtures/epub'));
  return dir
      .listSync()
      .whereType<File>()
      .map((f) => f.path)
      .where((p) => p.toLowerCase().endsWith('.epub'))
      .toList()
    ..sort();
}

ParsedDocument _doc(String body) => ParsedDocument(
  title: 'T',
  author: 'A',
  chapters: [
    Chapter('One', body, const [], [
      ImageRun(
        offset: 0,
        bytes: Uint8List(0),
        intrinsicWidth: 1,
        intrinsicHeight: 1,
      ),
    ]),
  ],
);

void main() {
  setUpAll(() async {
    await RustLib.init();
  });

  test('differ reports a body mismatch with a ledger classification', () {
    final dartDoc = _doc('Hello.');
    final rustDoc = _doc('Hello!');

    final unledgered = classify(dartDoc, rustDoc, fixture: 'demo.epub');
    expect(unledgered.diffs, isNotEmpty);
    expect(unledgered.unclassified, isNotEmpty);

    final report = classify(
      dartDoc,
      rustDoc,
      fixture: 'demo.epub',
      ledger: const [
        LedgerEntry(
          fixture: 'demo.epub',
          chapter: 0,
          field: 'body',
          classification: 'accepted',
          reason: 'demo pin',
        ),
      ],
    );
    expect(report.unclassified, isEmpty); // after ledger applied
  });

  test('ledger rejects unknown classifications', () {
    expect(
      () => parseLedger(
        '{"version":1,"entries":[{"fixture":"*","chapter":null,'
        '"field":"body","classification":"maybe","reason":"x"}]}',
      ),
      throwsFormatException,
    );
  });

  test(
    'repeated paragraphs style both instances on both engines (spec D11)',
    skip: _isSyntheticCorpus ? false : 'synthetic-corpus only',
    () async {
      // The D11 double-style gap is closed, so there is no runs diff left to
      // ledger: the Dart per-text-cursor cascade (`_mergeCssStyles`) and the
      // Rust selector cascade (`declared_css_runs`) both style each repeated
      // `<p class="note">` exactly once (10-20 and 22-32, identical CSS). This
      // test pins that parity so a regression reopens as an UNCLASSIFIED diff
      // instead of silently passing. The chapter's only diff is its title
      // (Rust derives "Repeated"; Dart leaves it empty), covered by the
      // wildcard title ledger entry.
      const path = 'test/fixtures/epub/repeated-paragraphs.epub';
      final report = await compareEngines(
        path,
        dartEngine: const DartEpubEngine(),
        rustEngine: const RustEpubEngine(),
        ledger: _loadLedger(),
      );
      expect(
        report.diffs.where((d) => d.field == 'runs'),
        isEmpty,
        reason: 'D11 runs parity holds (both engines style both paragraphs)',
      );
      expect(report.unclassified, isEmpty);
    },
  );

  test('synthetic corpus has zero unclassified diffs', () async {
    final ledger = _loadLedger();
    const dartEngine = DartEpubEngine();
    const rustEngine = RustEpubEngine();
    final unclassified = <ParityDiff>[];
    var diffCount = 0;
    for (final path in _corpus()) {
      final report = await compareEngines(
        path,
        dartEngine: dartEngine,
        rustEngine: rustEngine,
        ledger: ledger,
      );
      diffCount += report.diffs.length;
      unclassified.addAll(report.unclassified);
      for (final diff in report.diffs) {
        final entry = report.entryFor(diff);
        // ignore: avoid_print, the gate report is the point of this test.
        print(
          '${diff.fixture} ch${diff.chapter?.toString() ?? '-'} '
          '${diff.field}: dart=${diff.dartValue} rust=${diff.rustValue} '
          '-> ${entry == null ? 'UNCLASSIFIED' : '${entry.classification} (${entry.reason})'}',
        );
      }
    }
    // ignore: avoid_print, the gate summary is the point of this test.
    print(
      'parity: ${_corpus().length} fixtures, $diffCount diffs, '
      '${unclassified.length} unclassified',
    );
    if (_failOnUnclassified) {
      expect(unclassified, isEmpty, reason: 'unclassified parity diffs');
    }
  });

  test(
    'every ledger entry matches at least one corpus diff',
    skip: _isSyntheticCorpus ? false : 'synthetic-corpus only',
    () async {
      final ledger = _loadLedger();
      const dartEngine = DartEpubEngine();
      const rustEngine = RustEpubEngine();
      final diffs = <ParityDiff>[];
      for (final path in _corpus()) {
        diffs.addAll(
          (await compareEngines(
            path,
            dartEngine: dartEngine,
            rustEngine: rustEngine,
            ledger: ledger,
          )).diffs,
        );
      }
      final stale = ledger.where((e) => !diffs.any(e.matches)).toList();
      expect(stale, isEmpty, reason: 'stale ledger entries');
    },
  );
}
