import 'package:burrow/db/database.dart';
import 'package:burrow/models/book.dart';
import 'package:burrow/screens/author_screen.dart';
import 'package:burrow/screens/book_info_screen.dart';
import 'package:burrow/screens/collection_screen.dart';
import 'package:burrow/services/library_service.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _bookId = 'book-info-links';

Book _book() => Book(
  id: _bookId,
  title: 'Notes on the Analytical Engine',
  author: 'Ada Lovelace',
  path: '/tmp/book-info-links.epub',
  format: BookFormat.epub,
  addedAt: 1,
);

/// Seeds an in-memory DB + library with one book inside a "Favourites"
/// collection. Returns the library and the collection row.
Future<(LibraryService, Collection)> _seed() async {
  SharedPreferences.setMockInitialValues({});
  final lib = LibraryService();
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  lib.debugAttachDatabase(db);
  final book = _book();
  await db.insertBook(bookToCompanion(book));
  lib.debugAddAll([book]);
  final colId = await lib.createCollection('Favourites');
  expect(colId, isNotEmpty);
  await lib.addBookToCollection(colId, _bookId);
  final collection = lib.collections.single;
  addTearDown(() async {
    await db.close();
    lib.dispose();
  });
  return (lib, collection);
}

Future<void> _pumpInfo(WidgetTester t, LibraryService lib) async {
  t.view.devicePixelRatio = 1.0;
  t.view.physicalSize = const Size(412, 915);
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      home: BookInfoScreen(book: _book(), library: lib),
    ),
  );
  await t.pumpAndSettle();
  expect(t.takeException(), isNull);
}

void main() {
  testWidgets('tapping the author opens the author filter page', (t) async {
    final (lib, _) = await _seed();
    await _pumpInfo(t, lib);

    // The placeholder cover also prints the author; the metadata line is last.
    await t.tap(find.text('Ada Lovelace').last);
    await t.pumpAndSettle();

    final screen = t.widget<AuthorScreen>(find.byType(AuthorScreen));
    expect(screen.author, 'Ada Lovelace');
  });

  testWidgets('tapping a collection chip opens the collection filter page', (
    t,
  ) async {
    final (lib, collection) = await _seed();
    await _pumpInfo(t, lib);

    await t.tap(find.text('Favourites'));
    await t.pumpAndSettle();

    final screen = t.widget<CollectionScreen>(find.byType(CollectionScreen));
    expect(screen.collection.id, collection.id);
  });
}
