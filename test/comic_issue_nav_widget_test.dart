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

Future<String> _writeCbz(Directory dir, int pages, String name) async {
  final archive = Archive();
  for (var i = 1; i <= pages; i++) {
    archive.addFile(
      ArchiveFile('page${i.toString().padLeft(3, '0')}.png', _png.length, _png),
    );
  }
  final f = File('${dir.path}/$name.cbz')
    ..writeAsBytesSync(ZipEncoder().encode(archive));
  return f.path;
}

class _FakeWakelock extends WakelockPlusPlatformInterface {
  @override
  Future<void> toggle({required bool enable}) async {}
  @override
  Future<bool> get enabled async => false;
}

/// Pumps [book] into the reader and waits for the PageView, then reveals the
/// bottom chrome by tapping the center tap zone.
Future<ReaderScreenState> _pumpComic(
  WidgetTester tester,
  LibraryService library,
  Book book,
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

  await tester.tapAt(const Offset(206, 450));
  await tester.pump(const Duration(milliseconds: 300));

  return tester.state<ReaderScreenState>(find.byType(ReaderScreen));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late db.AppDatabase database;
  late LibraryService library;
  late Book issue1;
  late Book issue2;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    WakelockPlusPlatformInterface.instance = _FakeWakelock();
    BrightnessController.instance = BrightnessController(
      getCurrent: () async => 0.5,
      setBrightness: (_) async {},
      resetBrightness: () async {},
    );
    tmp = await Directory.systemTemp.createTemp('burrow_issue_nav');
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    library = LibraryService()..debugAttachDatabase(database);
  });

  Future<List<Book>> addSeries() async {
    final path1 = await _writeCbz(tmp, 20, 'Batman 001');
    final path2 = await _writeCbz(tmp, 20, 'Batman 002');
    issue1 = Book(
      id: 'c1',
      title: 'Batman 001',
      author: '',
      path: path1,
      format: BookFormat.cbz,
      addedAt: 1,
      seriesName: 'Batman',
      seriesIndex: 1,
    );
    issue2 = Book(
      id: 'c2',
      title: 'Batman 002',
      author: '',
      path: path2,
      format: BookFormat.cbz,
      addedAt: 2,
      seriesName: 'Batman',
      seriesIndex: 2,
    );
    library.debugAddAll([issue1, issue2]);
    await database.insertBook(db.bookToCompanion(issue1));
    await database.insertBook(db.bookToCompanion(issue2));
    return [issue1, issue2];
  }

  tearDown(() async {
    BrightnessController.instance = BrightnessController();
    await database.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  testWidgets('chrome shows issue label and issue nav buttons for a series',
      (tester) async {
    final books = await addSeries();
    await _pumpComic(tester, library, books.first);

    expect(find.textContaining('Issue 1 of 2'), findsOneWidget);
    expect(find.byIcon(Icons.skip_previous_rounded), findsOneWidget);
    expect(find.byIcon(Icons.skip_next_rounded), findsOneWidget);
  });

  testWidgets('chrome issue buttons only appear for comics in a series',
      (tester) async {
    final path = await _writeCbz(tmp, 20, 'Random Comic');
    final lone = Book(
      id: 'solo',
      title: 'Random Comic',
      author: '',
      path: path,
      format: BookFormat.cbz,
      addedAt: 1,
    );
    library.debugAddAll([lone]);
    await database.insertBook(db.bookToCompanion(lone));

    await _pumpComic(tester, library, lone);

    expect(find.textContaining('Issue'), findsNothing);
    expect(find.byIcon(Icons.skip_previous_rounded), findsNothing);
    expect(find.byIcon(Icons.skip_next_rounded), findsNothing);
  });

  testWidgets('next issue is disabled when the reader is on the final issue',
      (tester) async {
    final books = await addSeries();
    await _pumpComic(tester, library, books.last);

    final next = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.skip_next_rounded),
    );
    final prev = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.skip_previous_rounded),
    );
    expect(next.onPressed, isNull);
    expect(prev.onPressed, isNotNull);
  });

  testWidgets('tapping next issue swaps the reader to the following issue',
      (tester) async {
    final books = await addSeries();
    final state = await _pumpComic(tester, library, books.first);
    expect(state.widget.book.id, 'c1');

    await tester.tap(find.byIcon(Icons.skip_next_rounded));
    await _waitUntilReaderShows(tester, 'c2');

    expect(find.byType(ReaderScreen), findsOneWidget);
    expect(_readerState(tester)!.widget.book.id, 'c2');
  });

  testWidgets('reaching the last page of a non-final issue offers the next one',
      (tester) async {
    final books = await addSeries();
    await _pumpComic(tester, library, books.first);

    // Jump to the last page by dragging the chrome page slider to its far
    // end (drag, not tap: the Slider in tests responds to drags).
    final slider = find.byType(Slider).last;
    final rect = tester.getRect(slider);
    final gesture = await tester.startGesture(rect.center);
    await tester.pump();
    await gesture.moveBy(Offset(rect.width / 2 * 1.9, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 500));

    // The popup names the next issue...
    expect(find.textContaining('Batman 002'), findsOneWidget);
    // ...and tapping it swaps the reader to that issue. The banner is still
    // on screen mid-transition, so resolve by element identity.
    await tester.tap(find.textContaining('Batman 002'));
    await _waitUntilReaderShows(tester, 'c2');
    expect(_readerState(tester)!.widget.book.id, 'c2');
  });

  testWidgets('the final issue of a series never offers a popup',
      (tester) async {
    final books = await addSeries();
    await _pumpComic(tester, library, books.last);

    final slider = find.byType(Slider).last;
    final rect = tester.getRect(slider);
    final gesture = await tester.startGesture(rect.center);
    await tester.pump();
    await gesture.moveBy(Offset(rect.width / 2 * 1.9, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(ReaderScreen), findsOneWidget);
    expect(tester.state<ReaderScreenState>(find.byType(ReaderScreen))
        .debugComicPage, 19);
    expect(find.textContaining('Next:'), findsNothing);
  });

  testWidgets('a reader opened straight onto the last page stays clean',
      (tester) async {
    final books = await addSeries();
    // Resume position: the first issue was left on its final page.
    books.first.lastChapter = 19;
    await _pumpComic(tester, library, books.first);

    expect(
      tester.state<ReaderScreenState>(find.byType(ReaderScreen))
          .debugComicPage,
      19,
    );
    expect(find.textContaining('Next:'), findsNothing);
  });

  testWidgets('tapping previous issue returns to the earlier issue',
      (tester) async {
    final books = await addSeries();
    final state = await _pumpComic(tester, library, books.last);
    expect(state.widget.book.id, 'c2');

    await tester.tap(find.byIcon(Icons.skip_previous_rounded));
    await _waitUntilReaderShows(tester, 'c1');

    expect(find.byType(ReaderScreen), findsOneWidget);
    expect(_readerState(tester)!.widget.book.id, 'c1');
  });
}

/// Pumps until a [ReaderScreen] whose widget shows a [Book] with [bookId] is
/// in the tree, then pumps through the remaining route transition.
Future<void> _waitUntilReaderShows(WidgetTester tester, String bookId) async {
  for (var i = 0; i < 120; i++) {
    final matches = find
        .byType(ReaderScreen)
        .evaluate()
        .any((e) => (e.widget as ReaderScreen).book.id == bookId);
    if (matches) {
      // Finish the route transition so the outgoing reader is disposed.
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      return;
    }
    await tester.pump(const Duration(milliseconds: 50));
  }
  fail('reader never showed $bookId');
}

/// The ReaderScreen's state, tolerating the outgoing route during the swap
/// transition (the first match at the top of the stack).
ReaderScreenState? _readerState(WidgetTester tester) {
  final readers = find.byType(ReaderScreen).evaluate();
  if (readers.isEmpty) return null;
  return tester.state<ReaderScreenState>(
    find.byElementPredicate((e) => e == readers.last, skipOffstage: false),
  );
}
