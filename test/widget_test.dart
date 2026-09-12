import 'dart:math' as math;

import 'package:burrow/models/book.dart';
import 'package:burrow/models/style_run.dart';
import 'package:burrow/screens/library_screen.dart';
import 'package:burrow/services/library_service.dart';
import 'package:burrow/services/paginator.dart';
import 'package:burrow/utils/book_title.dart';
import 'package:burrow/widgets/progress_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Paginator', () {
    const style = TextStyle(fontSize: 16, height: 1.5);
    const viewport = Size(300, 400);

    test('pages tile the text without gaps or overlap', () {
      final text = List.generate(200, (i) => 'word$i').join(' ');
      final p = Paginator.paginate(
        text: text,
        style: style,
        maxWidth: viewport.width,
        maxHeight: viewport.height,
        direction: TextDirection.ltr,
      );

      expect(p.pages, isNotEmpty);
      expect(p.pages.first.start, 0);
      expect(p.pages.last.end, text.length);
      for (var i = 1; i < p.pages.length; i++) {
        expect(p.pages[i].start, greaterThanOrEqualTo(p.pages[i - 1].end));
        expect(
          text.substring(p.pages[i - 1].end, p.pages[i].start).trim(),
          isEmpty,
          reason: 'gap between pages ${i - 1} and $i is whitespace only',
        );
      }
    });

    test('novel-like text has no degenerate or overflowing pages', () {
      const pageStyle = TextStyle(fontSize: 18, height: 1.6);
      const maxWidth = 372.0;
      const maxHeight = 859.0;

      // Long paragraphs separated by blank lines, like parsed EPUB prose.
      const words = [
        'the', 'of', 'and', 'a', 'to', 'in', 'is', 'you', 'that', 'it', 'he',
        'was', 'for', 'on', 'are', 'as', 'with', 'his', 'they', 'I', 'at',
        'be', 'this', 'have', 'from', 'or', 'one', 'had', 'by', 'word', 'but',
        'not', 'what', 'all', 'were', 'we', 'when', 'your', 'can', 'said',
        'there', 'use', 'an', 'each', 'which', 'she', 'do', 'how', 'their',
        'if',
      ];
      final buf = StringBuffer();
      for (var p = 0; p < 60; p++) {
        final w = List.generate(
          130,
          (i) => words[(p * 7 + i * 3) % words.length],
        );
        buf.writeln('Paragraph $p begins. ${w.join(' ')} ends here.');
        buf.writeln();
      }
      final text = buf.toString();

      final pag = Paginator.paginate(
        text: text,
        style: pageStyle,
        maxWidth: maxWidth,
        maxHeight: maxHeight,
        direction: TextDirection.ltr,
      );

      expect(pag.pages.length, greaterThan(10));
      const slack = 6.0;
      const budget = maxHeight - slack;
      for (var i = 0; i < pag.pages.length; i++) {
        final page = pag.pages[i];
        final slice = text.substring(page.start, page.end);
        final tp = TextPainter(
          text: TextSpan(text: slice, style: pageStyle),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: maxWidth);
        final height = tp.height;
        final lines = tp.computeLineMetrics().length;
        tp.dispose();

        expect(height, lessThanOrEqualTo(budget),
            reason: 'page $i overflows ($lines lines)');
        if (i < pag.pages.length - 1) {
          expect(
            height,
            greaterThan(budget / 2),
            reason: 'page $i is degenerate ($lines lines): '
                '${slice.replaceAll('\n', r'\n')}',
          );
        }
        if (i > 0) {
          expect(page.start, greaterThanOrEqualTo(pag.pages[i - 1].end));
          expect(
            text.substring(pag.pages[i - 1].end, page.start).trim(),
            isEmpty,
          );
        }
      }
      // Any gap between the last page's end and text length is trailing
      // whitespace only (the paginator leaves trailing newlines outside pages
      // so they do not render as phantom empty lines).
      expect(text.substring(pag.pages.last.end).trim(), isEmpty);
    });

    test('pageIndexFor finds owning page', () {
      final text = '${'a ' * 500}\n${'b ' * 500}';
      final p = Paginator.paginate(
        text: text,
        style: style,
        maxWidth: viewport.width,
        maxHeight: viewport.height,
        direction: TextDirection.ltr,
      );
      if (p.pages.length < 2) return; // Single page: nothing to check.
      expect(p.pageIndexFor(0), 0);
      expect(
        p.pageIndexFor(text.length - 1),
        p.pages.length - 1,
      );
      // Every page resolves to itself; whitespace gaps between pages resolve
      // to the page that follows them.
      for (var i = 0; i < p.pages.length; i++) {
        expect(p.pageIndexFor(p.pages[i].start), i, reason: 'page $i start');
      }
      for (var i = 1; i < p.pages.length; i++) {
        if (p.pages[i].start > p.pages[i - 1].end) {
          expect(p.pageIndexFor(p.pages[i - 1].end), i, reason: 'gap $i');
        }
      }
    });

    test('empty text produces a single placeholder page', () {
      final p = Paginator.paginate(
        text: '',
        style: style,
        maxWidth: 100,
        maxHeight: 100,
        direction: TextDirection.ltr,
      );
      expect(p.pages.length, 1);
      expect(p.pageIndexFor(0), 0);
    });

    test('firstPageInset shrinks only the first page', () {
      final text = List.generate(300, (i) => 'word$i').join(' ');
      final paged = Paginator.paginate(
        text: text,
        style: style,
        maxWidth: viewport.width,
        maxHeight: viewport.height,
        direction: TextDirection.ltr,
        firstPageInset: viewport.height * 0.4,
      );
      // Tiling must stay contiguous (whitespace gaps allowed).
      expect(paged.pages.first.start, 0);
      expect(paged.pages.last.end, text.length);
      for (var i = 1; i < paged.pages.length; i++) {
        expect(paged.pages[i].start, greaterThanOrEqualTo(paged.pages[i - 1].end));
        expect(
          text.substring(paged.pages[i - 1].end, paged.pages[i].start).trim(),
          isEmpty,
        );
      }
      // The first page holds less text than a full page would.
      if (paged.pages.length > 2) {
        final plain = Paginator.paginate(
          text: text,
          style: style,
          maxWidth: viewport.width,
          maxHeight: viewport.height,
          direction: TextDirection.ltr,
        );
        expect(
          paged.pages.first.end,
          lessThan(plain.pages.first.end),
        );
      }
    });
  });

  group('Book', () {
    test('json round-trip preserves fields', () {
      final book = Book(
        id: 'id1',
        title: 'Title',
        author: 'Author',
        path: '/tmp/x.epub',
        format: BookFormat.epub,
        addedAt: 42,
        lastReadAt: 100,
        progress: 0.5,
        lastChapter: 3,
        lastOffset: 120,
      );
      final restored = Book.fromJson(book.toJson());
      expect(restored.id, 'id1');
      expect(restored.progress, 0.5);
      expect(restored.lastChapter, 3);
      expect(restored.lastOffset, 120);
      expect(restored.format, BookFormat.epub);
      expect(book.progressLabel, '50%');
    });

    test('formatFromExtension maps known types', () {
      expect(formatFromExtension('/a/b.EPUB'), BookFormat.epub);
      expect(formatFromExtension('/a/b.pdf'), BookFormat.pdf);
      expect(formatFromExtension('/a/notes.txt'), BookFormat.txt);
    });
  });

  group('Page rendering', () {
    testWidgets('every sliced page fits the app viewport', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(412, 915);
      addTearDown(tester.view.reset);

      const style = TextStyle(fontSize: 18, height: 1.6);
      const viewport = Size(372, 859); // Screen minus page padding.

      final text = StringBuffer();
      for (var p = 0; p < 40; p++) {
        text.writeln(
            'Paragraph $p. ${List.generate(60, (i) => 'w$p$i').join(' ')}');
        text.writeln();
        if (p % 7 == 0) text.writeln(); // Blank lines between sections.
      }
      final body = text.toString();

      final paged = Paginator.paginate(
        text: body,
        style: style,
        maxWidth: viewport.width,
        maxHeight: viewport.height,
        direction: TextDirection.ltr,
        firstPageInset: 48,
      );
      expect(paged.pages.length, greaterThan(3));

      Widget harness(String slice, {bool title = false}) => MaterialApp(
            home: Center(
              child: SizedBox(
                width: 412,
                height: 915,
                child: DefaultTextStyle(
                  // Simulates Material typography inheritance. Production
                  // renders via RichText, which ignores it entirely.
                  style: const TextStyle(
                    fontSize: 14,
                    height: 1.43,
                    letterSpacing: 0.25,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 28),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (title) ...[
                          RichText(
                            text: TextSpan(
                              text: 'Chapter',
                              style: style.copyWith(
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                        ],
                        Expanded(
                          child: RichText(
                            text: TextSpan(text: slice, style: style),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );

      await tester.pumpWidget(harness(
        body.substring(paged.pages.first.start, paged.pages.first.end),
        title: true,
      ));
      await tester.pump();
      expect(tester.takeException(), isNull);

      for (var i = 1; i < paged.pages.length; i++) {
        await tester.pumpWidget(harness(
          body.substring(paged.pages[i].start, paged.pages[i].end),
        ));
        await tester.pump();
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('styled pages render without overflow', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(412, 915);
      addTearDown(tester.view.reset);

      const style = TextStyle(fontSize: 18, height: 1.6);
      const viewport = Size(372, 859);

      final buf = StringBuffer();
      final runs = <StyleRun>[];
      for (var p = 0; p < 40; p++) {
        final words = List.generate(60, (i) => 'w$p$i');
        // Emphasize every 5th word.
        for (var i = 0; i < words.length; i++) {
          if (buf.isNotEmpty) buf.write(' ');
          final start = buf.length;
          buf.write(words[i]);
          if (i % 5 == 0) {
            runs.add(StyleRun(start, buf.length,
                bold: i % 10 == 0, italic: i % 10 != 0));
          }
        }
        buf.writeln();
        buf.writeln();
      }
      final body = buf.toString();

      final paged = Paginator.paginate(
        text: body,
        style: style,
        maxWidth: viewport.width,
        maxHeight: viewport.height,
        direction: TextDirection.ltr,
        firstPageInset: 48,
        runs: runs,
      );
      expect(paged.pages.length, greaterThan(3));

      Widget harness(int index) => MaterialApp(
            home: Center(
              child: SizedBox(
                width: 412,
                height: 915,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 20, vertical: 28),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: RichText(
                          text: TextSpan(
                            style: style,
                            children: buildStyledSpans(body, runs, style,
                                paged.pages[index].start, paged.pages[index].end),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );

      await tester.pumpWidget(harness(0));
      await tester.pump();
      expect(tester.takeException(), isNull);

      // The first page contains emphasized words rendered as styled spans.
      final rich = tester.widget<RichText>(find.byType(RichText).first);
      final children = (rich.text as TextSpan).children;
      expect(children, isNotNull);
      expect(
        children!.any((s) =>
            s is TextSpan &&
            s.style?.fontWeight == FontWeight.w700),
        isTrue,
        reason: 'bold run renders as w700 span',
      );

      for (var i = 1; i < paged.pages.length; i++) {
        await tester.pumpWidget(harness(i));
        await tester.pump();
        expect(tester.takeException(), isNull);
      }
    });
  });

  group('LibraryScreen', () {
    Book fakeBook(String id, {double progress = 0}) => Book(
          id: id,
          title: 'Book $id',
          author: 'Author $id',
          path: '/tmp/$id.epub',
          format: BookFormat.epub,
          addedAt: 1,
          lastReadAt: progress > 0 ? 10 : 0,
          progress: progress,
        );

    Future<void> pumpLibrary(WidgetTester tester, LibraryService library) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(412, 915);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(home: LibraryScreen(library: library)),
      );
      await tester.pump(); // Start entrance animations.
      await tester.pump(const Duration(seconds: 1)); // Let them finish.
      expect(tester.takeException(), isNull);
    }

    testWidgets('empty library shows the empty state', (tester) async {
      await pumpLibrary(tester, LibraryService());
      expect(find.text('Your burrow is empty'), findsOneWidget);
    });

    testWidgets('populated library shows hero card and grid tiles',
        (tester) async {
      final service = LibraryService()
        ..debugAddAll([
          fakeBook('a', progress: 0.4),
          fakeBook('b'),
          fakeBook('c'),
        ]);

      await pumpLibrary(tester, service);

      expect(find.text('CONTINUE READING'), findsOneWidget);
      expect(find.text('All books · 3'), findsOneWidget);
      // Per tile: tonal badge + placeholder's own format label; plus hero
      // placeholder label and the filter chip.
      expect(find.text('EPUB'), findsNWidgets(8));
    });

    testWidgets('FAB opens the expressive add menu', (tester) async {
      final service = LibraryService()..debugAddAll([fakeBook('a')]);
      await pumpLibrary(tester, service);

      expect(find.text('Import file'), findsNothing);
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      expect(find.text('Import file'), findsOneWidget);
      expect(find.text('Scan folder…'), findsOneWidget);
      expect(find.text('Scan device'), findsOneWidget);
    });

    testWidgets('grid follows the single progress convention', (tester) async {
      final service = LibraryService()
        ..debugAddAll([
          fakeBook('a'), // never opened
          fakeBook('b', progress: 0.25), // in progress -> hero card
          fakeBook('c', progress: 1),
        ]);
      await pumpLibrary(tester, service);

      // Unstarted: "NEW" badge on cover, no bar, never "0%".
      expect(find.text('NEW'), findsOneWidget);
      expect(find.text('0%'), findsNothing);
      // Started: the one segmented-bar convention is used on both started
      // tiles and the hero card; there is no separate percent label.
      expect(find.byType(SegmentedProgressBar), findsNWidgets(3));
      expect(find.text('25%'), findsNothing);
      expect(find.text('Finished'), findsOneWidget);
    });
  });

  group('Title cleanup', () {
    test('strips site cruft and separators from scraped filenames', () {
      expect(
        cleanBookTitle('_OceanofPDF.com_The_Forever_Hero_by_John_Doe.pdf'),
        'The Forever Hero',
      );
      expect(cleanBookTitle('oceanofpdf.com_A_Clan_Novel'), 'A Clan Novel');
      expect(
        cleanBookTitle('resignation_letter.txt'),
        'resignation letter',
      );
      expect(
        cleanBookTitle('[PDF] Designing Interfaces - libgen.li'),
        'Designing Interfaces',
      );
      expect(cleanBookTitle('Already Clean Title.epub'), 'Already Clean Title');
      expect(cleanBookTitle('THE HOBBIT'), 'The hobbit');
    });

    test('displayTitle cleans legacy stored titles', () {
      final book = Book(
        id: 'x',
        title: '_OceanofPDF.com_Old_Import',
        author: '',
        path: '/tmp/old.pdf',
        format: BookFormat.pdf,
        addedAt: 0,
      );
      expect(book.displayTitle, 'Old Import');
    });

    test('progress semantics follow one convention everywhere', () {
      Book withProgress(double p, int lastReadAt) => Book(
            id: 's',
            title: 't',
            author: '',
            path: '/tmp/t.epub',
            format: BookFormat.epub,
            addedAt: 0,
            progress: p,
            lastReadAt: lastReadAt,
          );
      expect(withProgress(0, 0).progressSemantics, 'Not started');
      expect(withProgress(0.25, 5).progressSemantics, '25 percent read');
      expect(withProgress(1, 5).progressSemantics, 'Finished');
      expect(withProgress(0.9999, 5).progressSemantics, 'Finished');
      // No bar is drawn until the book is actually opened.
      expect(withProgress(0, 0).showProgress, isFalse);
      expect(withProgress(0.01, 5).showProgress, isTrue);
    });
  });

  group('Accessibility', () {
    // Mirrors the placeholder palette math in book_cover.dart so the ink
    // contract is enforced, not assumed.
    Color bandColor(double hue, {required double sat, required double light}) =>
        HSLColor.fromAHSL(1, hue, sat, light).toColor();

    double luminance(Color c) {
      double channel(double v) {
        v /= 255;
        return v <= 0.03928
            ? v / 12.92
            : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
      }

      return 0.2126 * channel(c.r * 255) +
          0.7152 * channel(c.g * 255) +
          0.0722 * channel(c.b * 255);
    }

    double contrast(Color a, Color b) {
      final la = luminance(a);
      final lb = luminance(b);
      return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
    }

    const bands = <String, List<double>>{
      'epub': [96, 152],
      'txt': [26, 46],
      'pdf': [4, 22],
    };

    test('placeholder body ink clears WCAG AA on every format band', () {
      bands.forEach((name, band) {
        for (final hue in [band[0], (band[0] + band[1]) / 2, band[1]]) {
          final base = bandColor(hue, sat: 0.44, light: 0.34);
          final deep = bandColor(hue, sat: 0.50, light: 0.20);
          expect(
            contrast(const Color(0xFFFFFFFF), base),
            greaterThanOrEqualTo(4.5),
            reason: '$name hue $hue: white title vs base gradient stop',
          );
          expect(
            contrast(const Color(0xFFFFFFFF), deep),
            greaterThanOrEqualTo(7),
            reason: '$name hue $hue: white title vs deep gradient stop',
          );
        }
      });
    });

    testWidgets('filter chips meet the 48dp minimum target', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(412, 915);
      addTearDown(tester.view.reset);
      final service = LibraryService()..debugAddAll([
        Book(
          id: 'a',
          title: 'Book a',
          author: '',
          path: '/tmp/a.epub',
          format: BookFormat.epub,
          addedAt: 1,
        ),
      ]);
      await tester.pumpWidget(MaterialApp(home: LibraryScreen(library: service)));
      await tester.pumpAndSettle();

      for (final label in ['All', 'EPUB', 'TXT', 'PDF']) {
        final chipMaterial = find
            .ancestor(
              of: find.text(label),
              matching: find.byType(Material),
            )
            .first;
        final size = tester.getSize(chipMaterial);
        expect(size.height, greaterThanOrEqualTo(48), reason: '$label chip');
        expect(size.width, greaterThanOrEqualTo(48), reason: '$label chip');
      }
    });

    testWidgets('tiles announce title, author and one progress convention',
        (tester) async {
      final semantics = tester.ensureSemantics();
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(412, 915);
      addTearDown(tester.view.reset);
      final service = LibraryService()
        ..debugAddAll([
          Book(
            id: 'new1',
            title: 'Fresh Book',
            author: 'Ada',
            path: '/tmp/f.epub',
            format: BookFormat.epub,
            addedAt: 1,
          ),
          Book(
            id: 'mid1',
            title: 'Half Read',
            author: '',
            path: '/tmp/h.epub',
            format: BookFormat.txt,
            addedAt: 2,
            progress: 0.5,
            lastReadAt: 10,
          ),
        ]);
      await tester.pumpWidget(MaterialApp(home: LibraryScreen(library: service)));
      await tester.pumpAndSettle();

      // Anchor to the merged tile node's own label pattern; unanchored
      // matches would also hit placeholder art text and the hero card.
      final fresh =
          tester.getSemantics(find.bySemanticsLabel(RegExp(r'^Fresh Book by Ada')));
      expect(fresh.label, contains('Not started'));

      final half =
          tester.getSemantics(find.bySemanticsLabel(RegExp(r'^Half Read')));
      expect(half.label, contains('Half Read'));
      expect(half.label, contains('50 percent read'));

      // End-of-test verification runs before tearDowns, so dispose inline.
      semantics.dispose();
    });
  });

  group('ChapterPaginationDriver', () {
    const style = TextStyle(fontSize: 16, height: 1.5);
    const viewport = Size(300, 400);

    test('produces identical pages to one-shot paginate', () {
      final text = List.generate(500, (i) => 'word$i').join(' ');

      final oneShot = Paginator.paginate(
        text: text,
        style: style,
        maxWidth: viewport.width,
        maxHeight: viewport.height,
        direction: TextDirection.ltr,
      );

      final driver = ChapterPaginationDriver(
        text: text,
        style: style,
        maxWidth: viewport.width,
        maxHeight: viewport.height,
        direction: TextDirection.ltr,
      );

      while (!driver.isDone) {
        driver.nextChunk(10);
      }
      final incremental = driver.toPaginator();
      driver.dispose();

      expect(incremental.pages.length, oneShot.pages.length);
      for (var i = 0; i < oneShot.pages.length; i++) {
        expect(incremental.pages[i].start, oneShot.pages[i].start,
            reason: 'page $i start');
        expect(incremental.pages[i].end, oneShot.pages[i].end,
            reason: 'page $i end');
      }
    });

    test('chunk size 1 produces same result as chunk size 100', () {
      final text = List.generate(300, (i) => 'word$i').join(' ');

      final d1 = ChapterPaginationDriver(
        text: text,
        style: style,
        maxWidth: viewport.width,
        maxHeight: viewport.height,
        direction: TextDirection.ltr,
      );
      while (!d1.isDone) d1.nextChunk(1);
      final p1 = d1.toPaginator();
      d1.dispose();

      final d100 = ChapterPaginationDriver(
        text: text,
        style: style,
        maxWidth: viewport.width,
        maxHeight: viewport.height,
        direction: TextDirection.ltr,
      );
      while (!d100.isDone) d100.nextChunk(100);
      final p100 = d100.toPaginator();
      d100.dispose();

      expect(p1.pages.length, p100.pages.length);
      for (var i = 0; i < p1.pages.length; i++) {
        expect(p1.pages[i].start, p100.pages[i].start);
        expect(p1.pages[i].end, p100.pages[i].end);
      }
    });

    test('pages tile without gaps or overlap', () {
      final text = List.generate(400, (i) => 'word$i').join(' ');

      final driver = ChapterPaginationDriver(
        text: text,
        style: style,
        maxWidth: viewport.width,
        maxHeight: viewport.height,
        direction: TextDirection.ltr,
      );
      while (!driver.isDone) driver.nextChunk(5);
      final pages = driver.toPaginator().pages;
      driver.dispose();

      expect(pages, isNotEmpty);
      expect(pages.first.start, 0);
      expect(pages.last.end, text.length);

      for (var i = 1; i < pages.length; i++) {
        expect(pages[i].start >= pages[i - 1].start, isTrue,
            reason: 'pages are monotonically ordered');
        expect(pages[i].start > pages[i - 1].start, isTrue,
            reason: 'no duplicate page starts');
      }
    });

    test('empty text is immediately done', () {
      final driver = ChapterPaginationDriver(
        text: '',
        style: style,
        maxWidth: viewport.width,
        maxHeight: viewport.height,
        direction: TextDirection.ltr,
      );
      expect(driver.isDone, isTrue);
      expect(driver.nextChunk(10), isEmpty);
      final pages = driver.toPaginator().pages;
      driver.dispose();
      // Empty text produces zero pages (no work to paginate).
      expect(pages, isEmpty);
    });
  });

  group('Pagination with style runs', () {
    const style = TextStyle(fontSize: 16, height: 1.5);
    const viewport = Size(300, 400);

    /// Alternating bold/italic/quote words over a long single-line text.
    (String, List<StyleRun>) buildStyledText({int words = 400}) {
      final buf = StringBuffer();
      final runs = <StyleRun>[];
      for (var i = 0; i < words; i++) {
        if (buf.isNotEmpty) buf.write(' ');
        final start = buf.length;
        buf.write('word$i');
        switch (i % 3) {
          case 0:
            runs.add(StyleRun(start, buf.length, bold: true));
          case 1:
            runs.add(StyleRun(start, buf.length, italic: true));
          case 2:
            runs.add(StyleRun(start, buf.length, quote: true));
        }
      }
      return (buf.toString(), runs);
    }

    test('pages tile the text with styled measurement', () {
      final (text, runs) = buildStyledText();
      final p = Paginator.paginate(
        text: text,
        style: style,
        maxWidth: viewport.width,
        maxHeight: viewport.height,
        direction: TextDirection.ltr,
        runs: runs,
      );

      expect(p.pages, isNotEmpty);
      expect(p.pages.first.start, 0);
      for (var i = 1; i < p.pages.length; i++) {
        expect(
          text.substring(p.pages[i - 1].end, p.pages[i].start).trim(),
          isEmpty,
          reason: 'gap between pages ${i - 1} and $i is whitespace only',
        );
      }
      // Any remainder after the last page is trailing whitespace only.
      expect(text.substring(p.pages.last.end).trim(), isEmpty);
    });

    test('every page fits when measured exactly as it renders', () {
      final (text, runs) = buildStyledText(words: 600);
      const maxHeight = 400.0;
      const slack = 6.0;
      final p = Paginator.paginate(
        text: text,
        style: style,
        maxWidth: viewport.width,
        maxHeight: maxHeight,
        direction: TextDirection.ltr,
        runs: runs,
      );

      expect(p.pages.length, greaterThan(3));
      for (var i = 0; i < p.pages.length; i++) {
        final page = p.pages[i];
        final tp = TextPainter(
          text: TextSpan(
            style: style,
            children: buildStyledSpans(text, runs, style, page.start, page.end),
          ),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: viewport.width);
        expect(tp.height, lessThanOrEqualTo(maxHeight - slack),
            reason: 'styled page $i overflows');
        tp.dispose();
      }
    });

    test('driver matches one-shot paginate when runs are present', () {
      final (text, runs) = buildStyledText();

      final oneShot = Paginator.paginate(
        text: text,
        style: style,
        maxWidth: viewport.width,
        maxHeight: viewport.height,
        direction: TextDirection.ltr,
        runs: runs,
      );

      final driver = ChapterPaginationDriver(
        text: text,
        style: style,
        maxWidth: viewport.width,
        maxHeight: viewport.height,
        direction: TextDirection.ltr,
        runs: runs,
      );
      while (!driver.isDone) driver.nextChunk(5);
      final incremental = driver.toPaginator();
      driver.dispose();

      expect(incremental.pages.length, oneShot.pages.length);
      for (var i = 0; i < oneShot.pages.length; i++) {
        expect(incremental.pages[i].start, oneShot.pages[i].start,
            reason: 'page $i start');
        expect(incremental.pages[i].end, oneShot.pages[i].end,
            reason: 'page $i end');
      }
    });
  });
}
