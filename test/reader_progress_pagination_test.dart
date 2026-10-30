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

/// Six-chapter body long enough that a single layout pass spans frames.
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

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
    ReaderScreenState.debugSuspendBackgroundFill = false;

    tmp = await Directory.systemTemp.createTemp('burrow_exit_pagination');
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
      lastReadAt: 2000,
      progress: 0.42,
      lastChapter: 5,
      lastOffset: 100,
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

  testWidgets('exiting while the book is still paginating keeps its progress', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(412, 915);
    addTearDown(tester.view.reset);

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

    // Start the initial pass, then freeze it so the reader stays on the
    // "Laying out pages…" view with no PageView and no page controller.
    await tester.pump();
    ReaderScreenState.debugSuspendBackgroundFill = true;
    await tester.pump();
    final state = _readerState(tester);
    expect(state.debugPaginationRunning, isTrue);
    expect(state.debugHasController, isFalse);

    // Leave the reader mid-pagination.
    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    expect(
      book.progress,
      0.42,
      reason: 'exiting mid-layout must not rewrite saved progress',
    );
    expect(book.lastChapter, 5);
    expect(book.lastOffset, 100);
    expect(book.isFinished, isFalse);
  });
}
