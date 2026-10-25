// DIAGNOSTIC PROBE — not a unit test.
//
// Symptom under investigation: "some epubs freeze on the laying out pages
// screen". The reader delays first paint until the WHOLE book is paginated
// (deliberate product choice). Each frame of that pass runs one
// `ChapterPaginationDriver.nextChunkUntil` batch inside a post-frame callback,
// so any single batch that blocks for seconds is wall-clock time during which
// the app cannot paint or accept input — the "freeze" in measurable form.
//
// This opens each book through the real ReaderScreen (real Rust parse, real
// settings, real driver parameters) and records, per frame: wall time of
// `tester.pump()`. A sustained 60fps pass shows ~0-12ms pumps; a frozen book
// shows one or more multi-second pumps, or never settles at all.
//
// Run:
//   BURROW_PAG_PROBE=1 flutter test test/debug/reader_layout_probe_test.dart
//   BURROW_PAG_PROBE_BOOKS=/path/a.epub:/path/b.epub   (default: *.epub in dir)
//   BURROW_PAG_PROBE_DIR=/home/paul/output              (default)
//   BURROW_PAG_PROBE_BUDGET_MS=180000                   (per-book settle budget)
//
// Verdict per book (printed as a table row):
//   OK    settled, no frame > 500ms
//   PAUSE settled, worst frame 500ms..2s
//   FREEZE worst frame > 2s (or never settled within the budget)
//
// Skipped unless BURROW_PAG_PROBE=1 so the normal suite is unaffected.
import 'dart:io';

import 'package:burrow/db/database.dart' as db;
import 'package:burrow/models/book.dart';
import 'package:burrow/screens/reader_screen.dart';
import 'package:burrow/services/brightness_controller.dart';
import 'package:burrow/services/library_service.dart';
import 'package:burrow/src/rust/frb_generated.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

/// Keeps the wakelock plugin out of widget tests.
class _FakeWakelock extends WakelockPlusPlatformInterface {
  bool _on = false;

  @override
  Future<void> toggle({required bool enable}) async => _on = enable;

  @override
  Future<bool> get enabled async => _on;
}

ReaderScreenState _readerState(WidgetTester tester) =>
    tester.state<ReaderScreenState>(find.byType(ReaderScreen));

