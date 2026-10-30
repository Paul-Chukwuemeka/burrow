import 'package:burrow/models/css_style.dart';
import 'package:burrow/models/reader_settings.dart';
import 'package:burrow/models/style_run.dart';
import 'package:burrow/services/paginator.dart';
import 'package:burrow/utils/page_spans.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A paragraph break (`\n\n`) renders an empty line whose height comes from the
/// style run covering the newlines — typically the book's CSS (`line-height:
/// 1.2` over a 16px font), not the reader's settings base style. The paginator
/// used to synthesise those blank lines from the settings base only (18px at
/// 1.6 ≈ 29px) while they render at the run style (≈19px), so every paragraph
/// on a page reserved ~10px of space the renderer never drew and pages ended
/// visibly short of the bottom margin.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Settings base: 18px at line-height 1.6 (reader defaults).
  const base = TextStyle(fontSize: 18, height: 1.6);
  const viewport = Size(320, 420);
  // Typical calibre body CSS: 16px at line-height 1.2.
  const css = CssStyle(fontSize: 16, lineHeight: 1.2);

  ({String text, List<StyleRun> runs}) chapter({int paragraphs = 8}) {
    final buf = StringBuffer();
    final runs = <StyleRun>[];
    for (var i = 0; i < paragraphs; i++) {
      if (i > 0) {
        final br = buf.length;
        buf.write('\n\n');
        // The parser emits a run over the break characters too.
        runs.add(StyleRun(br, br + 2, css: css));
      }
      final start = buf.length;
      buf.write(
        'Paragraph $i has enough words in it to wrap onto a second line of '
        'this narrow column, which is exactly what we want here.',
      );
      runs.add(StyleRun(start, buf.length, css: css));
    }
    return (text: buf.toString(), runs: runs);
  }

  Paginator paginate(String text, List<StyleRun> runs) => Paginator.paginate(
    text: text,
    style: base,
    maxWidth: viewport.width,
    maxHeight: viewport.height,
    direction: TextDirection.ltr,
    runs: runs,
    settings: ReaderSettings(),
    theme: ReaderTheme.light,
  );

  /// Height the page renders at, measured the way `_PageContent` lays it out:
  /// a RichText with the settings base style wrapping `buildPageSpans`.
  double renderedHeight(
    String text,
    List<StyleRun> runs,
    TextPage page,
  ) {
    final tp = TextPainter(
      text: TextSpan(
        style: base,
        children: buildPageSpans(
          text: text,
          start: page.start,
          end: page.end,
          base: base,
          theme: ReaderTheme.light,
          settings: ReaderSettings(),
          runs: runs,
          renderWidth: viewport.width,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: viewport.width);
    final height = tp.height;
    tp.dispose();
    return height;
  }

  test('paragraph-break lines take the break run style, not the base style',
      () {
    final c = chapter();
    final p = paginate(c.text, c.runs);

    final blankHeights = <double>[];
    for (final page in p.pageLineHeights) {
      for (final h in page) {
        // Base style line (18 × 1.6) reports ~29; the CSS run reports ~19.
        if (h > 24) blankHeights.add(h);
      }
    }
    expect(
      blankHeights,
      isEmpty,
      reason:
          'no measured line should use the settings base height when the '
          'break characters carry a CSS run: $blankHeights',
    );
  });

  test('page height sums match what the page renders', () {
    final c = chapter(paragraphs: 12);
    final p = paginate(c.text, c.runs);
    expect(p.pages.length, greaterThan(2));

    for (var i = 0; i < p.pages.length; i++) {
      final measured = p.pageLineHeights[i].fold(0.0, (a, b) => a + b);
      final rendered = renderedHeight(c.text, c.runs, p.pages[i]);
      // Measured line heights are whole pixels (TextPainter rounds), so a page
      // may under-count by a fraction per line, but it must never reserve
      // more than a line of extra space the renderer does not use.
      final shortfall = rendered - measured;
      expect(
        shortfall,
        greaterThanOrEqualTo(-1.0),
        reason: 'page $i measured $measured but renders $rendered',
      );
      expect(
        shortfall,
        lessThanOrEqualTo(p.pageLineHeights[i].length * 0.5 + 1.0),
        reason:
            'page $i reserves ${shortfall.toStringAsFixed(1)}px more than it '
            'renders (measured $measured, rendered $rendered)',
      );
    }
  });
}
