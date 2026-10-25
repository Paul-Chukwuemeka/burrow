// Block-image centering contract.
//
// A `\uFFFC` marker alone on its line (only newlines / horizontal whitespace
// on either side) now renders as a full-column placeholder cell with the
// image centered inside. The line's height is unchanged and the line holds
// nothing else, so wrapping — and therefore pagination — must be identical
// to the previous shrink-wrapped behavior. Inline markers (text sharing the
// marker's line, or several markers side by side) stay shrink-wrapped:
// widening one of those would change wrapping and shift page heights.
//
// The two sizing call sites — Paginator's `_placeholdersIn` (measurement)
// and `buildPageSpans` (rendering) — must agree exactly; the end-to-end fit
// test here plus the unchanged suite pins that parity.
import 'dart:typed_data';

import 'package:burrow/models/css_style.dart';
import 'package:burrow/models/reader_settings.dart';
import 'package:burrow/models/style_run.dart';
import 'package:burrow/services/paginator.dart';
import 'package:burrow/utils/page_spans.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// Prints a [WidgetSpan] child's widget chain as
/// `Padding/SizedBox(w=300)/Center/...` so a test can pin the *shape* (the
/// node that provides the placeholder's box) without depending on widget
/// identity beyond the layout types that carry the contract.
String widgetShape(Widget? node, [String prefix = '', int depth = 0]) {
  if (node == null || depth > 8) return prefix;
  final description = switch (node) {
    SizedBox(width: final w) => 'SizedBox(w=$w)',
    Center(widthFactor: final f) => 'Center(widthFactor=$f)',
    Padding() => 'Padding',
    GestureDetector() => 'GestureDetector',
    _ => node.runtimeType.toString(),
  };
  final innerChild = switch (node) {
    SizedBox(:final child) => child,
    Center(:final child) => child,
    Padding(:final child) => child,
    GestureDetector(:final child) => child,
    _ => null,
  };
  return widgetShape(
    innerChild,
    prefix.isEmpty ? description : '$prefix/$description',
    depth + 1,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const style = TextStyle(fontSize: 16, height: 1.5);
  const viewport = Size(300, 400);
  final settings = ReaderSettings();
  const theme = ReaderTheme.light;
  const marker = '\uFFFC';

  group('standaloneIn (marker-cell predicate)', () {
    test('a marker alone on its line is standalone', () {
      expect(ImageRun.standaloneIn('$marker\nprose', 0), isTrue);
      expect(ImageRun.standaloneIn('prose\n$marker\nmore', 6), isTrue);
      expect(ImageRun.standaloneIn('prose\n$marker', 6), isTrue);
      expect(ImageRun.standaloneIn(marker, 0), isTrue);
    });

    test('horizontal whitespace around the marker stays standalone', () {
      expect(ImageRun.standaloneIn('pos\n  $marker \t\nmore', 6), isTrue);
      expect(ImageRun.standaloneIn('\r $marker \r\n', 2), isTrue);
    });

    test('text sharing the line makes it inline', () {
      expect(ImageRun.standaloneIn('word $marker\n', 5), isFalse);
      expect(ImageRun.standaloneIn('$marker tail', 0), isFalse);
    });

    test('another marker on the line keeps every marker inline', () {
      // Widening one of several markers sharing a line would force extra
      // wrapping and change page heights, so the pair must stay inline.
      expect(ImageRun.standaloneIn('$marker$marker', 0), isFalse);
      expect(ImageRun.standaloneIn('$marker$marker', 1), isFalse);
      expect(ImageRun.standaloneIn('$marker $marker', 0), isFalse);
      // Blank lines do not break standalone-ness: the nearest significant
      // char on each side being a newline is what matters.
      expect(ImageRun.standaloneIn('$marker\n\nprose', 0), isTrue);
    });
  });

  test('standalone spans center in a full-column cell; inline spans shrink-wrap', () {
    final prose = 'Filling the line before the image. ' * 6;
    // Images must carry an explicit CSS width: without one the design scales
    // them to the full column (making centering a no-op), so the narrow
    // shape this contract is about only exists for CSS-sized images.
    const narrowCss = CssStyle(width: CssLength.px(100));
    final blockText = '$prose\n$marker\n$prose';
    final standalone = ImageRun(
      offset: blockText.indexOf(marker),
      bytes: Uint8List(0),
      intrinsicWidth: 100,
      intrinsicHeight: 50,
      css: narrowCss,
    );
    final spans = buildPageSpans(
      text: blockText,
      start: standalone.offset,
      end: standalone.offset + 1,
      base: style,
      theme: theme,
      settings: settings,
      images: [standalone],
      renderWidth: viewport.width,
      maxHeight: viewport.height,
    );
    final spanShape = spans
        .whereType<WidgetSpan>()
        .map((s) => widgetShape(s.child))
        .join(' ; ');
    expect(
      spanShape,
      contains('SizedBox(w=${viewport.width})'),
      reason:
          'standalone marker must occupy the full measured column '
          '($spanShape)',
    );
    expect(
      spanShape,
      contains('Center(widthFactor=null)'),
      reason: 'the image must center inside the full-column cell ($spanShape)',
    );

    // The inline case keeps the shrink-wrapped predecessor shape.
    final inlineText = '$prose$marker tail. $prose';
    final inline = ImageRun(
      offset: inlineText.indexOf(marker),
      bytes: Uint8List(0),
      intrinsicWidth: 100,
      intrinsicHeight: 50,
      css: narrowCss,
    );
    final inlineSpans = buildPageSpans(
      text: inlineText,
      start: inline.offset,
      end: inline.offset + 1,
      base: style,
      theme: theme,
      settings: settings,
      images: [inline],
      renderWidth: viewport.width,
      maxHeight: viewport.height,
    );
    final inlineShape = inlineSpans
        .whereType<WidgetSpan>()
        .map((s) => widgetShape(s.child))
        .join(' ; ');
    expect(
      inlineShape,
      contains('Center(widthFactor=1.0)'),
      reason: 'inline marker must shrink-wrap to the image ($inlineShape)',
    );
    expect(
      inlineShape,
      isNot(contains('w=${viewport.width}')),
      reason: 'inline marker must not widen the cell',
    );
  });

  testWidgets('a narrow standalone image still fits its page (centered)', (
    tester,
  ) async {
    // Not fullWidth: the 150px inline cap shrinks 300x600 → 150x75, then the
    // box adds 2x8 padding. The centered full-column cell must remain within
    // the page exactly like the old shrink-wrapped box did.
    final text =
        'Leading prose fills the first page. ' * 10 +
        '\n$marker\n'
        'Trailing prose follows the image. ' * 10;
    final image = ImageRun(
      offset: text.indexOf(marker),
      bytes: Uint8List(0),
      intrinsicWidth: 300,
      intrinsicHeight: 600,
    );

    final paginator = Paginator.paginate(
      text: text,
      style: style,
      maxWidth: viewport.width,
      maxHeight: viewport.height,
      direction: TextDirection.ltr,
      runs: const [],
      images: [image],
      settings: settings,
      theme: theme,
    );

    var imagePageSeen = false;
    for (var i = 0; i < paginator.pages.length; i++) {
      final page = paginator.pages[i];
      final spans = buildPageSpans(
        text: text,
        start: page.start,
        end: page.end,
        base: style,
        theme: theme,
        settings: settings,
        images: [image],
        renderWidth: viewport.width,
        maxHeight: viewport.height,
      );
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox.fromSize(
            size: viewport,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.topLeft,
              children: [
                Positioned(
                  top: 0,
                  left: 0,
                  width: viewport.width,
                  child: RichText(
                    text: TextSpan(style: style, children: spans),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      expect(
        tester.takeException(),
        isNull,
        reason: 'page $i must lay out without exceptions',
      );
      final ro = tester.renderObject<RenderParagraph>(find.byType(RichText));
      var contentBottom = ro.size.height;
      for (final box in ro.getBoxesForSelection(
        TextSelection(
          baseOffset: 0,
          extentOffset: ro.text.toPlainText().length,
        ),
      )) {
        if (box.bottom > contentBottom) contentBottom = box.bottom;
      }
      if (text.substring(page.start, page.end).contains(marker)) {
        imagePageSeen = true;
        expect(
          contentBottom,
          lessThanOrEqualTo(viewport.height + 0.5),
          reason:
              'page $i renders ${contentBottom.toStringAsFixed(1)}px tall in '
              'a ${viewport.height}px page box — the centered image cell '
              'overflowed the page',
        );
      } else {
        expect(
          contentBottom,
          lessThanOrEqualTo(viewport.height - textLineSlack + 0.5),
          reason: 'text page $i overflows its measured budget',
        );
      }
    }
    expect(imagePageSeen, isTrue, reason: 'the image must land on a page');
  });

  testWidgets(
      'side-by-side figures still measure and render as a single line', (
    tester,
  ) async {
    // Guard against the widening regression: if a shared-line figure
    // paragraph got full-column cells, its two placeholders would wrap into
    // two lines and silently shift pagination.
    final text = '$marker $marker\nTrailing prose after the figures. ';
    final images = [0, 2]
        .map(
          (offset) => ImageRun(
            offset: offset,
            bytes: Uint8List(0),
            intrinsicWidth: 100,
            intrinsicHeight: 50,
            css: const CssStyle(width: CssLength.px(100)),
          ),
        )
        .toList();

    final paginator = Paginator.paginate(
      text: text,
      style: style,
      maxWidth: viewport.width,
      maxHeight: viewport.height,
      direction: TextDirection.ltr,
      runs: const [],
      images: images,
      settings: settings,
      theme: theme,
    );

    // Measured: the figure paragraph is a single line (50px image + 16px
    // padding = 66px tall) plus whatever trailing prose fits after it.
    var measuredFigurePage = -1;
    var figureLines = 0;
    for (var i = 0; i < paginator.pageLineHeights.length; i++) {
      final heights = paginator.pageLineHeights[i];
      final onLine = heights.where((h) => (h - 66).abs() < 0.5);
      if (onLine.isEmpty) continue;
      measuredFigurePage = i;
      figureLines = onLine.length;
      break;
    }
    expect(measuredFigurePage, isNonNegative);
    expect(
      figureLines,
      1,
      reason:
          'the two markers share one line; widening either marker would '
          'have wrapped them into two 66px lines',
    );

    // Rendered: the identical spans produce exactly as many lines as were
    // measured, unclamped.
    final page = paginator.pages[measuredFigurePage];
    final spans = buildPageSpans(
      text: text,
      start: page.start,
      end: page.end,
      base: style,
      theme: theme,
      settings: settings,
      images: images,
      renderWidth: viewport.width,
      maxHeight: viewport.height,
    );
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox.fromSize(
          size: viewport,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.topLeft,
            children: [
              Positioned(
                top: 0,
                left: 0,
                width: viewport.width,
                child: RichText(text: TextSpan(style: style, children: spans)),
              ),
            ],
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    final ro = tester.renderObject<RenderParagraph>(find.byType(RichText));
    // The rendered, unclamped content bottom must match the paginator's
    // measured line-height sum (small baseline artifact tolerated, as
    // documented in the overflow probe). Under the widening regression the
    // two figures wrap into an extra ~66px line and this overshoots.
    final measured = paginator.pageLineHeights[measuredFigurePage]
        .reduce((a, b) => a + b);
    final contentBottom = ro.getBoxesForSelection(
      TextSelection(
        baseOffset: 0,
        extentOffset: ro.text.toPlainText().length,
      ),
    ).fold<double>(0, (max, box) => box.bottom > max ? box.bottom : max);
    expect(
      contentBottom,
      inInclusiveRange(measured - 2, measured + 10),
      reason:
          'rendered height ${contentBottom.toStringAsFixed(1)} must match '
          'the measured ${measured.toStringAsFixed(1)}',
    );
  });
}

/// Second page line-height slack `_slack` value mirrored from the paginator.
const double textLineSlack = 6.0;
