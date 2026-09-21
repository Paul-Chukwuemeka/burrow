import 'package:flutter_test/flutter_test.dart';
import 'package:burrow/utils/book_title.dart';

void main() {
  group('cleanBookTitle', () {
    test('strips file extension', () {
      expect(cleanBookTitle('My Book.epub'), 'My Book');
      expect(cleanBookTitle('My Book.PDF'), 'My Book');
    });

    test('strips site noise', () {
      expect(cleanBookTitle('OceanofPDF.com_My_Book'), 'My Book');
    });

    test('replaces underscores with spaces', () {
      expect(cleanBookTitle('The_Great_Gatsby'), 'The Great Gatsby');
    });

    test('handles empty string', () {
      expect(cleanBookTitle(''), '');
    });

    test('trims leading and trailing punctuation', () {
      expect(cleanBookTitle('- My Book -'), 'My Book');
    });
  });
}