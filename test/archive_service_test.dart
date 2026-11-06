import 'package:burrow/db/database.dart';
import 'package:burrow/models/book.dart';
import 'package:burrow/models/library_enums.dart';
import 'package:burrow/services/library_service.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Book makeBook({
    String id = 'b1',
    String title = 'Test Book',
    String author = 'Author',
    String path = '/tmp/test.epub',
    String? genre,
    String? seriesName,
    int lastReadAt = 0,
    double progress = 0,
  }) => Book(
    id: id,
    title: title,
    author: author,
    path: path,
    format: BookFormat.epub,
    addedAt: 1000,
    genre: genre,
    seriesName: seriesName,
    lastReadAt: lastReadAt,
    progress: progress,
  );

  group('Book archive fields', () {
    test('new books are not archived', () {
      final book = makeBook();
      expect(book.archiveTier, ArchiveTier.none);
      expect(book.archivedAt, 0);
      expect(book.isArchived, isFalse);
    });

    test('JSON round-trips the archive tier and timestamp', () {
      final book = makeBook()
        ..archiveTier = ArchiveTier.hidden
        ..archivedAt = 12345;

      final restored = Book.fromJson(book.toJson());

      expect(restored.archiveTier, ArchiveTier.hidden);
      expect(restored.archivedAt, 12345);
      expect(restored.isArchived, isTrue);
    });

    test('legacy JSON without archive fields defaults to none', () {
      final json = makeBook().toJson()
        ..remove('archiveTier')
        ..remove('archivedAt');

      final restored = Book.fromJson(json);

      expect(restored.archiveTier, ArchiveTier.none);
      expect(restored.archivedAt, 0);
    });
  });

  group('Archive service', () {
    late LibraryService library;

    setUp(() {
      library = LibraryService();
    });

    test('archiveBooks moves a book out of active views', () async {
      final book = makeBook(id: 'b1');
      library.debugAddAll([book]);

      final count = await library.archiveBooks(['b1']);

      expect(count, 1);
      expect(library.activeBooks, isEmpty);
      expect(library.archivedBooks.map((b) => b.id), ['b1']);
      expect(library.hiddenArchiveBooks, isEmpty);
      expect(book.archiveTier, ArchiveTier.archive);
      expect(book.archivedAt, greaterThan(0));
    });

    test('archiveBooks can move a book straight to the hidden tier', () async {
      final book = makeBook(id: 'b1');
      library.debugAddAll([book]);

      await library.archiveBooks(['b1'], tier: ArchiveTier.hidden);

      expect(library.archivedBooks, isEmpty);
      expect(library.hiddenArchiveBooks.map((b) => b.id), ['b1']);
      expect(book.archiveTier, ArchiveTier.hidden);
    });

    test('restoreBooks returns a book to the active library', () async {
      final book = makeBook(id: 'b1');
      library.debugAddAll([book]);
      await library.archiveBooks(['b1']);

      final count = await library.restoreBooks(['b1']);

      expect(count, 1);
      expect(library.activeBooks.map((b) => b.id), ['b1']);
      expect(library.archivedBooks, isEmpty);
      expect(book.archiveTier, ArchiveTier.none);
      expect(book.archivedAt, 0);
    });

    test('moveArchiveBooks changes an archived book tier', () async {
      final book = makeBook(id: 'b1');
      library.debugAddAll([book]);
      await library.archiveBooks(['b1']);

      final count = await library.moveArchiveBooks(['b1'], ArchiveTier.hidden);

      expect(count, 1);
      expect(library.archivedBooks, isEmpty);
      expect(library.hiddenArchiveBooks.map((b) => b.id), ['b1']);
    });

    test('archived books vanish from recent, author, series and genre views', () async {
      library.debugAddAll([
        makeBook(
          id: 'active',
          author: 'Author',
          genre: 'Fantasy',
          seriesName: 'Dune',
          lastReadAt: 2000,
          progress: 0.4,
        ),
        makeBook(
          id: 'archived',
          author: 'Author',
          genre: 'Fantasy',
          seriesName: 'Dune',
          lastReadAt: 3000,
          progress: 0.4,
        ),
      ]);

      expect(library.mostRecent?.id, 'archived');

      await library.archiveBooks(['archived']);

      expect(library.mostRecent?.id, 'active');
      expect(library.uniqueAuthors, ['Author']);
      expect(library.booksByAuthor('Author').map((b) => b.id), ['active']);
      expect(library.uniqueSeries, ['Dune']);
      expect(library.booksBySeries('Dune').map((b) => b.id), ['active']);
      expect(library.uniqueGenres, ['Fantasy']);
      expect(library.booksByGenre('Fantasy').map((b) => b.id), ['active']);
    });

    test('missingActiveIds ignores archived books', () {
      final active = makeBook(id: 'active');
      final archived = makeBook(id: 'archived')..archiveTier = ArchiveTier.archive;
      library.debugAddAll([active, archived]);
      library.debugMarkMissing('active');
      library.debugMarkMissing('archived');

      expect(library.missingActiveIds, {'active'});
      expect(library.missingIds, {'active', 'archived'});
    });
  });

  group('Archive persistence', () {
    late AppDatabase db;
    late LibraryService library;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      library = LibraryService();
      library.debugAttachDatabase(db);
    });

    tearDown(() async {
      library.dispose();
      await db.close();
    });

    test('archive fields survive a database round-trip', () async {
      final book = makeBook(id: 'b1');
      await db.insertBook(bookToCompanion(book));
      library.debugAddAll([book]);

      await library.archiveBooks(['b1'], tier: ArchiveTier.hidden);

      final stored = (await db.getAllBooks()).single;
      expect(stored.archiveTier, ArchiveTier.hidden);
      expect(stored.archivedAt, greaterThan(0));
    });

    test('restoring clears the archive fields in the database', () async {
      final book = makeBook(id: 'b1');
      await db.insertBook(bookToCompanion(book));
      library.debugAddAll([book]);
      await library.archiveBooks(['b1']);

      await library.restoreBooks(['b1']);

      final stored = (await db.getAllBooks()).single;
      expect(stored.archiveTier, ArchiveTier.none);
      expect(stored.archivedAt, 0);
    });

    test('collection lists and counts exclude archived books', () async {
      await db.insertCollection(
        CollectionsCompanion.insert(
          id: 'c1',
          name: 'Collection',
          createdAt: 1,
        ),
      );
      final active = makeBook(id: 'active');
      final archived = makeBook(id: 'archived');
      await db.insertBook(bookToCompanion(active));
      await db.insertBook(bookToCompanion(archived));
      await db.addBookToCollection('c1', 'active');
      await db.addBookToCollection('c1', 'archived');
      library.debugAddAll([active, archived]);
      await library.archiveBooks(['archived']);

      expect(
        (await library.getBooksForCollection('c1')).map((b) => b.id),
        ['active'],
      );
      expect(await library.getCollectionBookCount('c1'), 1);
    });
  });
}
