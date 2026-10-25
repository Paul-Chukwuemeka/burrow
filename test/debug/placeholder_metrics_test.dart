// Minimal experiment: how does TextPainter count the line height of a
// middle-aligned inline placeholder, versus what RenderParagraph actually
// lays out? This is the suspected pagination/render mismatch behind image
// pages overflowing or clipping.
import 'dart:typed_data';

import 'package:burrow/models/reader_settings.dart';
import 'package:burrow/models/style_run.dart';
import 'package:burrow/services/paginator.dart';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const style = TextStyle(fontSize: 16, height: 1.5);
  const viewport = Size(300, 400);

  Future<void> pumpBody(
    WidgetTester tester,
    Widget child,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: child),
      ),
    );
  }

  testWidgets('placeholder line height: metrics vs render', (tester) async {
    // 1) A lone middle-aligned placeholder paragraph, measured by TextPainter
    //    exactly the way the paginator does.
    final tp = TextPainter(textDirection: TextDirection.ltr);
    tp.text = const TextSpan(
      style: style,
      children: [
        WidgetSpan(
          child: SizedBox.shrink(),
          alignment: PlaceholderAlignment.middle,
        ),
      ],
    );
    tp.setPlaceholderDimensions([
      const PlaceholderDimensions(
        size: Size(80, 166),
        alignment: PlaceholderAlignment.middle,
      ),
    ]);
    tp.layout(maxWidth: viewport.width);
    final metrics = tp.computeLineMetrics();
    // ignore: avoid_print
    print(
      'MEASURE lone-placeholder metric heights = '
      '${metrics.map((m) => m.height).toList()} tpHeight=${tp.height}',
    );
    tp.dispose();

    // 2) The same paragraph as the render tree lays it out: RichText with a
    //    real 80x150 widget inside vertical padding 8.
    await pumpBody(
      tester,
      SizedBox(
        width: 300,
        height: 400,
        child: RichText(
          text: TextSpan(
            style: style,
            children: [
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: const SizedBox(width: 80, height: 150),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final ro = tester.renderObject<RenderParagraph>(find.byType(RichText));
    final boxes = ro.getBoxesForSelection(
      const TextSelection(baseOffset: 1, extentOffset: 2),
    );
    // ignore: avoid_print
    print(
      'RENDER lone-placeholder size=${ro.size} '
      'contentBottom=${boxes.isEmpty ? ro.size.height : boxes.last.bottom}',
    );

    // 3) Same check with one text line above the placeholder (fresh painter;
    //    TextPainter is one-shot after layout in tests).
    final tp2 = TextPainter(textDirection: TextDirection.ltr);
    tp2
      ..text = const TextSpan(
        style: style,
        children: [
          TextSpan(text: 'one line of text\n'),
          WidgetSpan(
            child: SizedBox.shrink(),
            alignment: PlaceholderAlignment.middle,
          ),
        ],
      )
      ..setPlaceholderDimensions([
        const PlaceholderDimensions(
          size: Size(80, 166),
          alignment: PlaceholderAlignment.middle,
        ),
      ])
      ..layout(maxWidth: viewport.width);
    final metrics2 = tp2.computeLineMetrics();
    // ignore: avoid_print
    print(
      'MEASURE text+placeholder line heights = '
      '${metrics2.map((m) => m.height).toList()} tpHeight=${tp2.height}',
    );
    tp2.dispose();
    await pumpBody(
      tester,
      SizedBox(
        width: 300,
        height: 400,
        child: RichText(
          text: TextSpan(
            style: style,
            children: [
              TextSpan(text: 'one line of text\n'),
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: const SizedBox(width: 80, height: 150),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final ro2 = tester.renderObject<RenderParagraph>(find.byType(RichText));
    final plain = ro2.text.toPlainText();
    final boxes2 = ro2.getBoxesForSelection(
      TextSelection(baseOffset: 0, extentOffset: plain.length),
    );
    // ignore: avoid_print
    print(
      'RENDER text+placeholder size=${ro2.size} '
      'contentBottom=${boxes2.isEmpty ? ro2.size.height : boxes2.last.bottom}',
    );

    // 4) Full picture through the paginator: text lines then image paragraph.
    final text = '${List.generate(12, (i) => 'line $i').join('\n')}\n\uFFFC';
    final driver = ChapterPaginationDriver(
      text: text,
      style: style,
      maxWidth: viewport.width,
      maxHeight: viewport.height,
      direction: TextDirection.ltr,
      images: [
        ImageRun(
          offset: text.length - 1,
          bytes: Uint8List(0),
          intrinsicWidth: 120,
          intrinsicHeight: 90,
        ),
      ],
      settings: ReaderSettings(),
      theme: ReaderTheme.light,
    );
    while (!driver.isDone) {
      driver.nextChunk(4);
    }
    // ignore: avoid_print
    print('PAGINATOR pages: ${driver.pages.map((p) => '[${p.start},${p.end}) sz=${p.end - p.start}').join(' ')}');
    driver.dispose();
  });
}