void main() {
  final enabled = Platform.environment['BURROW_PAG_PROBE'] == '1';
  final dir = Platform.environment['BURROW_PAG_PROBE_DIR'] ?? '/home/paul/output';
  final budgetMs =
      int.tryParse(Platform.environment['BURROW_PAG_PROBE_BUDGET_MS'] ?? '') ??
      180000;
  final listed = Platform.environment['BURROW_PAG_PROBE_BOOKS'];

  final books = listed != null
      ? listed.split(':').where((p) => p.isNotEmpty).toList()
      : Directory(dir)
            .listSync()
            .whereType<File>()
            .map((f) => f.path)
            .where((p) => p.toLowerCase().endsWith('.epub'))
            .toList()
        ..sort();

  if (!enabled) {
    test('reader layout probe (disabled)', () {
      // ignore: avoid_print
      print('Skipped: set BURROW_PAG_PROBE=1 to run.');
    });
    return;
  }

  setUpAll(() async {
    await RustLib.init();
  });

  for (final path in books) {
    final name = path.split('/').last;
    testWidgets('layout probe: $name', timeout: const Timeout(Duration(minutes: 4)), (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      WakelockPlusPlatformInterface.instance = _FakeWakelock();
      BrightnessController.instance = BrightnessController(
        getCurrent: () async => 0.5,
        setBrightness: (_) async {},
        resetBrightness: () async {},
      );

      // ignore: avoid_print
      print('PROBE-SETUP $name step=tmp-dir');
      final tmp = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('burrow_pag_probe'),
      ))!;
      final book = Book(
        id: 'probe',
        title: name,
        author: 'probe',
        path: path,
        format: BookFormat.epub,
        addedAt: 0,
      );
      // Real file IO / drift work must run on the real event loop — awaiting it
      // in the fake-async zone deadlocks the test body.
      // ignore: avoid_print
      print('PROBE-SETUP $name step=db-open-insert');
      final database = (await tester.runAsync(() async {
        final database = db.AppDatabase.forTesting(NativeDatabase.memory());
        await database.insertBook(db.bookToCompanion(book));
        return database;
      }))!;
      final library = LibraryService()
        ..debugAttachDatabase(database)
        ..debugAddAll([book]);
      // ignore: avoid_print
      print('PROBE-SETUP $name step=pump-widget');

      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        BrightnessController.instance = BrightnessController();
        await tester.runAsync(() => database.close());
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });

      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(412, 915);
      addTearDown(tester.view.reset);

      // ---- parse phase (real isolate: needs runAsync to progress) -----------
      final parseWatch = Stopwatch()..start();
      await tester.pumpWidget(
        MaterialApp(home: ReaderScreen(book: book, library: library)),
      );
      // ignore: avoid_print
      print('PROBE-SETUP $name step=pump-widget-done');
      var parsed = false;
      final parseLoopWatch = Stopwatch()..start();
      for (var i = 0; i < 1000; i++) {
        if (_readerState(tester).debugHasDocument) {
          parsed = true;
          break;
        }
        if (i % 100 == 0) {
          // ignore: avoid_print
          print(
            'PROBE-ALIVE $name phase=parse i=$i '
            'elapsed=${parseLoopWatch.elapsedMilliseconds}ms',
          );
        }
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      final parseMs = parseWatch.elapsedMilliseconds;
      if (!parsed) {
        // ignore: avoid_print
        print('PROBE-RESULT $name verdict=PARSE-HANG parse_ms=$parseMs');
        fail('$name: document never parsed (parse_ms=$parseMs)');
      }

      // Kick the pagination pass off (its LayoutBuilder starts it post-frame).
      // ignore: avoid_print
      print('PROBE-PHASE $name phase=kick-pumps parse_ms=$parseMs');
      await tester.pump();
      await tester.pump();
      // ignore: avoid_print
      print(
        'PROBE-PHASE $name phase=pagination-start '
        'running=${_readerState(tester).debugPaginationRunning} '
        'lazy=${_readerState(tester).debugLazyRunning} '
        'controller=${_readerState(tester).debugHasController}',
      );

      // ---- pagination phase ------------------------------------------------
      final settleWatch = Stopwatch()..start();
      var frames = 0;
      var worstMs = 0;
      var over500 = 0;
      var over2000 = 0;
      final exceptions = <String>[];
      var settled = false;
      while (settleWatch.elapsedMilliseconds < budgetMs) {
        final state = _readerState(tester);
        if (!state.debugPaginationRunning &&
            !state.debugLazyRunning &&
            state.debugHasController) {
          settled = true;
          break;
        }
        final frameWatch = Stopwatch()..start();
        await tester.pump();
        final ms = frameWatch.elapsedMilliseconds;
        if (ms > worstMs) worstMs = ms;
        if (ms > 500) over500++;
        if (ms > 2000) over2000++;
        if (ms > 500) {
          // ignore: avoid_print
          print('PROBE-FRAME $name frame=$frames ${ms}ms');
        }
        frames++;
        if (frames % 100 == 0) {
          // ignore: avoid_print
          print(
            'PROBE-ALIVE $name phase=pagination frame=$frames '
            'elapsed=${settleWatch.elapsedMilliseconds}ms '
            'running=${state.debugPaginationRunning} '
            'lazy=${state.debugLazyRunning} '
            'controller=${state.debugHasController} worst=${worstMs}ms',
          );
        }
        final e = tester.takeException();
        if (e != null) {
          exceptions.add('frame $frames: $e');
          if (exceptions.length > 3) break;
        }
      }
      final settleMs = settleWatch.elapsedMilliseconds;

      final verdict = !settled
          ? 'FREEZE(no-settle)'
          : over2000 > 0
          ? 'FREEZE(${over2000}x>2s)'
          : over500 > 0
          ? 'PAUSE($over500 x>500ms)'
          : 'OK';
      // ignore: avoid_print
      print(
        'PROBE-RESULT $name verdict=$verdict parse_ms=$parseMs settle_ms=$settleMs '
        'frames=$frames worst_frame_ms=$worstMs over500=$over500 '
        'exceptions=${exceptions.length}',
      );
      if (exceptions.isNotEmpty) {
        fail('$name: exceptions during pagination:\n${exceptions.join('\n')}');
      }
      expect(settled, isTrue, reason: '$name never settled within ${budgetMs}ms');
    });
  }
}
