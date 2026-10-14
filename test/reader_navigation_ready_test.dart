import 'dart:io';

import 'package:burrow/db/database.dart' as db;
import 'package:burrow/models/book.dart';
import 'package:burrow/screens/reader_screen.dart';
import 'package:burrow/services/brightness_controller.dart';
import 'package:burrow/services/library_service.dart';
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

/// Six-chapter body long enough that layout cannot finish in one frame.
String _bookText() {
  final b = StringBuffer();
  for (var c = 1; c <= 6; c++) {
    b.writeln('Chapter $c');
    for (var p = 0; p < 24; p++) {
      b.writeln(
        'Para $c.$p opens here. '
        '${List.generate(45, (i) => 'w$c-$p-$i').join(' ')}',
      );
    }
    b.write('\n\n\n\n');
  }
  return b.toString();
}

ReaderScreenState _readerState(WidgetTester tester) =>
    tester.state<ReaderScreenState>(find.byType(ReaderScreen));

/// Body text of the page currently on screen.
String _visibleText(WidgetTester tester) {
  final buffer = StringBuffer();
  for (final rt in tester.widgetList<RichText>(find.byType(RichText))) {
    buffer.write(rt.text.toPlainText());
  }
  return buffer.toString();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late db.AppDatabase database;
  late LibraryService library;
  late Book book;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    WakelockPlusPlatformInterface.instance = _FakeWakelock();
    BrightnessController.instance = BrightnessController(
      getCurrent: () async => 0.5,
      setBrightness: (_) async {},
      resetBrightness: () async {},
    );
    // The background pass is suspended per-test so "not yet laid out" is
    // deterministic instead of racing the frame budget.
    ReaderScreenState.debugSuspendBackgroundFill = false;

    tmp = await Directory.systemTemp.createTemp('burrow_nav_ready');
    final bookFile = File('${tmp.path}/Long Book.txt');
    await bookFile.writeAsString(_bookText());

    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    book = Book(
      id: 'b1',
      title: 'Long Book',
      author: 'Author',
      path: bookFile.path,
      format: BookFormat.txt,
      addedAt: 1000,
    );
    library = LibraryService()
      ..debugAttachDatabase(database)
      ..debugAddAll([book]);
    await database.insertBook(db.bookToCompanion(book));
  });

  tearDown(() async {
    ReaderScreenState.debugSuspendBackgroundFill = false;
    BrightnessController.instance = BrightnessController();
    await database.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// Mount the reader and wait for the document to parse, without waiting for
  /// the background layout pass to finish.
  Future<void> mountReader(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(412, 915);
    addTearDown(tester.view.reset);
    addTearDown(() => tester.pumpWidget(const SizedBox()));

    await tester.pumpWidget(
      MaterialApp(home: ReaderScreen(book: book, library: library)),
    );
    for (var i = 0; i < 100; i++) {
      if (_readerState(tester).debugHasDocument) break;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(
      _readerState(tester).debugHasDocument,
      isTrue,
      reason: 'document should have parsed',
    );
    // LayoutBuilder kicks off the first pass in a post-frame callback.
    await tester.pump();
    await tester.pump();
  }

  /// Pump until the full-book pagination pass finishes and the reader paints.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4000; i++) {
      final s = _readerState(tester);
      if (!s.debugLazyRunning && s.debugHasController) break;
      await tester.pump();
    }
    await tester.pump();
  }

  testWidgets('the initial pass lays out the whole book before the first paint', (
    tester,
  ) async {
    await mountReader(tester);
    await tester.pump();

    // The full pass is chunked across frames, so nothing has painted yet: no
    // page view and the book is not fully laid out.
    expect(
      find.byType(PageView),
      findsNothing,
      reason: 'no pages paint until the whole book is paginated',
    );
    expect(_readerState(tester).debugAllReady, isFalse);

    await settle(tester);
    expect(find.byType(PageView), findsOneWidget);
    expect(_readerState(tester).debugAllReady, isTrue);
    expect(
      _readerState(tester).debugReadyCount,
      _readerState(tester).debugChapterCount,
      reason: 'every chapter is laid out before the first paint',
    );
  });

  testWidgets('opening on the last chapter and turning back works', (
    tester,
  ) async {
    book.lastChapter = 5;
    await mountReader(tester);
    await settle(tester);

    final size = tester.getSize(find.byType(PageView));
    await tester.tapAt(Offset(size.width * 0.15, size.height * 0.5));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // A backward turn keeps reading order: it must land on the END of the
    // previous chapter ("Chapter 5" = index 4, markers w5-*), not its start.
    expect(
      _visibleText(tester),
      contains('w5-23'),
      reason: 'a backward page turn must show the previous page',
    );
  });

  testWidgets('turning within a laid-out chapter lays out nothing new', (
    tester,
  ) async {
    await mountReader(tester);
    await settle(tester);

    final before = _readerState(tester).debugSyncLayouts;
    final size = tester.getSize(find.byType(PageView));
    await tester.tapAt(Offset(size.width * 0.85, size.height * 0.5));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      _readerState(tester).debugSyncLayouts,
      before,
      reason: 'a turn within a ready chapter must not re-lay it out',
    );
  });
}
