import 'package:burrow/models/book.dart';
import 'package:burrow/models/library_enums.dart';
import 'package:burrow/screens/library_screen.dart';
import 'package:burrow/services/library_service.dart';
import 'package:burrow/widgets/book_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Book _book(String id) => Book(
  id: id,
  title: 'Book $id',
  author: 'Author $id',
  path: '/tmp/archive-$id.epub',
  format: BookFormat.epub,
  addedAt: 1,
);

Future<void> _pumpLibrary(WidgetTester t, LibraryService lib) async {
  t.view.devicePixelRatio = 1.0;
  t.view.physicalSize = const Size(412, 915);
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(home: LibraryScreen(library: lib)));
  await t.pump();
  await t.pump(const Duration(seconds: 1));
  expect(t.takeException(), isNull);
}

void main() {
  testWidgets(
    'selection bar archives books and removes them from the library',
    (t) async {
      final lib = LibraryService()..debugAddAll([_book('a'), _book('b')]);
      addTearDown(lib.dispose);
      await _pumpLibrary(t, lib);
      expect(find.byType(BookCard), findsNWidgets(2));

      await t.longPress(find.byType(BookCard).first);
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('Archive'));
      await t.pumpAndSettle();

      expect(find.text('Archived 1 book'), findsOneWidget);
      expect(find.byType(BookCard), findsOneWidget);
      expect(lib.archivedBooks.map((b) => b.id), ['a']);
      expect(lib.activeBooks.map((b) => b.id), ['b']);
    },
  );

  testWidgets('header archive entry opens the archived books', (t) async {
    final lib = LibraryService()..debugAddAll([_book('a'), _book('b')]);
    addTearDown(lib.dispose);
    await lib.archiveBooks(['a']);
    await _pumpLibrary(t, lib);

    await t.tap(find.byIcon(Icons.more_vert_rounded));
    await t.pumpAndSettle();
    expect(find.text('Archive (1)'), findsOneWidget);

    await t.tap(find.text('Archive (1)'));
    await t.pumpAndSettle();

    expect(find.text('Archive'), findsOneWidget);
    expect(find.text('Book a'), findsWidgets);
    expect(find.byType(BookListCard), findsOneWidget);
  });

  testWidgets('hidden archive entry creates a PIN, then opens the tier', (
    t,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final lib = LibraryService()..debugAddAll([_book('h')]);
    addTearDown(lib.dispose);
    await lib.archiveBooks(['h'], tier: ArchiveTier.hidden);
    await _pumpLibrary(t, lib);

    await t.tap(find.byIcon(Icons.more_vert_rounded));
    await t.pumpAndSettle();
    await t.tap(find.text('Hidden archive (1)'));
    await t.pumpAndSettle();

    expect(find.text('Create hidden archive PIN'), findsOneWidget);
    await t.enterText(find.byType(TextField).at(0), '1234');
    await t.enterText(find.byType(TextField).at(1), '1234');
    await t.tap(find.text('Create'));
    await t.pumpAndSettle();

    expect(find.text('Hidden archive'), findsOneWidget);
    expect(find.text('Book h'), findsWidgets);
  });
}
