import 'package:burrow/db/database.dart';
import 'package:burrow/models/book.dart';
import 'package:burrow/services/library_service.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late LibraryService library;
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    library = LibraryService()..debugAttachDatabase(db);
    await db.insertBook(
      bookToCompanion(
        Book(
          id: 'b1',
          title: 'Book',
          author: '',
          path: '/tmp/b1.epub',
          format: BookFormat.epub,
          addedAt: 1,
        ),
      ),
    );
  });

  tearDown(() async {
    library.dispose();
    await db.close();
  });

  test('adds a reflowable highlight and returns its id', () async {
    final id = await library.addHighlight(
      bookId: 'b1',
      text: 'quoted words',
      chapter: 0,
      startOffset: 10,
      endChapter: 0,
      endOffset: 20,
    );

    expect(id, isNotEmpty);
    final rows = await library.getHighlights('b1');
    expect(rows, hasLength(1));
    expect(rows.single.id, id);
    expect(rows.single.quote, 'quoted words');
    expect(rows.single.chapter, 0);
    expect(rows.single.startOffset, 10);
    expect(rows.single.endChapter, 0);
    expect(rows.single.endOffset, 20);
  });

  test('adds a PDF highlight with segments', () async {
    const segments = '[{"page":12,"rects":[[1,2,3,4]]}]';

    await library.addHighlight(
      bookId: 'b1',
      text: 'pdf words',
      page: 12,
      segments: segments,
    );

    final rows = await library.getHighlights('b1');
    expect(rows.single.page, 12);
    expect(rows.single.segments, segments);
  });

  test('rejects a row with both locator families', () async {
    await expectLater(
      library.addHighlight(
        bookId: 'b1',
        text: 'bad',
        chapter: 0,
        startOffset: 0,
        endChapter: 0,
        endOffset: 1,
        page: 1,
        segments: '[]',
      ),
      throwsArgumentError,
    );
  });

  test('rejects a row with no locator family', () async {
    await expectLater(
      library.addHighlight(bookId: 'b1', text: 'bad'),
      throwsArgumentError,
    );
  });

  test('rejects malformed PDF segments', () async {
    await expectLater(
      library.addHighlight(bookId: 'b1', text: 'bad', page: 1, segments: '{'),
      throwsArgumentError,
    );
  });

  test('accepts a cross-chapter highlight ending at offset zero', () async {
    await library.addHighlight(
      bookId: 'b1',
      text: 'boundary',
      chapter: 0,
      startOffset: 90,
      endChapter: 1,
      endOffset: 0,
    );

    expect(await library.getHighlights('b1'), hasLength(1));
  });

  test('updates and deletes through the service', () async {
    final id = await library.addHighlight(
      bookId: 'b1',
      text: 'quoted words',
      chapter: 0,
      startOffset: 10,
      endChapter: 0,
      endOffset: 20,
    );

    await library.updateHighlightNote(id, 'my note');
    await library.updateHighlightColor(id, 2);

    var rows = await library.getHighlights('b1');
    expect(rows.single.note, 'my note');
    expect(rows.single.color, 2);

    await library.deleteHighlight(id);
    rows = await library.getHighlights('b1');
    expect(rows, isEmpty);
  });

  test('counts highlights per book', () async {
    await library.addHighlight(
      bookId: 'b1',
      text: 'one',
      chapter: 0,
      startOffset: 0,
      endChapter: 0,
      endOffset: 1,
    );
    await library.addHighlight(
      bookId: 'b1',
      text: 'two',
      chapter: 0,
      startOffset: 2,
      endChapter: 0,
      endOffset: 3,
    );

    expect(await library.countHighlightsForBook('b1'), 2);
    expect(await library.countHighlightsForBook('missing'), 0);
  });

  test('highlightCountsForBooks omits unknown ids', () async {
    await library.addHighlight(
      bookId: 'b1',
      text: 'one',
      chapter: 0,
      startOffset: 0,
      endChapter: 0,
      endOffset: 1,
    );

    final counts = await library.highlightCountsForBooks(['b1', 'missing']);
    expect(counts, {'b1': 1});
  });
}
