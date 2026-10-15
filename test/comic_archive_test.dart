import 'dart:convert';
import 'dart:typed_data';

import 'package:burrow/utils/comic_archive.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isImageEntry', () {
    test('accepts known image extensions (case-insensitive)', () {
      for (final name in [
        'page1.jpg',
        'page2.JPEG',
        'cover.PNG',
        'p.gif',
        'p.webp',
        'p.bmp',
        'comics/page 01.JPG',
      ]) {
        expect(isImageEntry(name), isTrue, reason: name);
      }
    });

    test('rejects non-image entries', () {
      for (final name in [
        'info.txt',
        'thumbs.db',
        'cover.jpg.txt',
        'page',
        'archive.zip',
      ]) {
        expect(isImageEntry(name), isFalse, reason: name);
      }
    });

    test('is case-insensitive on extensions', () {
      expect(isImageEntry('a.jpg'), isTrue);
      expect(isImageEntry('b.TXT'), isFalse);
      expect(isImageEntry('c.webp'), isTrue);
      expect(isImageEntry('d'), isFalse);
      expect(isImageEntry('e.PNG'), isTrue);
    });
  });

  group('naturalCompare', () {
    test('page2 sorts before page10', () {
      expect(naturalCompare('page2.jpg', 'page10.jpg'), lessThan(0));
      expect(naturalCompare('page10.jpg', 'page2.jpg'), greaterThan(0));
      expect(naturalCompare('page2.jpg', 'page2.jpg'), 0);
    });

    test('sorts a mixed page list in reading order', () {
      final names = [
        'page10.jpg',
        'page2.jpg',
        'page1.jpg',
        'page20.jpg',
        'page3.jpg',
      ]..sort(naturalCompare);
      expect(names, [
        'page1.jpg',
        'page2.jpg',
        'page3.jpg',
        'page10.jpg',
        'page20.jpg',
      ]);
    });

    test('orders numeric segments numerically', () {
      const pairs = [
        ('10.jpg', '2.jpg', 1),
        ('a1b2.jpg', 'a1b10.jpg', -1),
        ('Page2.JPG', 'page10.jpg', -1),
        ('same.jpg', 'same.jpg', 0),
      ];
      for (final (a, b, sign) in pairs) {
        expect(naturalCompare(a, b).sign, sign, reason: '$a vs $b');
      }
    });
  });

  group('decodeImageDimensions', () {
    test('decodes GIF logical screen size', () {
      final gif = Uint8List.fromList([
        0x47, 0x49, 0x46, 0x38, 0x39, 0x61, // GIF89a
        0x40, 0x01, // width 320 (LE)
        0xC8, 0x00, // height 200 (LE)
        0x00,
      ]);
      expect(decodeImageDimensions(gif), (320, 200));
    });

    test('decodes PNG IHDR size', () {
      final png = Uint8List(24);
      png.setRange(0, 4, [0x89, 0x50, 0x4E, 0x47]);
      // width 320 @16, height 200 @20, big-endian.
      png[16] = 0x00;
      png[17] = 0x00;
      png[18] = 0x01;
      png[19] = 0x40;
      png[20] = 0x00;
      png[21] = 0x00;
      png[22] = 0x00;
      png[23] = 0xC8;
      expect(decodeImageDimensions(png), (320, 200));
    });

    test('decodes BMP bitmap dimensions', () {
      final bmp = Uint8List(26);
      bmp[0] = 0x42;
      bmp[1] = 0x4D;
      bmp[18] = 0x40; // width 320 (LE)
      bmp[19] = 0x01;
      bmp[22] = 0x2C; // height 300 (LE)
      bmp[23] = 0x01;
      expect(decodeImageDimensions(bmp), (320, 300));
    });

    test('decodes WebP VP8X canvas size', () {
      final webp = Uint8List(30);
      webp.setRange(0, 4, [0x52, 0x49, 0x46, 0x46]); // RIFF
      webp.setRange(8, 12, [0x57, 0x45, 0x42, 0x50]); // WEBP
      webp.setRange(12, 16, [0x56, 0x50, 0x38, 0x58]); // VP8X
      webp[24] = 0x3F; // width-1 = 319
      webp[25] = 0x01;
      webp[27] = 0xC7; // height-1 = 199
      expect(decodeImageDimensions(webp), (320, 200));
    });

    test('decodes SVG viewBox and width/height', () {
      expect(
        decodeImageDimensions(
          Uint8List.fromList(utf8.encode('<svg viewBox="0 0 120 80"></svg>')),
        ),
        (120, 80),
      );
      expect(
        decodeImageDimensions(
          Uint8List.fromList(utf8.encode('<svg width="300" height="150"></svg>')),
        ),
        (300, 150),
      );
    });

    test('unknown bytes decode to (0, 0), not a throw', () {
      expect(decodeImageDimensions(Uint8List(0)), (0, 0));
      expect(
        decodeImageDimensions(Uint8List.fromList([1, 2, 3, 4])),
        (0, 0),
      );
    });

    test('decodes a small SVG viewBox', () {
      expect(
        decodeImageDimensions(
          Uint8List.fromList(utf8.encode('<svg viewBox="0 0 5 6"></svg>')),
        ),
        (5, 6),
      );
    });
  });
}
