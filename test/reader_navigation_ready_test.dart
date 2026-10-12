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

final _marker = RegExp(r'w\d+-\d+-\d+');

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

  testWidgets('turning back into an unlaid chapter shows text, not a blank', (
    tester,
  ) async {
    // Open on the last chapter; the background pass starts at chapter 0 and has
    // not reached chapter 4 yet when the page is turned.
    book.lastChapter = 5;
    await mountReader(tester);
    await tester.pump();

    expect(
      _readerState(tester).debugAllReady,
      isFalse,
      reason: 'the background pass must still be running for this test to bite',
    );

    final size = tester.getSize(find.byType(PageView));
    await tester.tapAt(Offset(size.width * 0.15, size.height * 0.5));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      _marker.hasMatch(_visibleText(tester)),
      isTrue,
      reason: 'a page turn into an unlaid chapter must not show a blank page',
    );
  });

  testWidgets('the initial pass lays out only the anchor chapter', (
    tester,
  ) async {
    await mountReader(tester);
    await tester.pump();

    expect(
      _readerState(tester).debugReadyCount,
      1,
      reason: 'the next chapter must be laid out on demand, not before first '
          'paint',
    );
  });
}
