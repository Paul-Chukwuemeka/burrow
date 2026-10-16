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
  TestWidgetsFlutterBinding.ensureInitialized();

  // The reader parses through the Rust engine, which needs its FFI binding
  // initialized once per file (there is no Dart fallback anymore).
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

    tmp = await Directory.systemTemp.createTemp('burrow_loading_labels');
    final bookFile = File('${tmp.path}/Short Story.txt');
    await bookFile.writeAsString(
      'Chapter one\n'
      '${List.filled(40, 'A paragraph of ordinary prose.').join('\n')}\n'
      '\n\n'
      'Chapter two\n'
      '${List.filled(40, 'More ordinary prose.').join('\n')}\n',
    );

    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    book = Book(
      id: 'b1',
      title: 'Short Story',
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

  testWidgets('opening shows its own label before laying out pages', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(412, 915);
    addTearDown(tester.view.reset);
    addTearDown(() => tester.pumpWidget(const SizedBox()));

    // First frame: the document has not parsed yet, and the bare spinner is
    // labeled as an open, not as pagination.
    await tester.pumpWidget(
      MaterialApp(home: ReaderScreen(book: book, library: library)),
    );
    await tester.pump();
    expect(_readerState(tester).debugHasDocument, isFalse);
    expect(find.text('Opening book…'), findsOneWidget);
    expect(find.text('Laying out pages…'), findsNothing);

    // Once the document is in, the opening label goes away. The layout
    // phase may be too short-lived to catch on a tiny book: the pass can
    // finish within a single frame, so only the swap-out is asserted.
    for (var i = 0; i < 100; i++) {
      if (_readerState(tester).debugHasDocument) break;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(_readerState(tester).debugHasDocument, isTrue);
    expect(find.text('Opening book…'), findsNothing);
  });
}
