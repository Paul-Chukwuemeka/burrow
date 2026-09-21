import 'package:flutter_test/flutter_test.dart';
import 'package:burrow/utils/file_size.dart';

void main() {
  group('formatFileSize', () {
    test('returns bytes for values under 1 KB', () {
      expect(formatFileSize(0), '0 B');
      expect(formatFileSize(1), '1 B');
      expect(formatFileSize(512), '512 B');
      expect(formatFileSize(1023), '1023 B');
    });

    test('returns KB for values under 1 MB', () {
      expect(formatFileSize(1024), '1.0 KB');
      expect(formatFileSize(1536), '1.5 KB');
    });

    test('returns MB for values under 1 GB', () {
      expect(formatFileSize(1048576), '1.0 MB');
      expect(formatFileSize(5242880), '5.0 MB');
    });

    test('returns GB for values under 1 TB', () {
      expect(formatFileSize(1073741824), '1.0 GB');
    });

    test('returns TB for values 1 TB and above', () {
      expect(formatFileSize(1099511627776), '1.0 TB');
    });

    test('handles negative values', () {
      expect(formatFileSize(-1), '0 B');
      expect(formatFileSize(-1024), '0 B');
    });
  });
}