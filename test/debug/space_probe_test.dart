// DIAGNOSTIC PROBE — not a unit test.
//
// Symptom: a mid-paragraph page break leaves a visibly larger-than-one-line
// gap at the bottom of a text page ("The Razor and the Hook has tasked us
// with …", chapter010 of The Final Architecture). A mid-paragraph break can
// only happen when the next measured line does not fit the remaining budget,
// so the gap should be smaller than one line height — this probe prints the
// measured line heights, the remaining space, and what follows the break.
//
// Run:
//   BURROW_SPACE_PROBE=1 flutter test test/debug/space_probe_test.dart
// Optional: BURROW_SPACE_PROBE_BOOKS=/path/to/book.epub
import 'dart:io';

import 'package:burrow/models/document.dart';
import 'package:burrow/models/reader_settings.dart';
import 'package:burrow/services/epub/epub_engine_factory.dart';
import 'package:burrow/services/paginator.dart';
import 'package:burrow/src/rust/frb_generated.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  if (Platform.environment['BURROW_SPACE_PROBE'] != '1') {
    test('space probe (disabled)', () {
      // ignore: avoid_print
      print('Skipped: set BURROW_SPACE_PROBE=1 to run.');
    });
    return;
  }

  TestWidgetsFlutterBinding.ensureInitialized();

  final bookPath = Platform.environment['BURROW_SPACE_PROBE_BOOKS'] ??
      '/home/paul/Downloads/_OceanofPDF.com_The_Final_Architecture_series_-_Adrian_Tchaikovsky.epub';
  const needle = 'tasked us with';

  testWidgets('space probe: find the mid-paragraph break', (tester) async {
    await RustLib.init();
    final engine = createEpubEngine('rust');
    final doc = (await tester.runAsync(() => engine.parse(bookPath)) ??
        (throw StateError('parse failed')));

    Chapter? chapter;
    for (final ch in doc.chapters) {
      if (ch.body.contains(needle)) {
        chapter = ch;
        break;
      }
    }
    // ignore: avoid_print
    print(
      'PROBE chapters=${doc.chapters.length} '
      'found=${chapter != null} '
      'offset=${chapter?.body.indexOf(needle)}',
    );
    expect(chapter, isNotNull, reason: 'needle chapter must parse');

    final needleChapter = chapter!;
    // Dump the runs the parser actually emitted around the needle paragraph,
    // so the measured-vs-rendered style analysis works on parsed data.
    final needleOffset = needleChapter.body.indexOf(needle);
    // ignore: avoid_print
    print(
      'PROBE runs=${needleChapter.runs.length} '
      'images=${needleChapter.images.length}',
    );
    for (final r in needleChapter.runs) {
      if (r.end >= needleOffset - 400 && r.start <= needleOffset + 400) {
        final css = r.css;
        final cssText = css == null
            ? 'null'
            : 'fontSize=${css.fontSize} lineHeight=${css.lineHeight} '
                  'fontFamily=${css.fontFamily}';
        // ignore: avoid_print
        print(
          'PROBE run [${r.start},${r.end}) bold=${r.bold} '
          'italic=${r.italic} css=$cssText',
        );
      }
    }
    final settings = ReaderSettings();
    const theme = ReaderTheme.light;
    // Exact reader geometry: _contentViewport = screen − 2×horizontalMargin
    // wide, screen − 56 tall (lib/screens/reader_screen.dart:721). The
    // emulator runs 1080x2400 @ dpr 2.625 → 411.43x914.29 logical.
    const viewport = Size(411.43, 914.29);
    final style = TextStyle(
      fontSize: settings.fontSize,
      height: settings.lineHeight,
      color: theme.text,
    );
    final pageWidth = viewport.width - settings.horizontalMargin * 2;
    final pageHeight = viewport.height - 56;

    final paginator = Paginator.paginate(
      text: needleChapter.body,
      style: style,
      maxWidth: pageWidth,
      maxHeight: pageHeight,
      direction: TextDirection.ltr,
      runs: needleChapter.runs,
      images: needleChapter.images,
      settings: settings,
      theme: theme,
    );

    final pageIndex = paginator.pages.indexWhere(
      (page) => needleChapter.body
          .substring(page.start, page.end)
          .contains(needle),
    );
    expect(pageIndex, isNonNegative, reason: 'needle page must exist');

    final page = paginator.pages[pageIndex];
    final lines = paginator.pageLineHeights[pageIndex];
    // ignore: avoid_print
    print(
      'PROBE page=$pageIndex lines=${lines.length} '
      'sum=${lines.fold(0.0, (a, b) => a + b)} '
      'pageEnd=${page.end}',
    );
    for (var i = 0; i < lines.length; i++) {
      // ignore: avoid_print
      print('PROBE line[$i]=${lines[i].toStringAsFixed(2)}');
    }
    // The text that follows the break: the paginator tiles text with small
    // gaps at boundaries, so look ahead in the chapter body directly.
    final afterBreak = needleChapter.body.substring(
      page.end,
      (page.end + 220).clamp(0, needleChapter.body.length),
    );
    // ignore: avoid_print
    print('PROBE afterBreak=\n$afterBreak');
    // What the page itself ends with.
    final tail = needleChapter.body.substring(
      (page.end - 120).clamp(0, page.end),
      page.end,
    );
    // ignore: avoid_print
    print('PROBE pageTail=\n$tail');
  });
}
