// DIAGNOSTIC PROBE — not a unit test.
//
// Companion to reader_layout_probe_test.dart. Where that one measures the
// real reader's frames, this one inspects what the engine hands the paginator
// and times the paginator itself, per chapter:
//
//   1. Parse shape: body length, newline/paragraph structure, style-run and
//      inline-image counts, and sanity of image offsets (every ImageRun.offset
//      must land on a \uFFFC placeholder inside the body).
//   2. Driver timing: for the heavyweight chapters, run the real
//      ChapterPaginationDriver exactly like the reader does
//      (nextChunkUntil(minPages: 1, budget: 8ms) in a loop) and report the
//      worst single synchronous call, total pass time, pages and run visits.
//      A single call blocking for seconds is the "freeze" in measurable form.
//
// Run:
//   BURROW_SHAPE_PROBE=1 flutter test test/debug/parse_shape_probe_test.dart
//   BURROW_SHAPE_BOOKS=/a.epub:/b.epub   (default: the Quinn suspects + /home/paul/output)
//   BURROW_SHAPE_TOPN=3                  (chapters to time, by body length)
//
// Skipped unless BURROW_SHAPE_PROBE=1 so the normal suite is unaffected.
import 'dart:io';

import 'package:burrow/models/document.dart';
import 'package:burrow/services/epub/epub_engine.dart';
import 'package:burrow/services/epub/epub_engine_factory.dart';
import 'package:burrow/services/paginator.dart';
import 'package:burrow/src/rust/frb_generated.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _fffc = '\uFFFC';

class _ChapterShape {
  _ChapterShape(this.index, this.chapter);
  final int index;
  final Chapter chapter;

  String get body => chapter.body;
  int get runs => chapter.runs.length;
  int get images => chapter.images.length;
  String get title => chapter.title;

  int get newlines => '\n'.allMatches(body).length;
  int get fffc => _fffc.allMatches(body).length;

  int get longestSegment {
    var worst = 0;
    var start = 0;
    while (start <= body.length) {
      final nl = body.indexOf('\n', start);
      final end = nl == -1 ? body.length : nl;
      if (end - start > worst) worst = end - start;
      if (nl == -1) break;
      start = nl + 1;
    }
    return worst;
  }

  /// Number of ImageRun offsets that do NOT land on a \uFFFC placeholder.
  int get badImageOffsets {
    var bad = 0;
    for (final img in chapter.images) {
      if (img.offset < 0 ||
          img.offset >= body.length ||
          body.codeUnitAt(img.offset) != 0xFFFC) {
        bad++;
      }
    }
    return bad;
  }

  /// Style runs not sorted, out of bounds, or inverted.
  int get badRuns {
    var bad = 0;
    var prevEnd = 0;
    for (final r in chapter.runs) {
      if (r.start < prevEnd || r.end > body.length || r.end <= r.start) bad++;
      prevEnd = r.end;
    }
    return bad;
  }
}

