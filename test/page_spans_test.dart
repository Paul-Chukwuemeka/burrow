import 'dart:typed_data';

import 'package:burrow/models/css_style.dart';
import 'package:burrow/models/reader_settings.dart';
import 'package:burrow/models/style_run.dart';
import 'package:burrow/services/book_search.dart';
import 'package:burrow/utils/page_spans.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const style = TextStyle(fontSize: 18, height: 1.6);
  const theme = ReaderTheme.light;

  SearchResult match(int offset, int length) => SearchResult(
        chapter: 0,
        offset: offset,
        length: length,
        snippet: '',
      );

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
      final span = wrapSpans(buildPageSpans(
        text: text,
        start: 4,
        end: 19,
        base: style,
        theme: theme,
        settings: ReaderSettings(),
      ));

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

      final span = wrapSpans(buildPageSpans(
        text: text,
        start: 0,
        end: text.length,
        base: style,
        theme: theme,
        settings: ReaderSettings(),
        runs: runs,
        matches: matches,
      ));

      expect(span.toPlainText(), text);
      // Caller ordering is untouched by the internal sort.
      expect(runs.first.start, 10);
      expect(matches.first.offset, 16);
    });

    test('styles runs and no-run gaps without dropping text', () {
      const runs = [
        StyleRun(4, 9, bold: true),
        StyleRun(16, 19, quote: true),
      ];

      final span = wrapSpans(buildPageSpans(
        text: text,
        start: 0,
        end: 20,
        base: style,
        theme: theme,
        settings: ReaderSettings(),
        runs: runs,
      ));

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

      final span = wrapSpans(buildPageSpans(
        text: text,
        start: 0,
        end: text.length,
        base: style,
        theme: theme,
        settings: ReaderSettings(),
        matches: [current, other],
        currentMatch: current,
      ));

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
      final span = wrapSpans(buildPageSpans(
        text: text,
        start: 0,
        end: 20,
        base: style,
        theme: theme,
        settings: ReaderSettings(),
        matches: [match(4, 5)],
        currentMatch: match(35, 3),
      ));

      final hit = leaves(span).firstWhere((p) => p.$1 == 'quick').$2!;
      expect(hit.backgroundColor?.a, closeTo(0.15, 0.001));
      expect(hit.fontWeight, isNull);
    });

    test('clips matches that straddle the page boundary', () {
      // "brown fox" starts on this page and continues past its end.
      final span = wrapSpans(buildPageSpans(
        text: text,
        start: 4,
        end: 15,
        base: style,
        theme: theme,
        settings: ReaderSettings(),
        matches: [match(10, 9)],
      ));

      expect(span.toPlainText(), 'quick brown');
      final parts = leaves(span);
      expect(parts.map((p) => p.$1), ['quick ', 'brown']);
      expect(parts.last.$2?.backgroundColor, isNotNull);
    });

    test('highlight styling wins inside emphasized text', () {
      final span = wrapSpans(buildPageSpans(
        text: text,
        start: 0,
        end: 20,
        base: style,
        theme: theme,
        settings: ReaderSettings(),
        runs: const [StyleRun(4, 15, quote: true)],
        matches: [match(10, 5)],
        currentMatch: match(10, 5),
      ));

      final parts = leaves(span);
      final hit = parts.firstWhere((p) => p.$1 == 'brown').$2!;
      expect(hit.fontStyle, FontStyle.italic, reason: 'run styling survives');
      expect(hit.color, theme.accent, reason: 'highlight color overrides quote');
      expect(hit.backgroundColor, isNotNull);
    });

    test('ignores runs and matches outside the page', () {
      final span = wrapSpans(buildPageSpans(
        text: text,
        start: 0,
        end: 10,
        base: style,
        theme: theme,
        settings: ReaderSettings(),
        runs: const [StyleRun(20, 25, bold: true)],
        matches: [match(30, 4)],
      ));

      expect(span.toPlainText(), text.substring(0, 10));
      expect(leaves(span).every((p) => p.$2?.fontWeight == null), isTrue);
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
        bytes: Uint8List(0),
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
        bytes: Uint8List(0),
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
  });
}
