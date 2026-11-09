import 'dart:convert';

import 'package:burrow/db/database.dart' as db;
import 'package:burrow/models/book.dart';
import 'package:burrow/services/highlight_exporter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final book = Book(
    id: 'b1',
    title: 'Test Book',
    author: 'Author',
    path: '/tmp/b1.epub',
    format: BookFormat.epub,
    addedAt: 1,
  );
  final exportedAt = DateTime.utc(2026, 11, 9);

  db.HighlightRow row({
    String id = 'h1',
    String quote = 'quoted words',
    String note = '',
    int? chapter = 0,
    int? startOffset = 10,
    int? endChapter = 0,
    int? endOffset = 20,
    int? page,
    String? segments,
  }) => db.HighlightRow(
    id: id,
    bookId: 'b1',
    quote: quote,
    note: note,
    color: 0,
    chapter: chapter,
    startOffset: startOffset,
    endChapter: endChapter,
    endOffset: endOffset,
    page: page,
    segments: segments,
    createdAt: 1700000000000,
  );

  String label(db.HighlightRow h) =>
      h.page != null ? 'Page ${h.page}' : 'Chapter One';

  test('markdown groups by chapter and quotes text', () {
    final markdown = highlightsToMarkdown(
      book: book,
      highlights: [row(note: 'my thought')],
      locatorLabel: label,
      exportedAt: exportedAt,
    );

    expect(
      markdown.trimRight(),
      [
        '# Test Book — Author',
        '_Exported 2026-11-09_',
        '',
        '## Chapter One',
        '> quoted words',
        '',
        '**Note:** my thought',
      ].join('\n'),
    );
  });

  test('markdown uses Page N for PDF locators', () {
    final markdown = highlightsToMarkdown(
      book: book,
      highlights: [
        row(
          page: 12,
          chapter: null,
          startOffset: null,
          endChapter: null,
          endOffset: null,
        ),
      ],
      locatorLabel: label,
      exportedAt: exportedAt,
    );

    expect(markdown, contains('## Page 12'));
  });

  test('markdown skips highlights with empty text', () {
    final markdown = highlightsToMarkdown(
      book: book,
      highlights: [row(quote: '   ')],
      locatorLabel: label,
      exportedAt: exportedAt,
    );

    expect(markdown, isNot(contains('## Chapter One')));
  });

  test('json has version, book, date, and locator fields', () {
    final decoded =
        jsonDecode(
              highlightsToJson(
                book: book,
                highlights: [
                  row(page: 12, segments: '[{"page":12,"rects":[]}]'),
                ],
                exportedAt: exportedAt,
              ),
            )
            as Map<String, dynamic>;

    expect(decoded['version'], 1);
    expect((decoded['book'] as Map)['title'], 'Test Book');
    expect(decoded['exportedAt'], '2026-11-09');
    final highlights = decoded['highlights'] as List;
    expect(highlights, hasLength(1));
    expect((highlights.first as Map)['page'], 12);
    expect((highlights.first as Map)['segments'], '[{"page":12,"rects":[]}]');
  });

  test('json round-trips all highlights', () {
    final decoded =
        jsonDecode(
              highlightsToJson(
                book: book,
                highlights: [
                  row(),
                  row(id: 'h2', quote: 'second'),
                ],
                exportedAt: exportedAt,
              ),
            )
            as Map<String, dynamic>;

    expect(decoded['highlights'], hasLength(2));
  });
}
