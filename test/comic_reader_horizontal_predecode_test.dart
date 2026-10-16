import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
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

final _png = Uint8List.fromList([
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
  0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4,
  0x89, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x44, 0x41,
  0x54, 0x78, 0xda, 0x63, 0x64, 0x60, 0xf8, 0x5f,
  0x0f, 0x00, 0x02, 0x87, 0x01, 0x80, 0xeb, 0x47,
  0xba, 0x92, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45,
  0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
]);

Future<String> _writeCbz(Directory dir, int pages) async {
  final archive = Archive();
  for (var i = 1; i <= pages; i++) {
    archive.addFile(
      ArchiveFile('page${i.toString().padLeft(3, '0')}.png', _png.length, _png),
    );
  }
  final bytes = ZipEncoder().encode(archive);
  final f = File('${dir.path}/comic.cbz');
  await f.writeAsBytes(bytes);
  return f.path;
}

class _FakeWakelock extends WakelockPlusPlatformInterface {
  @override
  Future<void> toggle({required bool enable}) async {}
  @override
  Future<bool> get enabled async => false;
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
    tmp = await Directory.systemTemp.createTemp('burrow_predecode');
    final path = await _writeCbz(tmp, 20);
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    book = Book(
      id: 'c1',
      title: 'Comic',
      author: '',
      path: path,
      format: BookFormat.cbz,
      addedAt: 1,
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

  testWidgets('horizontal flips decode ahead of the visible page', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(412, 915);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(home: ReaderScreen(book: book, library: library)),
    );
    for (var i = 0; i < 100; i++) {
      if (find.byType(PageView).evaluate().isNotEmpty) break;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await tester.pump();
    await tester.pump();

    final state = tester.state<ReaderScreenState>(find.byType(ReaderScreen));
    final ahead = state.debugComicDecodeAhead;
    expect(ahead, isNotNull, reason: 'comic books get a decode-ahead pass');
    await tester.runAsync(() => ahead!.debugIdle);
    await tester.pump();

    // Opened on page 0: the first +-3 window is decoded into the image cache.
    expect(ahead!.debugDecoded, containsAll(const {1, 2, 3}));

    // The PageView surface keeps its neighbours primed as well.
    final controller = tester.widget<PageView>(find.byType(PageView)).controller;
    expect(controller, isNotNull);
    expect(tester.widget<PageView>(find.byType(PageView)).allowImplicitScrolling,
        isTrue);

    // Flip once: the window re-centers and page 4 joins.
    await tester.tapAt(const Offset(380, 450));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(() => ahead.debugIdle);
    await tester.pump();
    expect(ahead.debugDecoded, contains(4));
  });
}
