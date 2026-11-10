import 'package:burrow/db/database.dart';
import 'package:burrow/models/book.dart';
import 'package:burrow/screens/library_screen.dart';
import 'package:burrow/services/library_service.dart';
import 'package:burrow/widgets/book_card.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Book _book(String id) => Book(
  id: id,
  title: 'Book $id',
  author: 'Author $id',
  path: '/tmp/removal-$id.epub',
  format: BookFormat.epub,
  addedAt: 1,
);

Future<void> _pump(WidgetTester t, LibraryService lib) async {
  t.view.devicePixelRatio = 1.0;
  t.view.physicalSize = const Size(412, 915);
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(home: LibraryScreen(library: lib)));
  await t.pump();
  await t.pump(const Duration(seconds: 1));
  expect(t.takeException(), isNull);
}

Future<void> _addHighlight(LibraryService lib, String bookId) =>
    lib.addHighlight(
      bookId: bookId,
      text: 'quoted',
      chapter: 0,
      startOffset: 0,
      endChapter: 0,
      endOffset: 6,
    );

void main() {
  late AppDatabase db;
  late LibraryService lib;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    lib = LibraryService()..debugAttachDatabase(db);
  });

  tearDown(() async {
    lib.dispose();
    await db.close();
  });

  testWidgets('single remove discloses the highlight count', (tester) async {
    final a = _book('a');
    await db.insertBook(bookToCompanion(a));
    await _addHighlight(lib, 'a');
    await _addHighlight(lib, 'a');
    lib.debugAddAll([a]);

    await _pump(tester, lib);

    await tester.longPress(find.byType(BookCard).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Remove from library'),
      120,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('Remove from library'));
    await tester.pumpAndSettle();

    expect(find.text('Also deletes 2 highlights.'), findsOneWidget);
  });

  testWidgets('batch remove discloses the total highlight count', (
    tester,
  ) async {
    final a = _book('a');
    final b = _book('b');
    await db.insertBook(bookToCompanion(a));
    await db.insertBook(bookToCompanion(b));
    await _addHighlight(lib, 'a');
    await _addHighlight(lib, 'b');
    lib.debugAddAll([a, b]);

    await _pump(tester, lib);

    await tester.longPress(find.byType(BookCard).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BookCard).at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Also deletes 2 highlights.'), findsOneWidget);
  });
}
