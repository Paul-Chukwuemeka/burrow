import 'package:burrow/db/database.dart';
import 'package:burrow/models/book.dart';
import 'package:burrow/services/library_service.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late LibraryService library;

  setUp(() {
    library = LibraryService();
  });

  Book makeBook({
    String id = 'b1',
    String title = 'Test Book',
    String author = 'Author',
    String? genre,
    String? seriesName,
    double? seriesIndex,
  }) => Book(
    id: id,
    title: title,
    author: author,
    path: '/tmp/test.epub',
    format: BookFormat.epub,
    addedAt: 1000,
    genre: genre,
    seriesName: seriesName,
    seriesIndex: seriesIndex,
  );

  group('Series helpers', () {
    test('uniqueSeries returns sorted unique series names', () {
      library.debugAddAll([
        makeBook(id: 'b1', seriesName: 'Foundation'),
        makeBook(id: 'b2', seriesName: 'Dune'),
        makeBook(id: 'b3', seriesName: 'Foundation'),
        makeBook(id: 'b4', seriesName: null),
        makeBook(id: 'b5', seriesName: ''),
        makeBook(id: 'b6', seriesName: 'Dune'),
      ]);

      expect(library.uniqueSeries, ['Dune', 'Foundation']);
    });

    test('uniqueSeries returns empty list when no books have series', () {
      library.debugAddAll([
        makeBook(id: 'b1', seriesName: null),
        makeBook(id: 'b2', seriesName: ''),
      ]);

      expect(library.uniqueSeries, isEmpty);
    });

    test('booksBySeries matches case-insensitively', () {
      library.debugAddAll([
        makeBook(id: 'b1', seriesName: 'Dune'),
        makeBook(id: 'b2', seriesName: 'dune'),
        makeBook(id: 'b3', seriesName: 'DUNE'),
        makeBook(id: 'b4', seriesName: 'Foundation'),
      ]);

      final result = library.booksBySeries('dune');
      expect(result.length, 3);
      expect(result.map((b) => b.id), containsAll(['b1', 'b2', 'b3']));
    });

    test('booksBySeries returns empty for unknown series', () {
      library.debugAddAll([makeBook(id: 'b1', seriesName: 'Dune')]);

      expect(library.booksBySeries('Foundation'), isEmpty);
    });

    test('seriesBookCount returns correct count', () {
      library.debugAddAll([
        makeBook(id: 'b1', seriesName: 'Dune'),
        makeBook(id: 'b2', seriesName: 'Dune'),
        makeBook(id: 'b3', seriesName: 'Foundation'),
      ]);

      expect(library.seriesBookCount('Dune'), 2);
      expect(library.seriesBookCount('Foundation'), 1);
      expect(library.seriesBookCount('Unknown'), 0);
    });
  });

  group('Genre helpers', () {
    test('uniqueGenres splits comma-separated values', () {
      library.debugAddAll([
        makeBook(id: 'b1', genre: 'Sci-Fi, Adventure'),
        makeBook(id: 'b2', genre: 'Fantasy'),
        makeBook(id: 'b3', genre: 'Sci-Fi, Thriller'),
        makeBook(id: 'b4', genre: null),
        makeBook(id: 'b5', genre: ''),
      ]);

      expect(library.uniqueGenres, [
        'Adventure',
        'Fantasy',
        'Sci-Fi',
        'Thriller',
      ]);
    });

    test('uniqueGenres trims whitespace', () {
      library.debugAddAll([
        makeBook(id: 'b1', genre: '  Sci-Fi , Adventure  '),
      ]);

      expect(library.uniqueGenres, ['Adventure', 'Sci-Fi']);
    });

    test('uniqueGenres returns empty list when no books have genres', () {
      library.debugAddAll([
        makeBook(id: 'b1', genre: null),
        makeBook(id: 'b2', genre: ''),
      ]);

      expect(library.uniqueGenres, isEmpty);
    });

    test('booksByGenre matches across comma-separated values', () {
      library.debugAddAll([
        makeBook(id: 'b1', genre: 'Sci-Fi, Adventure'),
        makeBook(id: 'b2', genre: 'Fantasy'),
        makeBook(id: 'b3', genre: 'Sci-Fi, Thriller'),
        makeBook(id: 'b4', genre: 'Adventure, Mystery'),
      ]);

      final sciFi = library.booksByGenre('Sci-Fi');
      expect(sciFi.length, 2);
      expect(sciFi.map((b) => b.id), containsAll(['b1', 'b3']));

      final adventure = library.booksByGenre('Adventure');
      expect(adventure.length, 2);
      expect(adventure.map((b) => b.id), containsAll(['b1', 'b4']));
    });

    test('booksByGenre matches case-insensitively', () {
      library.debugAddAll([
        makeBook(id: 'b1', genre: 'Sci-Fi'),
        makeBook(id: 'b2', genre: 'fantasy'),
      ]);

      expect(library.booksByGenre('sci-fi').length, 1);
      expect(library.booksByGenre('FANTASY').length, 1);
    });

    test('booksByGenre returns empty for unknown genre', () {
      library.debugAddAll([makeBook(id: 'b1', genre: 'Sci-Fi')]);

      expect(library.booksByGenre('Romance'), isEmpty);
    });

    test('genreBookCount returns correct count', () {
      library.debugAddAll([
        makeBook(id: 'b1', genre: 'Sci-Fi, Adventure'),
        makeBook(id: 'b2', genre: 'Sci-Fi'),
        makeBook(id: 'b3', genre: 'Fantasy'),
      ]);

      expect(library.genreBookCount('Sci-Fi'), 2);
      expect(library.genreBookCount('Adventure'), 1);
      expect(library.genreBookCount('Fantasy'), 1);
      expect(library.genreBookCount('Romance'), 0);
    });
  });

  group('deleteBookWithFile', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      library.debugAttachDatabase(db);
    });

    tearDown(() => db.close());

    Book makeBook({
      String id = 'del1',
      String title = 'Delete Me',
      String path = '/tmp/to-delete.epub',
    }) => Book(
      id: id,
      title: title,
      author: 'Author',
      path: path,
      format: BookFormat.epub,
      addedAt: 1000,
    );

    test(
      'removes book from DB and in-memory list, and cleans up related rows',
      () async {
        final book = makeBook();
        await db.insertBook(bookToCompanion(book));
        library.debugAddAll([book]);

        // Seed related rows.
        await db.insertBookmark(
          BookmarksCompanion.insert(
            id: 'bm1',
            bookId: 'del1',
            chapter: 1,
            offset: 0,
            createdAt: 2000,
          ),
        );
        await db.insertSession(
          ReadingSessionsCompanion.insert(bookId: 'del1', startedAt: 3000),
        );
        // Create a collection and link the book.
        await db.insertCollection(
          CollectionsCompanion.insert(
            id: 'col1',
            name: 'Test Collection',
            createdAt: 1000,
          ),
        );
        await db.addBookToCollection('col1', 'del1');

        expect(await db.getAllSessions(), hasLength(1));
        expect(await db.getAllBookmarks(), hasLength(1));

        await library.deleteBookWithFile(book.id);

        expect(library.books, isEmpty);
        expect(await db.getAllBookmarks(), isEmpty);
        expect(await db.getAllSessions(), isEmpty);
      },
    );

    test(
      'book is removed from in-memory list even without deleteFile',
      () async {
        final book = makeBook(path: '/tmp/kept.epub');
        await db.insertBook(bookToCompanion(book));
        library.debugAddAll([book]);

        await library.deleteBookWithFile(book.id, deleteFile: false);

        expect(library.books, isEmpty);
      },
    );
  });
}
