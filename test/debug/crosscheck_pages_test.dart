// Crosscheck: does what pagination COUNTED per page (its measured line
// heights, now exposed by ChapterPaginationDriver.debugPageLineHeights) match
// what the page actually renders (buildPageSpans + RichText, unclamped)?
//
// Runs the real Rust engine on the image-bearing fixtures, paginates at the
// reader's default-text geometry for several viewports, renders every page
// offscreen at unclamped height, and prints both numbers per page. Any
// mismatch reveals WHERE the render gets taller than the count.
import 'dart:io';
import 'dart:typed_data';

import 'package:burrow/models/reader_settings.dart';
import 'package:burrow/services/epub/rust_epub_engine.dart';
import 'package:burrow/services/paginator.dart';
import 'package:burrow/src/rust/frb_generated.dart';
import 'package:burrow/utils/page_spans.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final enabled = Platform.environment['BURROW_CROSSCHECK'] == '1';
  if (!enabled) {
    test('crosscheck (disabled)', () {
      // ignore: avoid_print
      print('Skipped: set BURROW_CROSSCHECK=1 to run.');
    });
    return;
  }

  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  const books = [
    'test/fixtures/epub/projection.epub',
    'test/fixtures/epub/tall-image.epub',
    'test/fixtures/epub/cover-inline.epub',
  ];
  const viewports = [Size(875, 356), Size(372, 859)];

  for (final path in books) {
    for (final viewport in viewports) {
      testWidgets('${path.split('/').last} @ ${viewport.width}x${viewport.height}', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        // The engine parses on its own isolate timings; keep it off the
        // fake-async zone.
        // ignore: avoid_print
        print('CROSSCHECK parsing ${path.split('/').last}…');
        final doc =
            (await tester.runAsync(() => const RustEpubEngine().parse(path)))!;
        // ignore: avoid_print
        print(
          'CROSSCHECK parsed chapters=${doc.chapters.length} '
          'firstImages=${doc.chapters.first.images.map((i) => (w: i.intrinsicWidth, h: i.intrinsicHeight, fw: i.fullWidth, off: i.offset, htmlW: i.htmlWidth, htmlH: i.htmlHeight, maxW: i.css?.maxWidth?.toJson(), width: i.css?.width?.toJson(), height: i.css?.height?.toJson()))}',
        );

        final settings = ReaderSettings();
        final style = TextStyle(
          fontSize: settings.fontSize,
          height: settings.lineHeight,
          color: ReaderTheme.light.text,
          fontFamily: settings.fontFamily,
        );
        final margin = settings.horizontalMargin;

        // First chapter is enough for these fixtures.
        final chapter = doc.chapters.first;
        {
          final driver = ChapterPaginationDriver(
            text: chapter.body,
            style: style,
            maxWidth: viewport.width - margin * 2,
            maxHeight: viewport.height - 56,
            direction: TextDirection.ltr,
            // _titleInset mirror not needed for this probe: crosscheck
            // compares counted/rendered sizes, not page fits.
            firstPageInset: 0,
            textScaler: TextScaler.noScaling,
            runs: chapter.runs,
            images: chapter.images,
            settings: settings,
            theme: ReaderTheme.light,
          );
          while (!driver.isDone) {
            driver.nextChunk(64);
          }
          driver.dispose();

          for (var i = 0; i < driver.pages.length; i++) {
            final page = driver.pages[i];
            final counted = driver.debugPageLineHeights[i].isEmpty
                ? 0.0
                : driver.debugPageLineHeights[i]
                      .reduce((a, b) => a + b);
            final spans = buildPageSpans(
              text: chapter.body,
              start: page.start,
              end: page.end,
              base: style,
              theme: ReaderTheme.light,
              settings: settings,
              runs: chapter.runs,
              images: chapter.images.map((img) {
                final bytes = img.bytes.isEmpty
                    ? Uint8List(0)
                    : img.bytes;
                return img.copyWith(bytes: bytes);
              }).toList(),
              renderWidth: viewport.width - margin * 2,
              maxHeight: viewport.height - 56,
              devicePixelRatio: 1.0,
            );
            await tester.pumpWidget(
              Directionality(
                textDirection: TextDirection.ltr,
                child: SizedBox(
                  width: viewport.width - margin * 2,
                  height: viewport.height,
                  child: Stack(
                    clipBehavior: Clip.none,
                    alignment: Alignment.topLeft,
                    children: [
                      Positioned(
                        top: 0,
                        left: 0,
                        width: viewport.width - margin * 2,
                        child: RichText(
                          text: TextSpan(style: style, children: spans),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
            final buildException = tester.takeException();
            if (buildException != null) {
              // ignore: avoid_print
              print('CROSSCHECK EXCEPTION page $i: $buildException');
              continue;
            }
            final ro = tester.renderObject<RenderParagraph>(
              find.byType(RichText),
            );
            var contentBottom = ro.size.height;
            if (ro.text.toPlainText().contains('\uFFFC')) {
              final plain = ro.text.toPlainText();
              for (final box in ro.getBoxesForSelection(TextSelection(
                baseOffset: 0,
                extentOffset: plain.length,
              ))) {
                final mid = Offset(
                  (box.left + box.right) / 2,
                  (box.top + box.bottom) / 2,
                );
                final pos = ro.getPositionForOffset(mid).offset;
                // ignore: avoid_print
                print(
                  '  box top=${box.top.toStringAsFixed(1)} bottom='
                  '${box.bottom.toStringAsFixed(1)} at=$pos '
                  '"${plain.substring(pos.clamp(0, plain.length), (pos + 10).clamp(0, plain.length)).replaceAll('\n', '␤')}"',
                );
              }
            }
            final gap = contentBottom - counted;
            final gapMark = gap > 0.5 ? ' <<<  GAPS' : '';
            // ignore: avoid_print
            print(
              'CROSSCHECK [${page.start},${page.end}) counted='
              '${counted.toStringAsFixed(1)} rendered='
              '${contentBottom.toStringAsFixed(1)} gap='
              '${gap.toStringAsFixed(1)}$gapMark '
              'roSize=${ro.size.width}x${ro.size.height}',
            );
            if (i > 5) break; // a couple of pages suffice
          }
          // ignore: avoid_print
          print('CROSSCHECK --- ${path.split('/').last} chapter done');
        }
      });
    }
  }
}
