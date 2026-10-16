// Regression tests for the reader "laying out pages" freeze.
//
// `css-only-runs.epub` is styled exclusively through nested CSS classes (no
// emphasis markup), so the projected chapter has a CSS-only run list. The Rust
// engine used to return that raw per-node list — overlapping, sometimes with
// identical extents — and the Dart paginator's span builder re-emitted covered
// text while measuring, so line offsets ran past the chapter body and the first
// pagination pass died on a RangeError. In release builds nothing catches that
// exception, the pass never reschedules and the reader sits on "Laying out
// pages…" forever.
//
// Pins (1) the engine emits sorted, disjoint, in-bounds runs for the fixture
// and (2) the paginator lays such a chapter out to completion.
import 'package:burrow/models/reader_settings.dart';
import 'package:burrow/services/epub/rust_epub_engine.dart';
import 'package:burrow/services/paginator.dart';
import 'package:burrow/src/rust/frb_generated.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _fixture = 'test/fixtures/epub/css-only-runs.epub';

void main() {
  setUpAll(() async {
    await RustLib.init();
  });

  test('CSS-only chapters project sorted, disjoint, in-bounds runs', () async {
    final doc = await const RustEpubEngine().parse(_fixture);
    expect(doc.chapters, hasLength(1));
    final chapter = doc.chapters.single;
    final body = chapter.body;

    expect(body.length, greaterThan(700));
    expect(body, contains('Nested class styling must not corrupt run offsets.'));
    expect(chapter.runs, isNotEmpty);
    expect(
      chapter.runs.any((run) => run.css?.fontWeight == FontWeight.w700),
      isTrue,
      reason: 'the .em span should carry its weight run',
    );

    for (var i = 0; i < chapter.runs.length; i++) {
      final run = chapter.runs[i];
      expect(run.start, lessThan(run.end), reason: 'run $i inverted');
      expect(
        run.end,
        lessThanOrEqualTo(body.length),
        reason: 'run $i out of bounds',
      );
      if (i > 0) {
        expect(
          run.start,
          greaterThanOrEqualTo(chapter.runs[i - 1].end),
          reason: 'runs ${i - 1} and $i overlap',
        );
      }
    }
  });

  test('the paginator lays out a CSS-only chapter to completion', () async {
    final doc = await const RustEpubEngine().parse(_fixture);
    final chapter = doc.chapters.single;
    const style = TextStyle(fontSize: 18, height: 1.5);

    final paginator = Paginator.paginate(
      text: chapter.body,
      style: style,
      maxWidth: 380,
      maxHeight: 300,
      direction: TextDirection.ltr,
      runs: chapter.runs,
      images: chapter.images,
      settings: ReaderSettings(),
      theme: ReaderTheme.light,
    );

    expect(paginator.pages, isNotEmpty);
    expect(
      chapter.body.substring(0, paginator.pages.first.start).trim(),
      isEmpty,
      reason: 'pagination must start at the top of the chapter',
    );
    for (final page in paginator.pages) {
      expect(page.start, lessThan(page.end));
      expect(page.end, lessThanOrEqualTo(chapter.body.length));
    }
    expect(
      chapter.body.substring(paginator.pages.last.end).trim(),
      isEmpty,
      reason: 'pages must cover the whole chapter',
    );
  });
}
