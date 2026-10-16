import 'dart:async';

import 'package:burrow/services/pdf_cover.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

const _pdf = 'test/fixtures/epub/mini.pdf';

void main() {
  group('renderPdfCoverThumbnail', () {
    test('renders a decodable 2:3 JPEG', () async {
      final bytes = await renderPdfCoverThumbnail(_pdf);
      expect(bytes, isNotNull);
      final decoded = img.decodeImage(bytes!);
      expect(decoded, isNotNull);
      expect(decoded!.width, 600);
      expect(decoded.height, 900);
    });

    test('missing file degrades to null, not a throw', () async {
      expect(
        await renderPdfCoverThumbnail('test/fixtures/epub/does-not-exist.pdf'),
        isNull,
      );
    });

    // Regression coverage for the first-load freeze: the centre-crop and JPEG
    // encode are pure-Dart CPU work. Inline they stalled the UI isolate for
    // ~700 ms per PDF during cover backfill (measured: maxGap 722 ms inline vs
    // 65 ms on the worker isolate), which a bulk import turns into a frozen
    // app. PDFium's own render already runs on pdfrx's worker.
    test('keeps the caller isolate free while cropping and encoding', () async {
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
      final bytes = await renderPdfCoverThumbnail(_pdf);
      watch.stop();
      heartbeat.cancel();

      expect(bytes, isNotNull);
      expect(ticks, greaterThan(10));
      // Inline crop+encode leaves one gap of hundreds of milliseconds; the
      // worker isolate leaves none. 250 ms is ~4x the observed ceiling, so a
      // slow machine cannot fail this, but an inline regression always will.
      expect(maxGapMs, lessThan(250));
    });
  });
}
