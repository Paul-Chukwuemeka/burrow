import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:burrow/utils/cover_prep.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

Uint8List _tinyJpeg() {
  final image = img.Image(width: 10, height: 10);
  img.fill(image, color: img.ColorRgb8(10, 20, 30));
  return Uint8List.fromList(img.encodeJpg(image));
}

/// A JPEG big enough that decoding + resizing + re-encoding it is real work
/// (tens to hundreds of milliseconds of pure-Dart CPU).
Uint8List _bigJpeg(int width, int height) {
  final image = img.Image(width: width, height: height);
  for (var y = 0; y < height; y += 4) {
    for (var x = 0; x < width; x += 4) {
      image.setPixelRgb(x, y, (x * 7) % 256, (y * 13) % 256, (x + y) % 256);
    }
  }
  return Uint8List.fromList(img.encodeJpg(image, quality: 90));
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

    test('odd dimensions (panorama) degrade gracefully', () {
      final pano = Uint8List.fromList(
        img.encodePng(img.Image(width: 3000, height: 50)),
      );
      final util = prepareCover(pano);
      expect(util, isNotNull);
      final decoded = img.decodeImage(util!);
      expect(decoded, isNotNull);
      expect(math.max(decoded!.width, decoded.height), lessThanOrEqualTo(480));
    });

    test('is idempotent across every input class', () {
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
        // A second pass over the output must be a fixpoint: covers are never
        // re-encoded into something different.
        final once = prepareCover(input);
        expect(prepareCover(once), once == null ? isNull : orderedEquals(once));
      }
    });
  });

  // Regression coverage for the first-load freeze: the Rust engine calls this
  // on the UI isolate, and the retired Dart parser ran the same work inside
  // `compute`. If it ever moves back inline, these tests go red.
  group('prepareCoverAsync (off-isolate cover prep)', () {
    test('null and empty degrade to null, not a throw', () async {
      expect(await prepareCoverAsync(null), isNull);
      expect(await prepareCoverAsync(Uint8List(0)), isNull);
    });

    test('small covers short-circuit without spawning an isolate', () async {
      final small = _tinyJpeg();
      final out = await prepareCoverAsync(small);
      // Same object back: the cheap header check short-circuited, no worker.
      expect(identical(out, small), isTrue);
    });

    test('matches prepareCover byte-for-byte on oversized input', () async {
      final big = _bigJpeg(800, 1200);
      final sync = prepareCover(big);
      final async = await prepareCoverAsync(big);
      expect(async, isNotNull);
      expect(async, orderedEquals(sync!));
      final decoded = img.decodeImage(async!);
      expect(decoded, isNotNull);
      expect(math.max(decoded!.width, decoded.height), lessThanOrEqualTo(480));
    });

    test('keeps the caller isolate free while it runs', () async {
      final big = _bigJpeg(1200, 1800);

      var ticks = 0;
      var maxGapMs = 0;
      var last = DateTime.now();
      final heartbeat = Timer.periodic(const Duration(milliseconds: 5), (_) {
        final now = DateTime.now();
        final gap = now.difference(last).inMilliseconds;
        if (gap > maxGapMs) maxGapMs = gap;
        last = now;
        ticks++;
      });

      final watch = Stopwatch()..start();
      final out = await prepareCoverAsync(big);
      watch.stop();
      heartbeat.cancel();

      expect(out, isNotNull);
      // The workload must be heavy enough for the assertion to mean anything;
      // if this fails the image got too small to prove anything.
      expect(
        watch.elapsedMilliseconds,
        greaterThan(60),
        reason: 'workload too small to distinguish blocking from not blocking',
      );
      // Inline, the caller would have one gap ≈ the whole duration. Off-isolate,
      // the heartbeat keeps ticking and no single gap dominates.
      expect(ticks, greaterThan(3));
      expect(maxGapMs, lessThan(watch.elapsedMilliseconds ~/ 2));
    });
  });
}
