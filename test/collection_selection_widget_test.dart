import 'package:burrow/db/database.dart';
import 'package:burrow/models/book.dart';
import 'package:burrow/screens/collection_screen.dart';
import 'package:burrow/services/library_service.dart';
import 'package:burrow/widgets/book_card.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Book _fakeBook(String id) => Book(
  id: id,
  title: 'Book $id',
  author: 'Author $id',
  path: '/tmp/col-sel-$id.epub',
  format: BookFormat.epub,
  addedAt: 1,
);

/// Seeds an in-memory DB + library with 3 epubs in a 'Mix' collection.
/// Returns the (library, db, collection-row) triple; caller owns disposal.
Future<(LibraryService, AppDatabase, Collection)> _seed() async {
  final lib = LibraryService();
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  lib.debugAttachDatabase(db);
  final books = [_fakeBook('a'), _fakeBook('b'), _fakeBook('c')];
  for (final b in books) {
    await db.insertBook(bookToCompanion(b));
  }
  lib.debugAddAll(books);
  final colId = await lib.createCollection('Mix');
  expect(colId, isNotEmpty);
  final (added, errors) = await lib.addBooksToCollection(colId, [
    'a',
    'b',
    'c',
  ]);
  expect(added, 3);
  expect(errors, isEmpty);
  final collection = lib.collections.firstWhere((c) => c.id == colId);
  return (lib, db, collection);
}

Future<void> _pumpCollection(
  WidgetTester t,
  LibraryService lib,
  Collection collection,
) async {
  t.view.devicePixelRatio = 1.0;
  t.view.physicalSize = const Size(412, 915);
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      home: CollectionScreen(collection: collection, library: lib),
    ),
  );
  await t.pump();
  await t.pump(const Duration(seconds: 1));
  expect(t.takeException(), isNull);
}

/// Selects the first two tiles via long-press + tap.
Future<void> _selectTwo(WidgetTester t) async {
  await t.longPress(find.byType(BookCard).first);
  await t.pumpAndSettle();
  expect(find.text('1 selected'), findsOneWidget);
  await t.tap(find.byType(BookCard).at(1));
  await t.pumpAndSettle();
  expect(find.text('2 selected'), findsOneWidget);
}

Future<void> _confirmRemove(WidgetTester t) async {
  await t.tap(find.byTooltip('Remove from collection'));
  await t.pumpAndSettle();
  expect(find.text('Remove 2 books from this collection?'), findsOneWidget);
  await t.tap(find.widgetWithText(FilledButton, 'Remove'));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('bulk remove: 2 selected removed, snack counted, bar cleared', (
    t,
  ) async {
    final (lib, db, collection) = await _seed();
    addTearDown(lib.dispose);
    addTearDown(db.close);
    await _pumpCollection(t, lib, collection);
    expect(find.byType(BookCard), findsNWidgets(3));

    await _selectTwo(t);
    await _confirmRemove(t);

    expect(find.text('Removed 2 books from "Mix"'), findsOneWidget);
    expect(find.byType(BookCard), findsOneWidget);
    expect(find.text('1 selected'), findsNothing);
    expect(await lib.getCollectionBookCount(collection.id), 1);
  });

  testWidgets('bulk remove partial failure shows "Removed 1 of 2 (1 failed)"', (
    t,
  ) async {
    // Hand-rolled fake (no mock package): fail one member's removal while
    // the store stays healthy, so the post-loop _loadBooks() still works.
    final lib = _ThrowOnRemoveService('b');
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    lib.debugAttachDatabase(db);
    addTearDown(lib.dispose);
    addTearDown(db.close);
    final books = [_fakeBook('a'), _fakeBook('b'), _fakeBook('c')];
    for (final b in books) {
      await db.insertBook(bookToCompanion(b));
    }
    lib.debugAddAll(books);
    final colId = await lib.createCollection('Mix');
    final (added, errors) = await lib.addBooksToCollection(colId, [
      'a',
      'b',
      'c',
    ]);
    expect(added, 3);
    expect(errors, isEmpty);
    final collection = lib.collections.firstWhere((c) => c.id == colId);
    await _pumpCollection(t, lib, collection);
    expect(find.byType(BookCard), findsNWidgets(3));

    await _selectTwo(t);
    await _confirmRemove(t);

    expect(find.text('Removed 1 of 2 (1 failed)'), findsOneWidget);
    // 'a' left the collection, 'b' failed and stays, 'c' untouched.
    expect(find.byType(BookCard), findsNWidgets(2));
    expect(find.text('1 selected'), findsNothing);
    expect(await lib.isBookInCollection(collection.id, 'a'), isFalse);
    expect(await lib.isBookInCollection(collection.id, 'b'), isTrue);
  });
}

/// LibraryService that throws for one book id on remove-from-collection.
class _ThrowOnRemoveService extends LibraryService {
  _ThrowOnRemoveService(this.failId);

  final String failId;

  @override
  Future<void> removeBookFromCollection(
    String collectionId,
    String bookId,
  ) async {
    if (bookId == failId) throw StateError('simulated remove failure');
    return super.removeBookFromCollection(collectionId, bookId);
  }
}
