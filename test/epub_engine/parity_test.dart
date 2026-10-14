// Parity harness for the Rust EPUB engine (Task 9).
//
// The gate is "zero unclassified diffs AND zero bug diffs": `classify` reports
// every observable Dart-vs-Rust difference, and the divergence ledger
// (`test/fixtures/epub/ledger.json`) classifies each known one as `accepted`
// (an improvement, with a reason) or `bug`. CI fails on unclassified diffs
// and on `bug` diffs alike (design D7: a Rust bug blocks); only `accepted`
// passes. A bare `flutter test` enforces the gate — report-only mode is an
// explicit opt-out (`EPUB_PARITY_REPORT_ONLY=1`), so a flagless run can never
// give false confidence.
//
// `RustLib.init()` dlopens the host build from `rust/target/release/`;
// `test/flutter_test_config.dart` builds it on demand. The corpus directory,
// ledger path, and gate flags come from the environment so `tool/epub_parity.dart`
// can drive this suite without code changes:
//   EPUB_PARITY_CORPUS (default `test/fixtures/epub`)
//   EPUB_PARITY_LEDGER (default `test/fixtures/epub/ledger.json`)
//   EPUB_PARITY_FAIL_ON_UNCLASSIFIED (`1` also forces the gate; strictness is
//     now the default, so this is a deprecated no-op alias)
//   EPUB_PARITY_REPORT_ONLY (`1` runs the corpus gate in report mode: prints
//     every diff but never fails — the nightly real-book job's mode)
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

// Report mode is an explicit opt-out: without it the gate always fails on
// unclassified AND bug diffs, so a bare `flutter test` cannot pass vacuously.
bool get _reportOnly => _env('EPUB_PARITY_REPORT_ONLY', '') == '1';

// The D11 pin and the stale-ledger check only make sense against the committed
// synthetic corpus (with its ledger); the nightly real-book job skips them and
// runs the corpus gate in report mode. Tolerates a trailing slash and an
// absolute path so the check cannot be dodged by spelling.
bool get _isSyntheticCorpus {
  final raw = _env('EPUB_PARITY_CORPUS', 'test/fixtures/epub');
  final norm = raw.replaceAll(RegExp(r'[/\\]+$'), '');
  return norm == 'test/fixtures/epub' ||
      norm.endsWith('/test/fixtures/epub') ||
      norm.endsWith(r'\test\fixtures\epub');
}

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

ParsedDocument _doc(String body) => _docWithTitle('One', body);

ParsedDocument _docWithTitle(String title, String body) => ParsedDocument(
  title: 'T',
  author: 'A',
  chapters: [
    Chapter(title, body, const [], [
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

  test('bug diffs fail the gate and value predicates scope wildcards', () {
    // A `bug`-classified diff is NOT unclassified, but it is still a gate
    // failure (design D7): `bugs` must surface it.
    final buggy = classify(
      _doc('Hello.'),
      _doc('Hello!'),
      fixture: 'demo.epub',
      ledger: const [
        LedgerEntry(
          fixture: 'demo.epub',
          chapter: 0,
          field: 'body',
          classification: 'bug',
          reason: 'known gap',
        ),
      ],
    );
    expect(buggy.unclassified, isEmpty);
    expect(buggy.bugs, hasLength(1));

    // The TOC-less title wildcard requires an empty Dart title: a title
    // regression on a TOC chapter (non-empty Dart title) must NOT match it,
    // so it surfaces as UNCLASSIFIED instead of hiding.
    const scoped = LedgerEntry(
      fixture: '*',
      chapter: null,
      field: 'title',
      classification: 'accepted',
      reason: 'TOC-less derivation',
      dartValue: '',
    );
    final derived = classify(
      _docWithTitle('', 'body'),
      _docWithTitle('Derived', 'body'),
      fixture: 'demo.epub',
      ledger: const [scoped],
    );
    expect(derived.unclassified, isEmpty);
    final regressed = classify(
      _docWithTitle('Real Title', 'body'),
      _docWithTitle('Wrong Title', 'body'),
      fixture: 'demo.epub',
      ledger: const [scoped],
    );
    expect(regressed.unclassified, hasLength(1));
    expect(regressed.bugs, isEmpty);
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
    final bugs = <ParityDiff>[];
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
      bugs.addAll(report.bugs);
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
      '${unclassified.length} unclassified, ${bugs.length} bug',
    );
    // Strict by default: a bare `flutter test` enforces the gate. Only an
    // explicit `EPUB_PARITY_REPORT_ONLY=1` (the nightly real-book job) prints
    // without failing. `EPUB_PARITY_FAIL_ON_UNCLASSIFIED=1` is kept as a
    // deprecated alias that also forces strictness.
    if (!_reportOnly || _failOnUnclassified) {
      expect(unclassified, isEmpty, reason: 'unclassified parity diffs');
      expect(bugs, isEmpty, reason: 'known-bug parity diffs (design D7)');
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
