import 'dart:math' as math;
import 'dart:typed_data';

import 'package:burrow/services/document_parser.dart';
import 'package:burrow/utils/comic_archive.dart' as comic;
import 'package:burrow/utils/cover_prep.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

Uint8List _tinyJpeg() {
  final image = img.Image(width: 10, height: 10);
  img.fill(image, color: img.ColorRgb8(10, 20, 30));
  return Uint8List.fromList(img.encodeJpg(image));
}

void main() {
  group('prepareCover (standalone util)', () {
    test('null and empty degrade to null, not a throw', () {
      expect(prepareCover(null), isNull);
      expect(prepareCover(Uint8List(0)), isNull);
    });

    test('unreadable bytes degrade to the raw bytes, not a throw', () {
      final garbage = Uint8List.fromList(
        List<int>.generate(300, (i) => (i * 37 + 11) % 256),
      );
      final out = prepareCover(garbage);
      expect(out, isNotNull);
      expect(out, orderedEquals(garbage));
    });

    test('tiny garbage (under the skip-decode threshold) is returned as-is', () {
      final garbage = Uint8List.fromList(
        List<int>.generate(64, (i) => (i * 13 + 7) % 256),
      );
      expect(prepareCover(garbage), orderedEquals(garbage));
    });

    test('truncated image header degrades to raw bytes, not a throw', () {
      // PNG magic + partial IHDR: header parse yields nothing useful, the
      // full decode fails; must still return the input.
      final truncated = Uint8List.fromList([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D,
      ]);
      expect(prepareCover(truncated), orderedEquals(truncated));
    });

    test('small cover is returned untouched', () {
      final small = _tinyJpeg();
      expect(prepareCover(small), equals(small));
    });

    test('oversized cover is downscaled to the max dimension', () {
      final big = Uint8List.fromList(
        img.encodePng(img.Image(width: 2000, height: 1500)),
      );
      final out = prepareCover(big);
      expect(out, isNotNull);
      final decoded = img.decodeImage(out!);
      expect(decoded, isNotNull);
      expect(math.max(decoded!.width, decoded.height), lessThanOrEqualTo(480));
    });

    test('odd dimensions (panorama) degrade gracefully and match DocumentParser',
        () {
      final pano = Uint8List.fromList(
        img.encodePng(img.Image(width: 3000, height: 50)),
      );
      final util = prepareCover(pano);
      final legacy = DocumentParser.prepareCover(pano);
      expect(util, isNotNull);
      expect(util, orderedEquals(legacy!));
      final decoded = img.decodeImage(util!);
      expect(decoded, isNotNull);
      expect(math.max(decoded!.width, decoded.height), lessThanOrEqualTo(480));
    });

    test('matches DocumentParser.prepareCover on every input class', () {
      final big = Uint8List.fromList(
        img.encodePng(img.Image(width: 100, height: 900)),
      );
      final inputs = <List<int>?>[
        null,
        [],
        Uint8List.fromList([1, 2, 3]),
        _tinyJpeg(),
        big,
      ];
      for (final input in inputs) {
        final a = prepareCover(input);
        final b = DocumentParser.prepareCover(input);
        if (a == null || b == null) {
          expect(a, isNull);
          expect(b, isNull);
        } else {
          expect(a, orderedEquals(b));
        }
      }
      // comic_archive import is used below; silence unused-import lints.
      expect(comic.isImageEntry('page1.jpg'), isTrue);
    });
  });
}
