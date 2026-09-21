import 'package:flutter_test/flutter_test.dart';
import 'package:burrow/utils/date_format.dart';

void main() {
  group('formatDate', () {
    test('returns empty string for zero or negative', () {
      expect(formatDate(0), '');
      expect(formatDate(-1), '');
    });

    test('formats valid timestamp', () {
      final ms = DateTime.utc(2024, 9, 15).millisecondsSinceEpoch;
      expect(formatDate(ms), 'Sep 15, 2024');
    });
  });

  group('formatDateTime', () {
    test('formats DateTime object', () {
      expect(formatDateTime(DateTime(2024, 1, 5)), 'Jan 5, 2024');
    });
  });

  group('formatPublicationDate', () {
    test('returns empty for empty string', () {
      expect(formatPublicationDate(''), '');
    });

    test('formats ISO 8601 date without time', () {
      expect(formatPublicationDate('2024-03-15T00:00:00Z'), 'Mar 15, 2024');
    });

    test('formats ISO 8601 date with time', () {
      final result = formatPublicationDate('2024-03-15T14:30:00Z');
      expect(result, contains('Mar 15, 2024'));
      expect(result, contains('14:30'));
    });

    test('formats plain year', () {
      expect(formatPublicationDate('2024'), '2024');
    });

    test('returns empty for year <= 1', () {
      expect(formatPublicationDate('0001-01-01'), '');
    });
  });
}