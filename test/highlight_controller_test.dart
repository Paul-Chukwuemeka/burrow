import 'package:burrow/controllers/highlight_controller.dart';
import 'package:burrow/db/database.dart';
import 'package:burrow/models/book.dart';
import 'package:burrow/services/library_service.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late LibraryService library;
  late AppDatabase db;
  late HighlightController controller;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    library = LibraryService()..debugAttachDatabase(db);
    final book = Book(
      id: 'b1',
      title: 'Book',
      author: '',
      path: '/tmp/b1.epub',
      format: BookFormat.epub,
      addedAt: 1,
    );
    await db.insertBook(bookToCompanion(book));
    controller = HighlightController(library: library, book: book);
  });

  tearDown(() async {
    controller.dispose();
    library.dispose();
    await db.close();
  });

  test('addReflowable converts flat offsets to chapter-local', () async {
    final row = await controller.addReflowable(
      text: 'quoted words',
      start: 90,
      end: 110,
      charsBefore: const [0, 100],
      color: 1,
    );

    expect(row, isNotNull);
    expect(row!.chapter, 0);
    expect(row.startOffset, 90);
    expect(row.endChapter, 1);
    expect(row.endOffset, 10);
  });

  test('addPdf stores page and segments', () async {
    const segments = '[{"page":12,"rects":[[1,2,3,4]]}]';

    final row = await controller.addPdf(
      text: 'pdf words',
      page: 12,
      segments: segments,
      color: 2,
    );

    expect(row, isNotNull);
    expect(row!.page, 12);
    expect(row.segments, segments);
    expect(row.color, 2);
  });

  test('load refreshes the list', () async {
    await library.addHighlight(
      bookId: 'b1',
      text: 'external',
      chapter: 0,
      startOffset: 0,
      endChapter: 0,
      endOffset: 1,
    );

    await controller.load();

    expect(controller.highlights, hasLength(1));
  });

  test(
    'forChapter includes a highlight that starts earlier and ends later',
    () async {
      await controller.addReflowable(
        text: 'long',
        start: 10,
        end: 250,
        charsBefore: const [0, 100, 200, 300],
        color: 0,
      );

      expect(controller.forChapter(1), hasLength(1));
      expect(controller.forChapter(3), isEmpty);
    },
  );

  test('pdfRectsForPage groups decoded rectangles by page', () async {
    await controller.addPdf(
      text: 'pdf',
      page: 12,
      segments:
          '[{"page":12,"rects":[[1,2,3,4],[5,6,7,8]]},'
          '{"page":13,"rects":[[9,10,11,12]]}]',
      color: 2,
    );

    expect(controller.pdfRectsForPage(12), hasLength(2));
    expect(controller.pdfRectsForPage(13), hasLength(1));
    expect(controller.pdfRectsForPage(99), isEmpty);
    expect(controller.pdfRectsForPage(12).first.color, 2);
  });

  test('loading twice keeps one row per highlight', () async {
    await controller.addReflowable(
      text: 'once',
      start: 0,
      end: 5,
      charsBefore: const [0, 100],
      color: 0,
    );

    await controller.load();
    await controller.load();

    expect(controller.highlights, hasLength(1));
  });

  test('forChapter excludes PDF rows', () async {
    await controller.addPdf(text: 'pdf', page: 1, segments: '[]', color: 0);

    expect(controller.forChapter(0), isEmpty);
  });

  test('updateNote and updateColor persist', () async {
    final row = await controller.addReflowable(
      text: 'quoted',
      start: 0,
      end: 5,
      charsBefore: const [0, 100],
      color: 0,
    );

    await controller.updateNote(row!.id, 'my note');
    await controller.updateColor(row.id, 4);

    final stored = controller.highlights.single;
    expect(stored.note, 'my note');
    expect(stored.color, 4);
  });

  test('delete removes the row', () async {
    final row = await controller.addReflowable(
      text: 'quoted',
      start: 0,
      end: 5,
      charsBefore: const [0, 100],
      color: 0,
    );

    await controller.delete(row!.id);

    expect(controller.highlights, isEmpty);
  });

  test('restore re-adds the same content after a delete', () async {
    final row = await controller.addReflowable(
      text: 'quoted',
      start: 10,
      end: 20,
      charsBefore: const [0, 100],
      color: 3,
      note: 'keep me',
    );
    await controller.delete(row!.id);

    final restored = await controller.restore(row);

    expect(restored, isNotNull);
    expect(controller.highlights, hasLength(1));
    expect(restored!.quote, 'quoted');
    expect(restored.note, 'keep me');
    expect(restored.color, 3);
    expect(restored.chapter, 0);
    expect(restored.startOffset, 10);
    expect(restored.endChapter, 0);
    expect(restored.endOffset, 20);
  });
}
