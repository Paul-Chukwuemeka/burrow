import 'package:burrow/db/database.dart';
import 'package:burrow/models/book.dart';
import 'package:drift/native.dart';
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
  });
}