void main() {
  final enabled = Platform.environment['BURROW_SHAPE_PROBE'] == '1';
  final listed = Platform.environment['BURROW_SHAPE_BOOKS'];
  final topN = int.tryParse(Platform.environment['BURROW_SHAPE_TOPN'] ?? '') ?? 3;

  final books = listed != null
      ? listed.split(':').where((p) => p.isNotEmpty).toList()
      : <String>[
          '/home/paul/Downloads/3_the-sum-of-all-kisses-by-julia-quinn.epub',
          '/home/paul/Downloads/When_He_Was_Wicked_-_Julia_Quinn.epub',
          ...Directory('/home/paul/output')
              .listSync()
              .whereType<File>()
              .map((f) => f.path)
              .where((p) => p.toLowerCase().endsWith('.epub')),
        ];

  if (!enabled) {
    test('parse shape probe (disabled)', () {
      // ignore: avoid_print
      print('Skipped: set BURROW_SHAPE_PROBE=1 to run.');
    });
    return;
  }

  test('parse shape + driver timing', () async {
    await RustLib.init();
    final engine = createEpubEngine(rustEpubEngineId);

    // The reader's style is font-dependent; this is the scaffold-equivalent
    // proxy (same size/leading order of magnitude). Driver cost structure
    // (paragraph count, run density, image placement) is what this probes.
    const style = TextStyle(fontSize: 18, height: 1.5);
    const maxWidth = 380.0;
    const maxHeight = 800.0;

    for (final path in books) {
      final name = path.split('/').last;
      final sw = Stopwatch()..start();
      ParsedDocument doc;
      try {
        doc = await engine.parse(path);
      } catch (e) {
        // ignore: avoid_print
        print('BOOK $name PARSE-FAILED: $e');
        continue;
      }
      final parseMs = sw.elapsedMilliseconds;

      final shapes = <_ChapterShape>[
        for (var i = 0; i < doc.chapters.length; i++)
          _ChapterShape(i, doc.chapters[i]),
      ];
      final totalChars = shapes.fold<int>(0, (a, s) => a + s.body.length);
      final totalRuns = shapes.fold<int>(0, (a, s) => a + s.runs);
      final totalImages = shapes.fold<int>(0, (a, s) => a + s.images);
      final badImgs = shapes.fold<int>(0, (a, s) => a + s.badImageOffsets);
      final badRuns = shapes.fold<int>(0, (a, s) => a + s.badRuns);
      // ignore: avoid_print
      print(
        'BOOK $name chapters=${shapes.length} chars=$totalChars runs=$totalRuns '
        'images=$totalImages bad_image_offsets=$badImgs bad_runs=$badRuns '
        'parse_ms=$parseMs fontFaces=${doc.fontFaces.length}',
      );

      // Heaviest chapters by body length.
      final byLen = List.of(shapes)
        ..sort((a, b) => b.body.length.compareTo(a.body.length));
      for (final s in byLen.take(topN)) {
        // ignore: avoid_print
        print(
          '  ch${s.index} len=${s.body.length} newlines=${s.newlines} '
          'longest_seg=${s.longestSegment} runs=${s.runs} images=${s.images} '
          'title="${s.title}"',
        );
      }

      // Drive the real paginator over every chapter, timing each batch call.
      final passWatch = Stopwatch()..start();
      var worstCallMs = 0;
      var worstChapter = -1;
      var totalPages = 0;
      var totalRunVisits = 0;
      final slowChapters = <String>[];
      final crashed = <String>[];
      for (final s in shapes) {
        final driver = ChapterPaginationDriver(
          text: s.body,
          style: style,
          maxWidth: maxWidth,
          maxHeight: maxHeight,
          direction: TextDirection.ltr,
          runs: s.chapter.runs,
          images: s.chapter.images,
        );
        var calls = 0;
        var chapterWorst = 0;
        try {
          while (!driver.isDone && calls < 200000) {
            final csw = Stopwatch()..start();
            driver.nextChunkUntil(minPages: 1, budget: const Duration(milliseconds: 8));
            final ms = csw.elapsedMilliseconds;
            if (ms > chapterWorst) chapterWorst = ms;
            if (ms > worstCallMs) {
              worstCallMs = ms;
              worstChapter = s.index;
            }
            calls++;
          }
        } catch (e) {
          // Report the crash site and the first overlapping run pair —
          // buildStyledSpans mis-slices when runs overlap (rs < cursor).
          final runs = s.chapter.runs;
          final overlaps = <String>[];
          for (var i = 1; i < runs.length && overlaps.length < 6; i++) {
            if (runs[i].start < runs[i - 1].end) {
              overlaps.add(
                '[${runs[i - 1].start},${runs[i - 1].end}) then '
                '[${runs[i].start},${runs[i].end})',
              );
            }
          }
          crashed.add('ch${s.index}');
          // ignore: avoid_print
          print(
            'CRASH $name ch${s.index} len=${s.body.length} runs=${runs.length} '
            'err="$e" overlaps=${overlaps.join(' | ')}',
          );
        }
        totalPages += driver.pages.length;
        totalRunVisits += driver.debugRunVisits;
        driver.dispose();
        if (chapterWorst > 500) {
          slowChapters.add('ch${s.index}=${chapterWorst}ms');
        }
      }
      final passMs = passWatch.elapsedMilliseconds;
      // ignore: avoid_print
      print(
        'DRIVER $name pass_ms=$passMs worst_call_ms=$worstCallMs '
        'worst_chapter=ch$worstChapter pages=$totalPages run_visits=$totalRunVisits'
        '${crashed.isEmpty ? '' : ' crashed:[${crashed.join(',')}]'}'
        '${slowChapters.isEmpty ? '' : ' slow:[${slowChapters.join(',')}]'}',
      );
    }
  });
}
