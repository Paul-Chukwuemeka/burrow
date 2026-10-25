// DIAGNOSTIC PROBE — not a unit test.
//
// Watches what Flutter's TextPainter actually reports for:
//   * a plain text line under a base style whose `height` differs from the
//     font's raw ascent+descent,
//   * the synthetic blank line a `\n\n` paragraph break contributes (both as
//     its own empty paragraph and as part of a merged text),
// and compares those with the heights buildStyledSpans/paginator derive.
//
// Run: BURROW_METRIC_PROBE=1 flutter test test/debug/metric_probe_test.dart
import 'dart:io';

import 'package:burrow/models/style_run.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  if (Platform.environment['BURROW_METRIC_PROBE'] != '1') {
    test('metric probe (disabled)', () {
      // ignore: avoid_print
      print('Skipped: set BURROW_METRIC_PROBE=1 to run.');
    });
    return;
  }
  TestWidgetsFlutterBinding.ensureInitialized();

  test('metrics: text lines vs blank lines', () async {
    void dump(String label, TextPainter tp) {
      tp.layout(maxWidth: 371.43);
      final metrics = tp.computeLineMetrics();
      // ignore: avoid_print
      print('PROBE $label -> ${metrics.length} lines, total=${tp.height}');
      for (var i = 0; i < metrics.length; i++) {
        // ignore: avoid_print
        print(
          'PROBE   line[$i] height=${metrics[i].height.toStringAsFixed(2)} '
          'ascent=${metrics[i].ascent.toStringAsFixed(2)} '
          'descent=${metrics[i].descent.toStringAsFixed(2)}',
        );
      }
      tp.dispose();
    }

    // 1: single line, base style with height multiplier.
    dump(
      'single X style 18/1.6 (no family)',
      TextPainter(
        text: const TextSpan(
          style: TextStyle(fontSize: 18, height: 1.6, color: Colors.black),
          text: 'X',
        ),
        textDirection: TextDirection.ltr,
      ),
    );

    // 2: text line inside a paragraph, plain span inheriting base.
    dump(
      'paragraph text line, plain span + base 18/1.6',
      TextPainter(
        text: TextSpan(
          style: const TextStyle(fontSize: 18, height: 1.6),
          children: buildStyledSpans(
            'The quick brown fox jumps over the lazy dog again and yet '
            'again to force at least two wrapped lines for the metrics check.',
            const [],
            const TextStyle(fontSize: 18, height: 1.6),
            0,
            110,
          ),
        ),
        textDirection: TextDirection.ltr,
      ),
    );

    // 3: merged two-paragraph text with one blank line between.
    dump(
      'merged p1 "\\n\\n" p2 (blank line inside one TextPainter)',
      TextPainter(
        text: const TextSpan(
          style: TextStyle(fontSize: 18, height: 1.6),
          text: 'One two three four five six seven eight nine ten eleven '
              'twelve thirteen fourteen.\n\nFive six seven eight nine ten '
              'eleven twelve thirteen fourteen fifteen sixteen.',
        ),
        textDirection: TextDirection.ltr,
      ),
    );

    // 4: the blank paragraph measured the way the paginator does it, as its
    //    own empty paragraph next to real ones.
    dump(
      'p1 alone',
      TextPainter(
        text: const TextSpan(
          style: TextStyle(fontSize: 18, height: 1.6),
          text: 'One two three four five six seven eight nine ten eleven '
              'twelve thirteen fourteen.',
        ),
        textDirection: TextDirection.ltr,
      ),
    );
    dump(
      'blank paragraph alone (empty text)',
      TextPainter(
        text: const TextSpan(
          style: TextStyle(fontSize: 18, height: 1.6),
          text: '',
        ),
        textDirection: TextDirection.ltr,
      ),
    );

    // 5: single X with NO height multiplier (raw font metrics baseline).
    dump(
      'single X style 18 raw (no height)',
      TextPainter(
        text: const TextSpan(
          style: TextStyle(fontSize: 18, color: Colors.black),
          text: 'X',
        ),
        textDirection: TextDirection.ltr,
      ),
    );
  });
}
