import 'dart:typed_data';

import 'package:burrow/models/reader_settings.dart';
import 'package:burrow/models/style_run.dart';
import 'package:burrow/services/paginator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const style = TextStyle(fontSize: 16, height: 1.5);
  const viewport = Size(300, 400);
  const slack = 6.0;

  Paginator paginate(
    String text, {
    double inset = 0,
    List<StyleRun> runs = const [],
    List<ImageRun> images = const [],
  }) {
    return Paginator.paginate(
      text: text,
      style: style,
      maxWidth: viewport.width,
      maxHeight: viewport.height,
      direction: TextDirection.ltr,
      firstPageInset: inset,
      runs: runs,
      images: images,
      settings: ReaderSettings(),
      theme: ReaderTheme.light,
    );
  }

  Set<int> graphemeBoundaries(String s) {
    final set = <int>{0};
    var i = 0;
    for (final ch in s.characters) {
      i += ch.length;
      set.add(i);
    }
    return set;
  }

  void expectNoOverflow(Paginator p, String text) {
    final budget = viewport.height - slack;
    for (var i = 0; i < p.pages.length; i++) {
      final slice = text.substring(p.pages[i].start, p.pages[i].end);
      final tp = TextPainter(
        text: TextSpan(text: slice, style: style),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: viewport.width);
      final height = tp.height;
      tp.dispose();
      expect(
        height,
        lessThanOrEqualTo(budget + 0.01),
        reason: 'page $i overflows',
      );
    }
  }

  group('Line-metrics paginator', () {
    test('never splits grapheme clusters', () {
      // ZWJ family emoji, skin-tone modifier, combining accent, surrogate pair.
      final unit = '👨‍👩‍👧‍👦 e\u0301 résumé 👍🏽 café ';
      final text = List.generate(120, (_) => unit).join().trim();
      final boundaries = graphemeBoundaries(text);

      final p = paginate(text);
      expect(p.pages, isNotEmpty);
      for (final page in p.pages) {
        expect(
          boundaries,
          contains(page.start),
          reason: 'page start ${page.start} splits a cluster',
        );
        expect(
          boundaries,
          contains(page.end),
          reason: 'page end ${page.end} splits a cluster',
        );
      }
    });

    test('paginates CJK text with no whitespace', () {
      final text = '漢字の文章です。' * 400;
      final p = paginate(text);

      expect(p.pages.length, greaterThan(1));
      expect(p.pages.first.start, 0);
      expect(p.pages.last.end, text.length);
      for (var i = 0; i < p.pages.length; i++) {
        expect(
          p.pages[i].end,
          greaterThan(p.pages[i].start),
          reason: 'page $i empty',
        );
        if (i > 0) {
          expect(p.pages[i].start, greaterThanOrEqualTo(p.pages[i - 1].end));
        }
      }
      expectNoOverflow(p, text);
    });

    test('chunking does not change page boundaries', () {
      final buf = StringBuffer();
      for (var i = 0; i < 80; i++) {
        buf.writeln('Paragraph $i has a few words in it and then ends.');
        buf.writeln();
      }
      final text = buf.toString();

      final oneShot = paginate(text);

      final driver = ChapterPaginationDriver(
        text: text,
        style: style,
        maxWidth: viewport.width,
        maxHeight: viewport.height,
        direction: TextDirection.ltr,
      );
      final byOne = <TextPage>[];
      while (!driver.isDone) {
        byOne.addAll(driver.nextChunk(1));
      }
      driver.dispose();

      final driver2 = ChapterPaginationDriver(
        text: text,
        style: style,
        maxWidth: viewport.width,
        maxHeight: viewport.height,
        direction: TextDirection.ltr,
      );
      final budgeted = <TextPage>[];
      while (!driver2.isDone) {
        budgeted.addAll(
          driver2.nextChunkUntil(minPages: 1, budget: Duration.zero),
        );
      }
      driver2.dispose();

      expect(byOne.length, oneShot.pages.length);
      expect(budgeted.length, oneShot.pages.length);
      for (var i = 0; i < oneShot.pages.length; i++) {
        expect(byOne[i].start, oneShot.pages[i].start);
        expect(byOne[i].end, oneShot.pages[i].end);
        expect(budgeted[i].start, oneShot.pages[i].start);
        expect(budgeted[i].end, oneShot.pages[i].end);
      }
    });

    test('reserves exact image height via placeholders', () {
      final before = 'word ' * 40; // length 200
      final text = '$before\uFFFC${' tail' * 60}';
      final image = ImageRun(
        offset: before.length,
        bytes: Uint8List(0),
        intrinsicWidth: 200,
        intrinsicHeight: 300,
        fullWidth: true,
      );

      final p = paginate(text, images: [image]);
      expect(p.pages, isNotEmpty);

      final imagePageIndex = p.pages.indexWhere(
        (pg) => pg.start <= image.offset && pg.end > image.offset,
      );
      expect(
        imagePageIndex,
        isNot(-1),
        reason: 'an image page should contain the placeholder',
      );

      // The oversized full-width image must own its page.
      final page = p.pages[imagePageIndex];
      expect(text.substring(page.start, page.end), contains('\uFFFC'));

      // Tiling still holds with images present.
      for (var i = 1; i < p.pages.length; i++) {
        expect(p.pages[i].start, greaterThanOrEqualTo(p.pages[i - 1].end));
        expect(
          text.substring(p.pages[i - 1].end, p.pages[i].start).trim(),
          isEmpty,
        );
      }

      // Every non-whitespace character belongs to some page: this fails if the
      // WidgetSpan placeholder shifted text offsets after the image.
      expect(p.pages.first.start, 0);
      expect(p.pages.last.end, text.length);
      for (var i = 0; i < text.length; i++) {
        if (text[i].trim().isEmpty) continue;
        final covered = p.pages.any((pg) => pg.start <= i && i < pg.end);
        expect(covered, isTrue, reason: 'offset $i (${text[i]}) uncovered');
      }
    });

    test('offsets stay aligned across multiple images', () {
      final buf = StringBuffer();
      final images = <ImageRun>[];
      for (var i = 0; i < 6; i++) {
        buf.write('paragraph $i ');
        buf.write('word ' * 12);
        buf.write('\uFFFC');
        images.add(
          ImageRun(
            offset: buf.length - 1,
            bytes: Uint8List(0),
            intrinsicWidth: 120,
            intrinsicHeight: 90,
          ),
        );
        buf.write('\n');
      }
      final text = buf.toString();

      final p = paginate(text, images: images);
      expect(text.substring(p.pages.last.end).trim(), isEmpty);
      for (final image in images) {
        final covered = p.pages.any(
          (pg) => pg.start <= image.offset && image.offset < pg.end,
        );
        expect(
          covered,
          isTrue,
          reason: 'image at ${image.offset} should be within a page',
        );
      }
    });

    test('pageIndexFor handles gaps, start and end edges', () {
      final text = '${'alpha ' * 200}\n\n${'beta ' * 200}';
      final p = paginate(text);
      expect(p.pages.first.start, 0);
      expect(p.pageIndexFor(0), 0);
      // Past the end clamps to the last page.
      expect(p.pageIndexFor(text.length), p.pages.length - 1);
      expect(p.pageIndexFor(text.length + 999), p.pages.length - 1);
      // Every page start resolves to itself; whitespace gaps resolve forward.
      for (var i = 0; i < p.pages.length; i++) {
        expect(p.pageIndexFor(p.pages[i].start), i);
      }
      for (var i = 1; i < p.pages.length; i++) {
        if (p.pages[i].start > p.pages[i - 1].end) {
          expect(p.pageIndexFor(p.pages[i - 1].end), i);
        }
      }
    });

    test('firstPageInset only shrinks the first page', () {
      final text = List.generate(400, (i) => 'word$i').join(' ');
      final plain = paginate(text);
      final inset = paginate(text, inset: viewport.height * 0.4);
      expect(inset.pages.first.end, lessThanOrEqualTo(plain.pages.first.end));
      expect(inset.pages.length, greaterThanOrEqualTo(plain.pages.length));
      expectNoOverflow(inset, text);
    });
  });
}
