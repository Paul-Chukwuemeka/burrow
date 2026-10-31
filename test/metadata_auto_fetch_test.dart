import 'package:burrow/models/book.dart';
import 'package:burrow/screens/metadata_fetch_screen.dart';
import 'package:burrow/services/metadata_api_service.dart';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('normalizeIsbn', () {
    test('accepts ISBN-13 with hyphens', () {
      expect(
        MetadataApiService.normalizeIsbn('978-0-547-92822-7'),
        '9780547928227',
      );
    });

    test('accepts bare ISBN-13', () {
      expect(
        MetadataApiService.normalizeIsbn('9780547928227'),
        '9780547928227',
      );
    });

    test('accepts ISBN-10 with hyphens', () {
      expect(
        MetadataApiService.normalizeIsbn('0-547-92822-7'),
        '0547928227',
      );
    });

    test('accepts ISBN-10 with trailing X', () {
      expect(
        MetadataApiService.normalizeIsbn('817525766-0'.replaceFirstMapped(
          RegExp(r'.$'),
          (_) => 'X',
        )),
        '817525766X',
      );
    });

    test('rejects free-text titles even when they contain digits', () {
      expect(MetadataApiService.normalizeIsbn('the hobbit 1937'), null);
      expect(MetadataApiService.normalizeIsbn('_OceanofPDF.com_Hero'), null);
    });
  });

  group('openLibrarySearchUri', () {
    test('routes ISBN queries through q= instead of title=', () {
      final uri = MetadataApiService.openLibrarySearchUri(
        query: '9780547928227',
        limit: 10,
      );
      expect(uri.host, 'openlibrary.org');
      expect(uri.queryParameters['q'], '9780547928227');
      expect(uri.queryParameters.containsKey('title'), isFalse);
    });

    test('keeps title= route for plain title queries', () {
      final uri = MetadataApiService.openLibrarySearchUri(
        query: 'the hobbit',
        limit: 10,
      );
      expect(uri.queryParameters['title'], 'the hobbit');
      expect(uri.queryParameters.containsKey('q'), isFalse);
    });
  });

  group('buildAutoMetadataQuery', () {
    Book bookWith({String? isbn, String title = ''}) => Book(
          id: 'b1',
          title: title,
          author: 'J.R.R. Tolkien',
          path: '/tmp/b1.epub',
          format: BookFormat.epub,
          addedAt: DateTime(2026).millisecondsSinceEpoch,
          isbn: isbn,
        );

    test('prefers normalized ISBN', () {
      final query = buildAutoMetadataQuery(
        bookWith(isbn: '978-0-547-92822-7', title: 'whatever'),
      );
      expect(query, '9780547928227');
    });

    test('uses cleaned display title, not the raw filename', () {
      final query = buildAutoMetadataQuery(
        bookWith(
          title: '_OceanofPDF.com_The_Forever_Hero_by_John_Doe.epub',
        ),
      );
      // No site noise, no extension, no "by Author" tail.
      expect(query, isNot(contains('OceanofPDF')));
      expect(query, isNot(contains('by John')));
      expect(query, isNot(contains('.epub')));
      expect(query, isNotEmpty);
    });

    test('falls back to cleaned title when ISBN is blank-ish', () {
      final query = buildAutoMetadataQuery(
        bookWith(isbn: '   ', title: 'The Hobbit'),
      );
      expect(query, 'The Hobbit');
    });

    test('returns null when nothing usable is available', () {
      final query = buildAutoMetadataQuery(bookWith(title: ''));
      expect(query, null);
    });
  });
}
