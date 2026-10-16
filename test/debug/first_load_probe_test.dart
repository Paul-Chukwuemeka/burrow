// DIAGNOSTIC PROBE — not a unit test.
//
// Symptom under investigation: "on first load, extracting metadata for 433
// books/docs — the whole app freezes/slows down".
//
// This drives a genuine first load over a large real library through the real
// code path (LibraryService.startBackgroundScan -> importFileFast ->
// metadata queue -> engine -> Rust FFI) and measures two things:
//
//   1. UI-isolate responsiveness: a 5ms heartbeat timer runs on the same
//      isolate Flutter uses for the UI. A gap between ticks is wall-clock time
//      during which the app could not service frames or input. That is the
//      "freeze" in measurable form.
//   2. Throughput: how long the import and extraction phases take.
//
// Run:
//   BURROW_PROBE=1 flutter test test/debug/first_load_probe_test.dart
//   BURROW_PROBE_LIB=/tmp/opencode/lib433   (default)
//   BURROW_PROBE_LIMIT=50                   (default: all files)
//
// Skipped unless BURROW_PROBE=1 so the normal suite is unaffected.
import 'dart:async';
import 'dart:io';

import 'package:burrow/db/database.dart';
import 'package:burrow/services/library_service.dart';
import 'package:burrow/src/rust/frb_generated.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final enabled = Platform.environment['BURROW_PROBE'] == '1';
  final libDir = Platform.environment['BURROW_PROBE_LIB'] ?? '/tmp/opencode/lib433';
  final limit = int.tryParse(Platform.environment['BURROW_PROBE_LIMIT'] ?? '') ?? (1 << 30);
  // Optional regex on the filename, e.g. '\.pdf$' to price one format alone.
  final match = Platform.environment['BURROW_PROBE_MATCH'];

  test('first-load probe: scan + import + metadata extraction', () async {
    await RustLib.init();

    final paths = Directory(libDir)
        .listSync()
        .whereType<File>()
        .map((f) => f.path)
        .where((p) => RegExp(r'\.(epub|pdf|cbz|cbr|txt)$', caseSensitive: false).hasMatch(p))
        .where((p) => match == null || RegExp(match, caseSensitive: false).hasMatch(p))
        .take(limit)
        .toList()
      ..sort();
    // ignore: avoid_print
    print('PROBE library=$libDir match=${match ?? "*"} files=${paths.length}');

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final library = LibraryService()..debugAttachDatabase(db);

    // --- 1. heartbeat on the UI isolate -------------------------------------
    final gaps = <int>[];
    final gapAt = <int, int>{}; // msSinceStart -> gapMs
    final t0 = DateTime.now();
    DateTime? lastTick;
    final hb = Timer.periodic(const Duration(milliseconds: 5), (_) {
      final now = DateTime.now();
      final prev = lastTick;
      if (prev != null) {
        final gap = now.difference(prev).inMilliseconds;
        gaps.add(gap);
        gapAt[now.difference(t0).inMilliseconds] = gap;
      }
      lastTick = now;
    });

    // Per-book cost, attributed by title (the status stream carries it).
    final bookCostMs = <String, int>{};
    DateTime? lastProgress;

    // --- phase timings from the public status stream ------------------------
    final progressIntervals = <int>[];
    DateTime? extractStart, lastEvent;
    var passes = 0;
    var maxPassTotal = 0;
    var completedPasses = 0;
    library.metadataStatus.listen((s) {
      final now = DateTime.now();
      lastEvent = now;
      if (s.type == MetadataStatusType.started) {
        passes++;
        extractStart ??= now;
        if (s.total > maxPassTotal) maxPassTotal = s.total;
      } else if (s.type == MetadataStatusType.progress) {
        extractStart ??= now;
        final prev = lastProgress;
        if (prev != null) progressIntervals.add(now.difference(prev).inMilliseconds);
        lastProgress = now;
      } else if (s.type == MetadataStatusType.completed) {
        completedPasses++;
      }
    });

    library.startBackgroundScan(Future.value(paths));

    // Import phase: until the scan reports idle.
    final importWatch = Stopwatch()..start();
    while (library.isScanning && importWatch.elapsed.inSeconds < 600) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final importMs = importWatch.elapsedMilliseconds;

    // Extraction phase: until no status event for 3s (queue drained).
    final extractWatch = Stopwatch()..start();
    while (extractWatch.elapsed.inSeconds < 900) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final lastEv = lastEvent;
      if (completedPasses > 0 &&
          lastEv != null &&
          DateTime.now().difference(lastEv).inMilliseconds > 3000) {
        break;
      }
    }
    final extractMs = extractWatch.elapsedMilliseconds;
    hb.cancel();
    final totalMs = DateTime.now().difference(t0).inMilliseconds;

    // --- stats ---------------------------------------------------------------
    final sorted = [...gaps]..sort();
    int pct(double q) => sorted.isEmpty ? 0 : sorted[((sorted.length - 1) * q).round()];
    final over100 = gaps.where((g) => g > 100).length;
    final over500 = gaps.where((g) => g > 500).length;
    final over1000 = gaps.where((g) => g > 1000).length;
    final incomplete = library.books.where((b) => !b.metadataComplete).length;

    final topGaps = gapAt.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final gapLines = topGaps
        .take(6)
        .map((e) => '  +${e.key}ms  gap=${e.value}ms  (${e.key <= importMs ? 'import' : 'extract'})')
        .join('\n');
    final pSorted = [...progressIntervals]..sort();
    int ppct(double q) => pSorted.isEmpty ? 0 : pSorted[((pSorted.length - 1) * q).round()];

    // ignore: avoid_print
    print('''
================ PROBE VERDICT ================
files               = ${paths.length}
books imported      = ${library.books.length}
metadata incomplete = $incomplete
total_ms            = $totalMs
import_ms           = $importMs
extract_ms          = $extractMs
ms_per_book_extract = ${library.books.isEmpty ? 0 : (extractMs / library.books.length).toStringAsFixed(1)}
passes              = $passes (completed: $completedPasses, max pass size: $maxPassTotal)
tick_gap_ms         = p50 ${pct(0.5)} | p95 ${pct(0.95)} | p99 ${pct(0.99)} | max ${sorted.isEmpty ? 0 : sorted.last}
gaps_over_100ms     = $over100
gaps_over_500ms     = $over500   (>=0.5s the UI could not paint)
gaps_over_1000ms    = $over1000  (>=1s = the "freeze")
progress_interval_ms= p50 ${ppct(0.5)} | p95 ${ppct(0.95)} | max ${pSorted.isEmpty ? 0 : pSorted.last}
largest UI gaps (time since start):
$gapLines
===============================================
''');

    library.dispose();
    db.close();
  }, timeout: const Timeout(Duration(minutes: 30)), skip: enabled ? null : 'set BURROW_PROBE=1 to run the load probe');
}
