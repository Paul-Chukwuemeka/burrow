// Regression: full-page images must fit their page.
//
// The paginator measured full-page (fullWidth) images against the raw page
// height while the renderer adds ImageRun.verticalPadding (2x8) around each
// placeholder. An image capped to the page height therefore rendered
// `height + 16` in a box that is only `height` tall: the bottom of the image
// was silently clipped (RenderParagraph clamps its laid-out size, so nothing
// threw). Both sizing call sites now subtract the padding from the cap; this
// test pins the contract end-to-end: paginate, render every page unclamped,
// and require the rendered content to fit the page box.
import 'dart:typed_data';

import 'package:burrow/models/css_style.dart';
import 'package:burrow/models/reader_settings.dart';
import 'package:burrow/models/style_run.dart';
import 'package:burrow/services/paginator.dart';
import 'package:burrow/utils/page_spans.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const style = TextStyle(fontSize: 16, height: 1.5);
  const viewport = Size(300, 400);
  final settings = ReaderSettings();
  const theme = ReaderTheme.light;

  testWidgets('every page renders within the page box (fullWidth image)', (
    tester,
  ) async {
    final text =
        'Leading prose fills the first page. ' * 10 +
        '\n\uFFFC\n'
        'Trailing prose follows the image. ' * 10;
    final image = ImageRun(
      offset: text.indexOf('\uFFFC'),
      bytes: Uint8List(0),
      intrinsicWidth: 400,
      intrinsicHeight: 900,
      fullWidth: true,
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
      // A Stack/Positioned mirror of the reader's layout: RichText wraps at
      // the page width with no vertical clamp, so the real laid-out content
      // height is observable.
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
      if (text.substring(page.start, page.end).contains('\uFFFC')) {
        imagePageSeen = true;
        // The inline image must consume its padding within the page: if the
        // cap used the raw page height again, the content bottom lands at
        // `viewport.height + padding` instead of at most `viewport.height`.
        expect(
          contentBottom,
          lessThanOrEqualTo(viewport.height + 0.5),
          reason:
              'page $i renders ${contentBottom.toStringAsFixed(1)}px tall in '
              'a ${viewport.height}px page box — the image placeholder '
              'overflowed the page',
        );
      } else {
        // Text pages keep their existing contract: within the paginated
        // budget (page height minus slack).
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
      'css/html-sized inline images keep their size when a tap handler is '
      'attached (the page content wrapper must copy, not rebuild, ImageRun)',
      (tester) async {
    // The reader wraps every image with an image popup tap handler. The
    // wrapper used to rebuild ImageRun field-by-field and dropped css/html
    // sizing, so a css-capped image rendered full-width on its page —
    // overflowing even though the paginator had measured the capped size.
    // buildPageSpans itself is sizing-agnostic to that bug, so the contract
    // is pinned here on renderedSize inputs: a css width cap must constrain
    // the rendered size, and the tap wrapper must preserve
    // ImageRun.css/htmlWidth/htmlHeight through copyWith.
    const css = CssStyle(
      width: CssLength.px(8),
      maxWidth: CssLength.percent(100),
    );
    final sized = ImageRun(
      offset: 0,
      bytes: Uint8List(0),
      intrinsicWidth: 400,
      intrinsicHeight: 900,
      css: css,
    );
    final wrapped = sized.copyWith(onTap: () {});
    expect(wrapped.css, css);
    expect(wrapped.renderedSize(viewport.width), const Size(8, 18));

    // A plain intrinsic-sized image without HTML attributes is the only case
    // where the legacy field-by-field rebuild happened to produce the same
    // size; document the scaled-to-width shape so a future fix cannot sneak
    // back through this path either.
    final plain = ImageRun(
      offset: 0,
      bytes: Uint8List(0),
      intrinsicWidth: 100,
      intrinsicHeight: 50,
    );
    expect(
      plain.copyWith(onTap: () {}).copyWith(bytes: Uint8List(1)).css,
      isNull,
      reason: 'copyWith must be null-preserving so sizing stays intact',
    );
  });
}

/// Second page line-height slack `_slack` value mirrored from the paginator.
const double textLineSlack = 6.0;
