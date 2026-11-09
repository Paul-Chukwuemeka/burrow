import 'dart:typed_data';

import 'package:burrow/models/css_style.dart';
import 'package:burrow/models/document.dart' show ChapterLink;
import 'package:burrow/models/highlight_palette.dart';
import 'package:burrow/models/reader_settings.dart';
import 'package:burrow/models/style_run.dart';
import 'package:burrow/services/book_search.dart';
import 'package:burrow/utils/page_spans.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const style = TextStyle(fontSize: 18, height: 1.6);
  const theme = ReaderTheme.light;

  SearchResult match(int offset, int length) =>
      SearchResult(chapter: 0, offset: offset, length: length, snippet: '');

  /// Wraps the List<InlineSpan> result into a single TextSpan for testing.
  TextSpan wrapSpans(List<InlineSpan> spans) =>
      TextSpan(style: style, children: spans);

  /// Flattens the span tree, pairing each leaf's text with its style.
  List<(String, TextStyle?)> leaves(TextSpan span) {
    final out = <(String, TextStyle?)>[];
    void walk(InlineSpan s) {
      if (s is TextSpan) {
        if (s.text != null) out.add((s.text!, s.style));
        for (final c in s.children ?? const <InlineSpan>[]) {
          walk(c);
        }
      }
    }

    walk(span);
    return out;
  }

  group('buildPageSpans', () {
    const text = 'The quick brown fox jumps over the lazy dog.';

    test('returns the plain slice when there is nothing to style', () {
      final span = wrapSpans(
        buildPageSpans(
          text: text,
          start: 4,
          end: 19,
          base: style,
          theme: theme,
          settings: ReaderSettings(),
        ),
      );

      expect(span.toPlainText(), 'quick brown fox');
      expect(span.style, style);
      expect(span.children, isNotNull);
    });

    // Regression: a cascade binds to the whole conditional expression, so
    // `cond ? const [] : List.of(x)..sort()` sorted the const list and threw
    // "Cannot modify an unmodifiable list" while building the page.
    test('does not mutate caller lists, even unmodifiable ones', () {
      final runs = List<StyleRun>.unmodifiable([
        const StyleRun(10, 15, bold: true),
        const StyleRun(4, 9, italic: true),
      ]);
      final matches = List<SearchResult>.unmodifiable([
        match(16, 3),
        match(4, 5),
      ]);

      final span = wrapSpans(
        buildPageSpans(
          text: text,
          start: 0,
          end: text.length,
          base: style,
          theme: theme,
          settings: ReaderSettings(),
          runs: runs,
          matches: matches,
        ),
      );

      expect(span.toPlainText(), text);
      // Caller ordering is untouched by the internal sort.
      expect(runs.first.start, 10);
      expect(matches.first.offset, 16);
    });

    test('styles runs and no-run gaps without dropping text', () {
      const runs = [StyleRun(4, 9, bold: true), StyleRun(16, 19, quote: true)];

      final span = wrapSpans(
        buildPageSpans(
          text: text,
          start: 0,
          end: 20,
          base: style,
          theme: theme,
          settings: ReaderSettings(),
          runs: runs,
        ),
      );

      expect(span.toPlainText(), text.substring(0, 20));
      final parts = leaves(span);
      expect(parts.map((p) => p.$1), ['The ', 'quick', ' brown ', 'fox', ' ']);
      expect(parts[1].$2?.fontWeight, FontWeight.w700);
      expect(parts[2].$2?.fontWeight, isNull, reason: 'gap keeps base style');
      expect(parts[3].$2?.fontStyle, FontStyle.italic);
      expect(parts[3].$2?.color, theme.muted);
    });

    test('highlights matches, emphasizing only the current one', () {
      final current = match(4, 5);
      final other = match(20, 5);

      final span = wrapSpans(
        buildPageSpans(
          text: text,
          start: 0,
          end: text.length,
          base: style,
          theme: theme,
          settings: ReaderSettings(),
          matches: [current, other],
          currentMatch: current,
        ),
      );

      expect(span.toPlainText(), text);
      final parts = leaves(span);
      final currentSpan = parts.firstWhere((p) => p.$1 == 'quick').$2!;
      final otherSpan = parts.firstWhere((p) => p.$1 == 'jumps').$2!;

      expect(currentSpan.color, theme.accent);
      expect(currentSpan.fontWeight, FontWeight.w700);
      expect(currentSpan.backgroundColor?.a, closeTo(0.35, 0.001));

      expect(otherSpan.color, isNot(theme.accent));
      expect(otherSpan.fontWeight, isNull);
      expect(otherSpan.backgroundColor?.a, closeTo(0.15, 0.001));
    });

    // Regression: the current hit used to be looked up by index into the
    // page-local match list, so an off-page (or unset, -1) selection wrapped
    // around and emphasized an arbitrary match on the page.
    test('no match is emphasized when the current hit is off this page', () {
      final span = wrapSpans(
        buildPageSpans(
          text: text,
          start: 0,
          end: 20,
          base: style,
          theme: theme,
          settings: ReaderSettings(),
          matches: [match(4, 5)],
          currentMatch: match(35, 3),
        ),
      );

      final hit = leaves(span).firstWhere((p) => p.$1 == 'quick').$2!;
      expect(hit.backgroundColor?.a, closeTo(0.15, 0.001));
      expect(hit.fontWeight, isNull);
    });

    test('clips matches that straddle the page boundary', () {
      // "brown fox" starts on this page and continues past its end.
      final span = wrapSpans(
        buildPageSpans(
          text: text,
          start: 4,
          end: 15,
          base: style,
          theme: theme,
          settings: ReaderSettings(),
          matches: [match(10, 9)],
        ),
      );

      expect(span.toPlainText(), 'quick brown');
      final parts = leaves(span);
      expect(parts.map((p) => p.$1), ['quick ', 'brown']);
      expect(parts.last.$2?.backgroundColor, isNotNull);
    });

    test('highlight styling wins inside emphasized text', () {
      final span = wrapSpans(
        buildPageSpans(
          text: text,
          start: 0,
          end: 20,
          base: style,
          theme: theme,
          settings: ReaderSettings(),
          runs: const [StyleRun(4, 15, quote: true)],
          matches: [match(10, 5)],
          currentMatch: match(10, 5),
        ),
      );

      final parts = leaves(span);
      final hit = parts.firstWhere((p) => p.$1 == 'brown').$2!;
      expect(hit.fontStyle, FontStyle.italic, reason: 'run styling survives');
      expect(
        hit.color,
        theme.accent,
        reason: 'highlight color overrides quote',
      );
      expect(hit.backgroundColor, isNotNull);
    });

    test('ignores runs and matches outside the page', () {
      final span = wrapSpans(
        buildPageSpans(
          text: text,
          start: 0,
          end: 10,
          base: style,
          theme: theme,
          settings: ReaderSettings(),
          runs: const [StyleRun(20, 25, bold: true)],
          matches: [match(30, 4)],
        ),
      );

      expect(span.toPlainText(), text.substring(0, 10));
      expect(leaves(span).every((p) => p.$2?.fontWeight == null), isTrue);
    });

    test('links carry guaranteed accent underline styling', () {
      // Link covers "quick brown" (4..15); no source styling at all.
      final span = wrapSpans(
        buildPageSpans(
          text: text,
          start: 4,
          end: 19,
          base: style,
          theme: theme,
          settings: ReaderSettings(),
          links: const [ChapterLink(4, 15, 3)],
        ),
      );

      final hits = leaves(span);
      // The whole page text is still tiled.
      expect(span.toPlainText(), text.substring(4, 19));
      final linked = hits.where((p) => p.$2?.decoration != null).toList();
      expect(linked.map((p) => p.$1).join(), 'quick brown');
      for (final (_, line) in linked) {
        expect(line?.color, theme.accent);
        expect(line?.decoration, TextDecoration.underline);
      }
      // The unlinked remainder keeps the plain styles ("fox" plus the gap
      // between the link and the page edge).
      expect(hits.last.$1, ' fox');
      expect(hits.last.$2?.decoration, isNull);
      expect(hits.last.$2?.color, isNull);
    });

    test('a link boundary cuts the styled spans apart', () {
      // Two adjacent links over one page: they must not merge into one span.
      final span = wrapSpans(
        buildPageSpans(
          text: text,
          start: 4,
          end: 19,
          base: style,
          theme: theme,
          settings: ReaderSettings(),
          links: const [ChapterLink(4, 9, 1), ChapterLink(10, 15, 2)],
        ),
      );

      final linked = leaves(span);
      // Tile: "quick"(link) | " " (the gap belongs to neither) |
      // "brown"(link) | " fox"(unstyled).
      expect(linked, hasLength(4));
      expect(linked[0].$1, 'quick');
      expect(linked[0].$2?.decoration, TextDecoration.underline);
      expect(linked[1].$1, ' ');
      expect(linked[1].$2?.decoration, isNull);
      expect(linked[2].$1, 'brown');
      expect(linked[2].$2?.decoration, TextDecoration.underline);
      expect(linked[3].$1, ' fox');
      expect(linked[3].$2?.decoration, isNull);
    });

    test('a styled run inside a link keeps bold and gains accent', () {
      final span = wrapSpans(
        buildPageSpans(
          text: text,
          start: 4,
          end: 19,
          base: style,
          theme: theme,
          settings: ReaderSettings(),
          runs: const [StyleRun(4, 9, bold: true)],
          links: const [ChapterLink(4, 15, 3)],
        ),
      );

      final linked = leaves(span);
      // Tile: "quick" (bold run + link) | " brown " (link only) | " fox ".
      expect(linked[0].$2?.fontWeight, FontWeight.w700);
      expect(linked[0].$2?.color, theme.accent);
      final brown = linked.firstWhere((p) => p.$1.contains('brown'));
      expect(brown.$2?.fontWeight, isNull);
      expect(brown.$2?.color, theme.accent);
      expect(linked.last.$2?.color, isNull);
    });
  });

  group('ImageRun sizing', () {
    test('renderedHeight caps portrait image at fixed 150px', () {
      // 800×1200 portrait at 370px width → natural 555 → capped at 150.
      final img = ImageRun(
        offset: 0,
        bytes: Uint8List(0),
        intrinsicWidth: 800,
        intrinsicHeight: 1200,
      );
      final h = img.renderedHeight(370);
      expect(h, closeTo(150.0, 1));
    });

    test('renderedHeight with maxHeight caps portrait image', () {
      // 800×1200 portrait — capped at 150px fixed, regardless of viewport.
      final img = ImageRun(
        offset: 0,
        bytes: Uint8List(0),
        intrinsicWidth: 800,
        intrinsicHeight: 1200,
      );
      final h = img.renderedHeight(370, maxHeight: 860);
      expect(h, closeTo(150.0, 1));
    });

    test('renderedSize preserves aspect ratio after capping', () {
      final img = ImageRun(
        offset: 0,
        bytes: Uint8List(0),
        intrinsicWidth: 800,
        intrinsicHeight: 1200,
      );
      final size = img.renderedSize(370, maxHeight: 860);
      final aspect = size.width / size.height;
      expect(aspect, closeTo(800 / 1200, 0.01));
    });

    test('renderedWidth matches renderedSize width', () {
      final img = ImageRun(
        offset: 0,
        bytes: Uint8List(0),
        intrinsicWidth: 800,
        intrinsicHeight: 1200,
      );
      final size = img.renderedSize(370, maxHeight: 860);
      expect(img.renderedWidth(370, maxHeight: 860), size.width);
    });

    test('landscape image still capped at 150px when tall enough', () {
      // 400×300 landscape at 370px width → natural 277.5 → capped at 150.
      final img = ImageRun(
        offset: 0,
        bytes: Uint8List(0),
        intrinsicWidth: 400,
        intrinsicHeight: 300,
      );
      final h = img.renderedHeight(370, maxHeight: 860);
      expect(h, closeTo(150.0, 1));
    });

    test('degenerate intrinsic dimensions fall back to 160 height', () {
      final img = ImageRun(
        offset: 0,
        bytes: Uint8List(0),
        intrinsicWidth: 0,
        intrinsicHeight: 0,
      );
      final size = img.renderedSize(370);
      expect(size.height, 160);
      expect(size.width, 370);
    });

    test('fullWidth image is not capped', () {
      final img = ImageRun(
        offset: 0,
        bytes: Uint8List(0),
        intrinsicWidth: 800,
        intrinsicHeight: 1200,
        fullWidth: true,
      );
      // Natural height at 370px width = 555, exceeds 150 cap but fullWidth skips it.
      final size = img.renderedSize(370);
      expect(size.height, closeTo(555.0, 1));
      expect(size.width, 370);
    });

    test('max-width:100% resolves to the content width, not 100px', () {
      final img = ImageRun(
        offset: 0,
        bytes: Uint8List(0),
        intrinsicWidth: 1200,
        intrinsicHeight: 600,
        css: const CssStyle(maxWidth: CssLength.percent(100)),
      );
      final size = img.renderedSize(370, maxHeight: 860);
      // Fits the width, then the inline cap trims it to 300x150.
      expect(size.width, closeTo(300.0, 1));
      expect(size.height, closeTo(150.0, 1));
    });

    test('max-width:100px stays absolute', () {
      final img = ImageRun(
        offset: 0,
        bytes: Uint8List(0),
        intrinsicWidth: 1200,
        intrinsicHeight: 600,
        css: const CssStyle(maxWidth: CssLength.px(100)),
      );
      final size = img.renderedSize(370, maxHeight: 860);
      expect(size.width, closeTo(100.0, 1));
      expect(size.height, closeTo(50.0, 1));
    });

    test('fullWidth image is capped to the page height, preserving aspect', () {
      final img = ImageRun(
        offset: 0,
        bytes: Uint8List(0),
        intrinsicWidth: 800,
        intrinsicHeight: 1200,
        fullWidth: true,
      );
      final size = img.renderedSize(370, maxHeight: 400);
      // Natural 370x555; page height 400 scales both axes.
      expect(size.height, closeTo(400.0, 0.5));
      expect(size.width, closeTo(370 * 400 / 555, 1));
      expect(size.width / size.height, closeTo(800 / 1200, 0.01));
    });
  });

  group('buildPageSpans with images', () {
    test('portrait image is capped and wrapped in Center', () {
      final img = ImageRun(
        offset: 2,
        bytes: Uint8List.fromList(const [1, 2, 3, 4]),
        intrinsicWidth: 800,
        intrinsicHeight: 1200,
      );

      final spans = buildPageSpans(
        text: 'AB\uFFCDC',
        start: 0,
        end: 4,
        base: style,
        theme: theme,
        settings: ReaderSettings(),
        images: [img],
        renderWidth: 370,
        maxHeight: 860,
      );

      // Find the WidgetSpan (image).
      final widgetSpan = spans.whereType<WidgetSpan>().first;
      final padded = widgetSpan.child as Padding;
      final center = padded.child as Center;
      final image = center.child as Image;

      // Image should be capped (height < natural 555).
      final natural = 1200 * 370 / 800;
      expect(image.height, lessThan(natural));
      expect(image.height, closeTo(150.0, 1));
      expect(image.width, closeTo(100.0, 1));
    });

    test('image without explicit maxHeight still gets fixed 150px cap', () {
      final img = ImageRun(
        offset: 2,
        bytes: Uint8List.fromList(const [1, 2, 3, 4]),
        intrinsicWidth: 400,
        intrinsicHeight: 300,
      );

      final spans = buildPageSpans(
        text: 'AB\uFFCDC',
        start: 0,
        end: 4,
        base: style,
        theme: theme,
        settings: ReaderSettings(),
        images: [img],
        renderWidth: 370,
      );

      final widgetSpan = spans.whereType<WidgetSpan>().first;
      final padded = widgetSpan.child as Padding;
      final center = padded.child as Center;
      final image = center.child as Image;

      // 400×300 at 370px → natural 277.5 → capped at 150, width 200.
      expect(image.height, closeTo(150.0, 1));
      expect(image.width, closeTo(200.0, 1));
    });

    testWidgets('an image with deferred bytes renders a sized placeholder', (
      tester,
    ) async {
      final img = ImageRun(
        offset: 1,
        bytes: Uint8List(0),
        intrinsicWidth: 400,
        intrinsicHeight: 300,
        sourceKey: 'OEBPS/cover.jpg',
      );

      final spans = buildPageSpans(
        text: 'A\uFFFCB',
        start: 0,
        end: 3,
        base: style,
        theme: theme,
        settings: ReaderSettings(),
        images: [img],
        renderWidth: 370,
      );

      // An empty-bytes image must not attempt to decode: no Image widget, but
      // the space is still reserved so the page layout is unchanged.
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: RichText(text: wrapSpans(spans)),
        ),
      );
      expect(find.byType(Image), findsNothing);
      expect(spans.whereType<WidgetSpan>(), isNotEmpty);
    });

    testWidgets('inline image renders at its measured placeholder width', (
      tester,
    ) async {
      // Regression: the image was wrapped in a bare Center, which expands to
      // the paragraph's full width inside a WidgetSpan. Pagination measured the
      // image at its renderedSize width (here 40px), so at render time the
      // wider span re-wrapped the line, pushed text onto extra lines, and the
      // page overflowed its budget.
      final img = ImageRun(
        offset: 1,
        bytes: Uint8List(0),
        intrinsicWidth: 40,
        intrinsicHeight: 40,
      );
      final text = 'A\uFFFCB C D E F G H I J K L M N O P Q R S T U V W X Y Z';
      final spans = buildPageSpans(
        text: text,
        start: 0,
        end: text.length,
        base: style,
        theme: theme,
        settings: ReaderSettings(),
        images: [img],
        renderWidth: 370,
        maxHeight: 860,
      );

      final size = img.renderedSize(370, maxHeight: 860);
      final tp = TextPainter(
        text: wrapSpans(spans),
        textDirection: TextDirection.ltr,
      );
      tp.setPlaceholderDimensions([
        PlaceholderDimensions(
          size: Size(size.width, size.height + 2 * ImageRun.verticalPadding),
          alignment: PlaceholderAlignment.middle,
        ),
      ]);
      tp.layout(maxWidth: 370);
      final measuredHeight = tp.height;
      tp.dispose();

      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 370,
              child: RichText(text: wrapSpans(spans)),
            ),
          ),
        ),
      );

      final imageCenter = tester.renderObject<RenderBox>(
        find
            .descendant(
              of: find.byType(RichText),
              matching: find.byType(Center),
            )
            .first,
      );
      expect(
        imageCenter.size.width,
        closeTo(size.width, 0.5),
        reason: 'image span width must match the measured placeholder width',
      );
      expect(
        tester.renderObject<RenderBox>(find.byType(RichText)).size.height,
        closeTo(measuredHeight, 0.5),
        reason: 'rendered page height must match its paginated height',
      );
    });
  });

  test('overlapping style runs tile the slice exactly once', () {
    // Regression: a run that starts inside text already emitted must be
    // clipped, not re-emitted — re-emitting duplicated the measured text and
    // ran pagination line offsets past the end of the body (the reader's
    // "laying out pages" freeze).
    const text = 'Alpha beta gamma delta.';
    final spans = buildStyledSpans(
      text,
      const [StyleRun(0, 12), StyleRun(6, 23, bold: true)],
      style,
      0,
      text.length,
    );
    expect(spans.map((span) => span.text).join(), text);
    expect(spans, hasLength(2));
    expect(spans.first.text, 'Alpha beta g');
    expect(spans.last.text, 'amma delta.');
    expect(spans.last.style?.fontWeight, FontWeight.w700);
  });

  group('highlight slices', () {
    List<InlineSpan> pages({
      List<HighlightSlice> slices = const [],
      ({int start, int end})? selectedRange,
    }) => buildPageSpans(
      text: 'word word',
      start: 0,
      end: 9,
      base: style,
      theme: theme,
      settings: ReaderSettings(),
      highlightSlices: slices,
      selectedRange: selectedRange,
    );

    test('paints a highlight background', () {
      final span = wrapSpans(
        pages(slices: const [(start: 0, end: 4, color: 0)]),
      );
      expect(span.toPlainText(), 'word word');

      final first = span.children!.first as TextSpan;
      expect(first.text, 'word');
      expect(first.style?.backgroundColor, highlightBackground(0, dark: false));
    });

    test('selection overrides a highlight', () {
      final span = wrapSpans(
        pages(
          slices: const [(start: 0, end: 4, color: 0)],
          selectedRange: (start: 0, end: 4),
        ),
      );
      final first = span.children!.first as TextSpan;
      expect(first.style?.backgroundColor, theme.selection);
    });

    test('highlight boundaries split the span', () {
      final span = wrapSpans(
        pages(slices: const [(start: 5, end: 9, color: 0)]),
      );
      final children = span.children!.cast<TextSpan>();
      expect(children.map((c) => c.text), ['word ', 'word']);
      expect(children[0].style?.backgroundColor, isNull);
      expect(children[1].style?.backgroundColor, isNotNull);
    });

    test('a slice outside the page paints nothing', () {
      final span = wrapSpans(
        pages(slices: const [(start: 50, end: 60, color: 0)]),
      );
      for (final child in span.children!.cast<TextSpan>()) {
        expect(child.style?.backgroundColor, isNull);
      }
    });
  });
}
