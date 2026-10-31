// Auto-resume on relaunch: with the toggle on, a cold start opens the most
// recently read, unfinished book straight into the reader; the library stays
// underneath so Back lands where it always has.
import 'dart:io';

import 'package:burrow/db/database.dart' as db;
import 'package:burrow/main.dart';
import 'package:burrow/models/book.dart';
import 'package:burrow/screens/library_screen.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The reader parses through the Rust engine, which needs its FFI binding
  // initialized once per file (there is no Dart fallback anymore).
  setUpAll(() async {
    await RustLib.init();
  });

  late Directory tmp;
  late db.AppDatabase database;
  late LibraryService library;
  late Book mid;
  late Book finished;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    WakelockPlusPlatformInterface.instance = _FakeWakelock();
    BrightnessController.instance = BrightnessController(
      getCurrent: () async => 0.5,
      setBrightness: (_) async {},
      resetBrightness: () async {},
    );

    tmp = await Directory.systemTemp.createTemp('burrow_launch_resume');
    final bookFile = File('${tmp.path}/Mid.txt');
    await bookFile.writeAsString(
      'Chapter one\n'
      '${List.filled(40, 'A paragraph of ordinary prose.').join('\n')}\n'
      '\n\n'
      'Chapter two\n'
      '${List.filled(40, 'More ordinary prose.').join('\n')}\n',
    );
    final finishedFile = File('${tmp.path}/Done.txt');
    await finishedFile.writeAsString('One paragraph. The end.');

    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    library = LibraryService()..debugAttachDatabase(database);

    Book seeded(
      String id, {
      required String path,
      double progress = 0,
      int lastReadAt = 0,
    }) => Book(
      id: id,
      title: 'Book $id',
      author: 'Author $id',
      path: path,
      format: BookFormat.txt,
      addedAt: 1,
      lastReadAt: lastReadAt,
      progress: progress,
    );

    finished = seeded(
      'done',
      progress: 1,
      lastReadAt: 5,
      path: finishedFile.path,
    );
    mid = seeded('mid', progress: 0.25, lastReadAt: 10, path: bookFile.path)
      ..lastChapter = 1;
    library.debugAddAll([finished, mid]);
  });

  tearDown(() async {
    BrightnessController.instance = BrightnessController();
    await database.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<void> pumpBurrow(WidgetTester tester, LibraryService lib) async {
    lib.onboardingComplete = true;
    await tester.pumpWidget(BurrowApp(library: lib, autoScanOnOpen: false));
    await tester.pumpAndSettle();
  }

  testWidgets('with the toggle on, launch lands in the most recent book', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(412, 915);
    addTearDown(tester.view.reset);

    // Toggle on before the app builds: _buildHome must resume from it.
    library.settings.autoResumeOnRelaunch = true;
    // Last exit happened inside the reader (process death with it on screen,
    // or a background kill — no Dart code ran to clear it).
    library.settings.readerOpenAtLastExit = true;

    library.onboardingComplete = true;
    await tester.pumpWidget(BurrowApp(library: library, autoScanOnOpen: false));
    for (var i = 0; i < 100 && find.byType(ReaderScreen).evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }

    // The reader opened with the most recent unfinished book…
    expect(find.byType(ReaderScreen), findsOneWidget);
    final reader =
        tester.state<ReaderScreenState>(find.byType(ReaderScreen)).widget;
    expect(reader.book.id, mid.id);
    expect(reader.book.title, mid.title);
    // …and the library stays underneath, so Back still retrieves a books list.
    expect(find.byType(LibraryScreen), findsOneWidget);

    // The document actually parsed, i.e. the resume is usable, not an error.
    final state = tester.state<ReaderScreenState>(find.byType(ReaderScreen));
    for (var i = 0; i < 100 && !state.debugHasDocument; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(state.debugHasDocument, isTrue);

    // Unwind the route while the library is still alive: the reader's
    // dispose persists settings via notifyListeners, so the end-of-test
    // tree teardown (which disposes the injected service first) must not
    // be the thing unmounting the reader.
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(find.byType(ReaderScreen).evaluate(), isEmpty);

    // Leaving the reader clears the was-open-at-exit flag: a later close from
    // the library must not auto-resume.
    expect(library.settings.readerOpenAtLastExit, isFalse);
  });

  testWidgets('toggle on but reader not open at last exit stays on library', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(412, 915);
    addTearDown(tester.view.reset);
    addTearDown(() => tester.pumpWidget(const SizedBox()));

    // The toggle wants auto-resume, but the last close happened on the
    // library screen (the reader was backed out of before the app exited),
    // so the relaunch must open the library only.
    library.settings.autoResumeOnRelaunch = true;
    library.settings.readerOpenAtLastExit = false;

    await pumpBurrow(tester, library);

    expect(find.byType(LibraryScreen), findsOneWidget);
    expect(find.byType(ReaderScreen).evaluate(), isEmpty);
  });

  testWidgets('with the toggle off (default), launch stays on the library', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(412, 915);
    addTearDown(tester.view.reset);
    addTearDown(() => tester.pumpWidget(const SizedBox()));

    await pumpBurrow(tester, library);

    expect(find.byType(LibraryScreen), findsOneWidget);
    expect(find.byType(ReaderScreen).evaluate(), isEmpty);
  });

  testWidgets('with the toggle on but only a finished book, no reader opens', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(412, 915);
    addTearDown(tester.view.reset);
    addTearDown(() => tester.pumpWidget(const SizedBox()));

    // Fresh library with just the finished file: nothing is resumable.
    final doneOnly = LibraryService()
      ..debugAttachDatabase(database)
      ..debugAddAll([finished]);
    doneOnly.settings.autoResumeOnRelaunch = true;

    await pumpBurrow(tester, doneOnly);

    expect(find.byType(LibraryScreen), findsOneWidget);
    expect(find.byType(ReaderScreen).evaluate(), isEmpty);
  });

  testWidgets('opening the reader marks readerOpenAtLastExit', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(412, 915);
    addTearDown(tester.view.reset);
    addTearDown(() => tester.pumpWidget(const SizedBox()));

    library.settings.readerOpenAtLastExit = false;
    await tester.pumpWidget(
      MaterialApp(home: ReaderScreen(book: mid, library: library)),
    );
    await tester.pump();

    // The reader is on screen: a kill from here (foreground or background)
    // must resume on the next cold start.
    expect(library.settings.readerOpenAtLastExit, isTrue);

    // Let the open finish so teardown isn't stuck cancelling a mid-parse
    // document (same bounded pump the resume test above uses — a bare
    // reader never settles for pumpAndSettle).
    final state = tester.state<ReaderScreenState>(find.byType(ReaderScreen));
    for (var i = 0; i < 100 && !state.debugHasDocument; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(state.debugHasDocument, isTrue);
  });
}
