import 'dart:async';
import 'dart:typed_data';


import 'package:burrow/services/comic_decode_ahead.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('comicPageDecodeBounds', () {
    const viewport = Size(412, 915);
    const dpr = 2.0;
    const intrinsic = (3000, 4500);

    test('fit-width decode covers the physical display with zoom headroom', () {
      final b = comicPageDecodeBounds(
        fit: BoxFit.fitWidth,
        viewport: viewport,
        devicePixelRatio: dpr,
        intrinsic: intrinsic,
      );
      expect(b, isNotNull);
      final (w, h) = b!;
      // Display scale: 412/3000; decode = scale * dpr * headroom.
      final scale = (412 / 3000) * dpr * comicDecodeHeadroom;
      expect(w, closeTo(3000 * scale, 1.5));
      expect(h, closeTo(4500 * scale, 1.5));
      expect(h / w, closeTo(4500 / 3000, 0.02), reason: 'aspect preserved');
    });

    test('fit-height and contain pick their own display scales', () {
      final contain = comicPageDecodeBounds(
        fit: BoxFit.contain,
        viewport: viewport,
        devicePixelRatio: dpr,
        intrinsic: intrinsic,
      )!;
      // 3000/412 = 7.3 vs 4500/915 = 4.9: width is the binding axis, so
      // contain behaves exactly like fit-width here.
      expect(contain, equals(comicPageDecodeBounds(fit: BoxFit.fitWidth,
        viewport: viewport,
        devicePixelRatio: dpr,
        intrinsic: intrinsic)));

      final fitHeight = comicPageDecodeBounds(
        fit: BoxFit.fitHeight,
        viewport: viewport,
        devicePixelRatio: dpr,
        intrinsic: intrinsic,
      )!;
      // Raw scale (915/4500)*2*1.5 = 0.61 → (1830, 2745); the 2048
      // dimension cap binds and shrinks aspect-correctly.
      expect(fitHeight.$2, 2048);
      expect(fitHeight.$1, closeTo(1830 * 2048 / 2745, 1.5));
      expect(fitHeight.$2 / fitHeight.$1, closeTo(1.5, 0.02));
    });

    test('decode never exceeds the natural resolution', () {
      final b = comicPageDecodeBounds(
        fit: BoxFit.fitWidth,
        viewport: viewport,
        devicePixelRatio: dpr,
        intrinsic: (1000, 1500),
      );
      // (412/1000) * 2 * 1.5 = 1.24 > 1 → clamped to native.
      expect(b, equals((1000, 1500)));
    });

    test('hard caps bound pathological pages', () {
      final tall = comicPageDecodeBounds(
        fit: BoxFit.fitWidth,
        viewport: viewport,
        devicePixelRatio: 3,
        intrinsic: (1000, 12000), // webcomic strip aspect
      );
      expect(tall!.$1, lessThanOrEqualTo(comicMaxDecodeDimension));
      expect(tall.$2, lessThanOrEqualTo(comicMaxDecodeDimension));
      expect(
        tall.$1 * tall.$2,
        lessThanOrEqualTo(comicMaxDecodePixels),
        reason: 'pixel budget bounds the image-cache working set',
      );

      expect(
        comicPageDecodeBounds(
          fit: BoxFit.fitWidth,
          viewport: viewport,
          devicePixelRatio: dpr,
          intrinsic: (0, 4500),
        ),
        isNull,
        reason: 'no usable intrinsic dims → decode unbounded, like today',
      );
    });
  });

  group('ComicDecodeAhead', () {
    late Map<int, Uint8List> pages;
    late Set<int> pending; // pages whose loader future is unresolved
    late Map<int, Completer<Uint8List?>> completers;
    late Map<int, int> requestCount;
    late List<(int, ImageProvider)> warmed;

    Uint8List fakeBytes(int index) =>
        pages.putIfAbsent(index, () => Uint8List.fromList([index]));

    ComicDecodeAhead build({int window = 3}) {
      pages = {};
      warmed = [];
      completers = {};
      requestCount = {};
      return ComicDecodeAhead(
        window: window,
        loadBytes: (index) {
          requestCount[index] = (requestCount[index] ?? 0) + 1;
          if (!pending.contains(index)) {
            return Future.value(fakeBytes(index));
          }
          final completer = completers.putIfAbsent(
            index,
            Completer<Uint8List?>.new,
          );
          return completer.future;
        },
        resolveBounds: (index) => (index == 5) ? null : (480, 720),
        warmup: (provider) {
          if (provider is! ResizeImage ||
              provider.imageProvider is! MemoryImage) {
            throw StateError('expected ResizeImage(MemoryImage(bytes))');
          }
          warmed.add((
            (provider.imageProvider as MemoryImage).bytes[0],
            provider,
          ));
        },
      );
    }

    tearDown(() {
      for (final completer in completers.values) {
        if (!completer.isCompleted) completer.complete(null);
      }
    });

    test('advance warms exactly the decodable window around the center',
        () async {
      final ahead = build();
      pending = {}; // everything resolves immediately
      ahead.advance(4);
      await Future<void>.delayed(Duration.zero);

      expect(requestCount.keys.toSet(), {1, 2, 3, 4, 5, 6, 7});
      final warmedIndices = warmed.map((w) => w.$1).toSet();
      expect(warmedIndices, {1, 2, 3, 4, 6, 7});
      expect(warmedIndices, isNot(contains(5)), reason: 'bounds null → skip');
      expect(ahead.debugDecoded, containsAll(warmedIndices));
      for (final (index, provider) in warmed) {
        final resize = provider as ResizeImage;
        expect(resize.width, 480);
        expect(resize.height, 720);
        expect((resize.imageProvider as MemoryImage).bytes[0], index);
      }
      ahead.dispose();
    });

    test('repeating advance at the same center does not re-warm', () async {
      final ahead = build();
      pending = {};
      ahead.advance(4);
      await Future<void>.delayed(Duration.zero);
      final before = warmed.length;
      ahead.advance(4);
      await Future<void>.delayed(Duration.zero);
      expect(warmed.length, equals(before));
      ahead.dispose();
    });

    test('moving the center warms only the new pages', () async {
      final ahead = build();
      pending = {6}; // stays pending throughout
      ahead.advance(3);
      await Future<void>.delayed(Duration.zero);
      warmed.clear();
      ahead.advance(8);
      await Future<void>.delayed(Duration.zero);
      // Window(8) = 5..11; 6 was requested but is still in flight, 7 and
      // 8 were never inside the first window (0..6) and are new, 0..4 pruned
      // by the window, so only 7..11 are new.
      expect(warmed.map((w) => w.$1).toSet(), {7, 8, 9, 10, 11});
      ahead.dispose();
    });

    test('pending loads are requested once, warmed on completion', () async {
      final ahead = build();
      pending = {6};
      ahead.advance(3);
      ahead.advance(3);
      await Future<void>.delayed(Duration.zero);
      expect(requestCount[6], 1, reason: 'in-flight dedupe');
      expect(warmed.map((w) => w.$1), isNot(contains(6)));

      completers[6]!.complete(fakeBytes(6));
      ahead.advance(3);
      await Future<void>.delayed(Duration.zero);
      expect(warmed.map((w) => w.$1), contains(6));
      expect(requestCount[6], 1, reason: 'completed page is not reloaded');
      ahead.dispose();
    });

    test('warmup and widget share byte identity for an exact cache key',
        () async {
      final ahead = build();
      pending = {};
      ahead.advance(4);
      await Future<void>.delayed(Duration.zero);
      final provider = warmed.firstWhere((w) => w.$1 == 4).$2 as ResizeImage;
      final bytes = (provider.imageProvider as MemoryImage).bytes;
      expect(identical(bytes, pages[4]), isTrue,
          reason: 'the widget renders via Image.memory(bytes) on the '
              'provider-cached instance; identity keeps the image cache key '
              'reliable');
      ahead.dispose();
    });
  });
}
