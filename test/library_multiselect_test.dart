import 'package:burrow/db/database.dart';
import 'package:burrow/models/book.dart';
import 'package:burrow/services/library_service.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

Book _b(String id) => Book(
      id: id,
      title: id,
      author: '',
      path: '/tmp/multi-$id.epub',
      format: BookFormat.epub,
      addedAt: 1,
    );

void main() {
  test('deleteBooks removes all + reports count', () async {
    final lib = LibraryService();
    lib.debugAddAll([_b('a'), _b('b'), _b('c')]);
    final (deleted, errors) = await lib.deleteBooks(['a', 'b']);
    expect(deleted, 2);
    expect(errors, isEmpty);
    expect(lib.bookById('a'), isNull);
    expect(lib.bookById('c'), isNotNull);
  });

  test('deleteBooks continues past unknown id (silent no-op, mirrors single)',
      () async {
    final lib = LibraryService();
    lib.debugAddAll([_b('a')]);
    final (deleted, errors) = await lib.deleteBooks(['nope', 'a']);
    expect(deleted, 1);
    expect(errors, isEmpty);
    expect(lib.bookById('a'), isNull);
  });

  test('deleteBooks notifies exactly once', () async {
    final lib = LibraryService();
    lib.debugAddAll([_b('a'), _b('b')]);
    var notified = 0;
    lib.addListener(() => notified++);
    await lib.deleteBooks(['a', 'b']);
    expect(notified, 1);
  });

  test('addBooksToCollection adds all members', () async {
    final lib = LibraryService();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    lib.debugAttachDatabase(db);
    try {
      final a = _b('a');
      final b = _b('b');
      await db.insertBook(bookToCompanion(a));
      await db.insertBook(bookToCompanion(b));
      lib.debugAddAll([a, b]);
      final colId = await lib.createCollection('Fav');
      expect(colId, isNotEmpty);
      final (added, errors) = await lib.addBooksToCollection(colId, ['a', 'b']);
      expect(added, 2);
      expect(errors, isEmpty);
      expect(await lib.isBookInCollection(colId, 'a'), isTrue);
      expect(await lib.isBookInCollection(colId, 'b'), isTrue);
    } finally {
      await db.close();
    }
  });

  test('addBooksToCollection duplicate add reports error, notifies once',
      () async {
    final lib = LibraryService();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    lib.debugAttachDatabase(db);
    try {
      final a = _b('a');
      await db.insertBook(bookToCompanion(a));
      lib.debugAddAll([a]);
      final colId = await lib.createCollection('Fav');
      var notified = 0;
      lib.addListener(() => notified++);
      final (added, errors) = await lib.addBooksToCollection(colId, ['a', 'a']);
      // Store enforces UNIQUE(collection_id, book_id): duplicate throws,
      // batch collects it and continues.
      expect(added, 1);
      expect(errors, hasLength(1));
      expect(await lib.isBookInCollection(colId, 'a'), isTrue);
      expect(notified, 1);
    } finally {
      await db.close();
    }
  });

  test('deleteBooks partial failure: continues, collects errors, notifies once',
      () async {
    final lib = LibraryService();
    final db = _ThrowOnDeleteDb('b');
    lib.debugAttachDatabase(db);
    try {
      final books = [_b('a'), _b('b'), _b('c')];
      for (final b in books) {
        await db.insertBook(bookToCompanion(b));
      }
      lib.debugAddAll(books);
      var notified = 0;
      lib.addListener(() => notified++);
      final (deleted, errors) = await lib.deleteBooks(['a', 'b', 'c']);
      // 'b' throws inside its own transaction; the loop keeps going and the
      // batch still notifies exactly once at the end.
      expect(deleted, 2);
      expect(errors, hasLength(1));
      expect(errors.single, isA<StateError>());
      expect(lib.bookById('a'), isNull);
      expect(lib.bookById('b'), isNotNull);
      expect(lib.bookById('c'), isNull);
      expect(notified, 1);
    } finally {
      await db.close();
    }
  });
}

/// AppDatabase that throws for one book id on delete. [LibraryService]'s
/// per-id delete helper is library-private, so the DB call is the only
/// injectable seam for a per-id failure (mirrors _ThrowOnRemoveService in
/// test/collection_selection_widget_test.dart).
class _ThrowOnDeleteDb extends AppDatabase {
  _ThrowOnDeleteDb(this.failId) : super.forTesting(NativeDatabase.memory());

  final String failId;

  @override
  Future<void> deleteBookById(String id) async {
    if (id == failId) throw StateError('simulated delete failure');
    return super.deleteBookById(id);
  }
}
