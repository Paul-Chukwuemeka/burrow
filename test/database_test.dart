import 'package:burrow/db/database.dart';
import 'package:burrow/models/book.dart';
import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart' show NativeDatabase;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  group('AppDatabase', () {
    Book makeBook({
      String id = 'b1',
      String title = 'Test Book',
      String author = 'Author',
      String path = '/tmp/test.epub',
      BookFormat format = BookFormat.epub,
      double progress = 0,
    }) => Book(
      id: id,
      title: title,
      author: author,
      path: path,
      format: format,
      addedAt: 1000,
      progress: progress,
    );

    test('insert and read book', () async {
      final book = makeBook();
      await db.insertBook(bookToCompanion(book));

      final all = await db.getAllBooks();
      expect(all.length, 1);
      expect(all.first.id, 'b1');
      expect(all.first.title, 'Test Book');
      expect(all.first.format, BookFormat.epub);
    });

    test('delete book', () async {
      await db.insertBook(bookToCompanion(makeBook()));
      await db.insertBook(bookToCompanion(makeBook(id: 'b2', title: 'Book 2')));

      expect(await db.getAllBooks(), hasLength(2));

      await db.deleteBookById('b1');
      final remaining = await db.getAllBooks();
      expect(remaining.length, 1);
      expect(remaining.first.id, 'b2');
    });

    test('update book position', () async {
      await db.insertBook(bookToCompanion(makeBook()));
      await db.updateBook(
        positionToUpdate(
          id: 'b1',
          lastChapter: 5,
          lastOffset: 1234,
          progress: 0.42,
          lastReadAt: 9999,
        ),
      );

      final all = await db.getAllBooks();
      expect(all.first.lastChapter, 5);
      expect(all.first.lastOffset, 1234);
      expect(all.first.progress, 0.42);
      expect(all.first.lastReadAt, 9999);
    });

    test('meta get and set', () async {
      expect(await db.getMeta('schema_version'), isNull);

      await db.setMeta('schema_version', '1');
      expect(await db.getMeta('schema_version'), '1');

      await db.setMeta('schema_version', '2');
      expect(await db.getMeta('schema_version'), '2');
    });

    test('bookToCompanion round-trip preserves all fields', () async {
      final book =
          makeBook(
              id: 'rt1',
              title: 'Round Trip',
              author: 'Writer',
              path: '/tmp/rt.txt',
              format: BookFormat.txt,
              progress: 0.75,
            )
            ..lastChapter = 3
            ..lastOffset = 999
            ..lastReadAt = 5555;

      await db.insertBook(bookToCompanion(book));
      final all = await db.getAllBooks();
      final restored = all.first;

      expect(restored.id, book.id);
      expect(restored.title, book.title);
      expect(restored.author, book.author);
      expect(restored.path, book.path);
      expect(restored.format, book.format);
      expect(restored.progress, book.progress);
      expect(restored.lastChapter, book.lastChapter);
      expect(restored.lastOffset, book.lastOffset);
      expect(restored.lastReadAt, book.lastReadAt);
    });

    test('nullable coverPath round-trips correctly', () async {
      final book = makeBook(id: 'c1');
      await db.insertBook(bookToCompanion(book));
      final all = await db.getAllBooks();
      expect(all.first.coverPath, isNull);
    });

    test('default values via Value.absent()', () async {
      // Insert with Value.absent() for optional fields → drift defaults kick in.
      await db
          .into(db.books)
          .insert(
            BooksCompanion.insert(
              id: 'def1',
              title: 'Defaults',
              path: '/tmp/def.txt',
              format: BookFormat.txt,
              addedAt: 0,
            ),
          );
      final all = await db.getAllBooks();
      expect(all.first.author, ''); // drift default
      expect(all.first.lastReadAt, 0); // drift default
      expect(all.first.progress, 0.0); // drift default
      expect(all.first.lastChapter, 0); // drift default
      expect(all.first.lastOffset, 0); // drift default
    });

    test('v8 stores fileSize and mtimeMs', () async {
      // makeBook helper has no fingerprint yet — construct explicitly:
      final withPrint = Book(
        id: 'fp1',
        title: 'FP',
        author: 'A',
        path: '/tmp/a.epub',
        format: BookFormat.epub,
        addedAt: 1000,
        fileSize: 12345,
        mtimeMs: 999000,
      );
      await db.insertBook(bookToCompanion(withPrint));
      final all = await db.getAllBooks();
      expect(all.first.fileSize, 12345);
      expect(all.first.mtimeMs, 999000);
    });
  });

  group('Bookmarks', () {
    test('insert and retrieve bookmarks for a book', () async {
      await db
          .into(db.books)
          .insert(
            BooksCompanion.insert(
              id: 'bm-test-1',
              title: 'Bookmark Test',
              path: '/tmp/test.epub',
              format: BookFormat.epub,
              addedAt: DateTime.now().millisecondsSinceEpoch,
            ),
          );

      await db
          .into(db.bookmarks)
          .insert(
            BookmarksCompanion.insert(
              id: 'bm-1',
              bookId: 'bm-test-1',
              chapter: 1,
              offset: 100,
              createdAt: DateTime.now().millisecondsSinceEpoch,
            ),
          );

      final results = await db.getBookmarksForBook('bm-test-1');
      expect(results.length, 1);
      expect(results.first.id, 'bm-1');
    });

    test('deleteBookById cascades to bookmarks', () async {
      await db
          .into(db.books)
          .insert(
            BooksCompanion.insert(
              id: 'cascade-test',
              title: 'Cascade Test',
              path: '/tmp/test.epub',
              format: BookFormat.epub,
              addedAt: DateTime.now().millisecondsSinceEpoch,
            ),
          );
      await db
          .into(db.bookmarks)
          .insert(
            BookmarksCompanion.insert(
              id: 'cascade-bm',
              bookId: 'cascade-test',
              chapter: 1,
              offset: 0,
              createdAt: DateTime.now().millisecondsSinceEpoch,
            ),
          );

      await db.deleteBookById('cascade-test');

      final bookmarks = await db.getBookmarksForBook('cascade-test');
      expect(bookmarks, isEmpty);
    });
  });

  group('Highlights', () {
    HighlightsCompanion highlight({
      String id = 'h1',
      String bookId = 'b1',
      int? chapter = 0,
      int? startOffset = 10,
      int? endChapter = 0,
      int? endOffset = 20,
      int? page,
      String? segments,
    }) => HighlightsCompanion.insert(
      id: id,
      bookId: bookId,
      quote: 'quoted words',
      note: const Value(''),
      color: const Value(0),
      chapter: Value(chapter),
      startOffset: Value(startOffset),
      endChapter: Value(endChapter),
      endOffset: Value(endOffset),
      page: Value(page),
      segments: Value(segments),
      createdAt: 1000,
    );

    Future<void> insertBook(String id) => db.insertBook(
      bookToCompanion(
        Book(
          id: id,
          title: 'Book $id',
          author: '',
          path: '/tmp/$id.epub',
          format: BookFormat.epub,
          addedAt: 1,
        ),
      ),
    );

    test('insert and read highlights in reading order', () async {
      await insertBook('b1');
      await db.insertHighlight(
        highlight(
          id: 'h1',
          chapter: 1,
          startOffset: 5,
          endChapter: 1,
          endOffset: 9,
        ),
      );
      await db.insertHighlight(
        highlight(
          id: 'h2',
          chapter: 0,
          startOffset: 40,
          endChapter: 0,
          endOffset: 44,
        ),
      );
      await db.insertHighlight(
        highlight(
          id: 'h3',
          chapter: 0,
          startOffset: 10,
          endChapter: 0,
          endOffset: 14,
        ),
      );

      final rows = await db.getHighlightsForBook('b1');
      expect(rows.map((r) => r.id), ['h3', 'h2', 'h1']);
    });

    test('update note and colour', () async {
      await insertBook('b1');
      await db.insertHighlight(highlight());

      await db.updateHighlightNote('h1', 'new note');
      await db.updateHighlightColor('h1', 3);

      final rows = await db.getHighlightsForBook('b1');
      expect(rows.single.note, 'new note');
      expect(rows.single.color, 3);
      expect(rows.single.updatedAt, isNotNull);
    });

    test('delete one highlight', () async {
      await insertBook('b1');
      await db.insertHighlight(highlight());

      await db.deleteHighlightById('h1');

      expect(await db.getHighlightsForBook('b1'), isEmpty);
    });

    test('deleteBookById cascades to highlights', () async {
      await insertBook('b1');
      await insertBook('b2');
      await db.insertHighlight(highlight(id: 'h1', bookId: 'b1'));
      await db.insertHighlight(highlight(id: 'h2', bookId: 'b1'));
      await db.insertHighlight(highlight(id: 'h3', bookId: 'b2'));

      await db.deleteBookById('b1');

      expect(await db.getHighlightsForBook('b1'), isEmpty);
      expect(await db.getHighlightsForBook('b2'), hasLength(1));
    });

    test('migration from v8 creates the highlights table', () async {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      final executor = NativeDatabase.memory(
        setup: (raw) {
          raw.execute('CREATE TABLE books (id TEXT NOT NULL PRIMARY KEY)');
          raw.userVersion = 8;
        },
      );
      final migrated = AppDatabase.forTesting(executor);

      expect(await migrated.getHighlightsForBook('none'), isEmpty);
      final version = await migrated
          .customSelect('PRAGMA user_version')
          .getSingle();
      expect(version.data['user_version'], 9);
      expect(await migrated.countHighlightsForBook('none'), 0);

      await migrated.close();
    });
  });
}
