// Golden tests for the Rust TXT parser (retire-dart-engine Task 7).
//
// The Dart oracle is retired: `RustEpubEngine.parse` is pinned directly
// against committed fixture expectations — filename-derived title, chapter
// splits, and the empty-file rejection. Fixtures cover plain UTF-8,
// heading/blank-run splits, and the Latin-1/BOM fallback.
//
// `RustLib.init()` dlopens the host build from `rust/target/release/`;
// `test/flutter_test_config.dart` builds it on demand.
import 'dart:io';

import 'package:burrow/services/epub/rust_epub_engine.dart';
import 'package:burrow/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpAll(() async {
    await RustLib.init();
  });

  test('plain UTF-8 parses as a single untitled chapter', () async {
    const path = 'test/fixtures/epub/plain.txt';
    final doc = await const RustEpubEngine().parse(path);

    expect(doc.title, 'plain');
    expect(doc.author, isEmpty);
    expect(doc.chapters, hasLength(1));
    expect(doc.chapters.single.title, isEmpty);
    expect(
      doc.chapters.single.body,
      'The burrow was quiet in the morning.\n\n'
      'A second paragraph follows here, plain and simple.\n',
    );
    expect(doc.chapters.single.runs, isEmpty);
    expect(doc.chapters.single.images, isEmpty);
  });

  test('headings and blank runs split chapters with titles', () async {
    const path = 'test/fixtures/epub/chapters.txt';
    final doc = await const RustEpubEngine().parse(path);

    expect(doc.title, 'chapters');
    expect(
      doc.chapters.map((c) => c.title).toList(),
      ['Chapter 1: The Beginning', 'Chapter 2: The Middle', 'PART II'],
    );
    expect(
      doc.chapters.map((c) => c.body).toList(),
      [
        'Once upon a time in the burrow.\n\nMore of the first chapter.',
        'Something happened in the middle.',
        'The second part begins here.',
      ],
    );
  });

  test('Latin-1/BOM fixture decodes without throwing', () async {
    const path = 'test/fixtures/epub/latin1-bom.txt';
    final doc = await const RustEpubEngine().parse(path);

    expect(doc.title, 'latin1-bom');
    expect(doc.chapters, hasLength(1));
    expect(
      doc.chapters.single.body,
      'ï»¿Café crème brûlée.\n\nNaïve notes from the burrow.\n',
    );
  });

  test('an empty file is rejected as a FormatException', () async {
    final tmp = await Directory.systemTemp.createTemp('burrow_txt_golden');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final empty = File('${tmp.path}/empty.txt')..writeAsStringSync('   \n  ');
    await expectLater(
      const RustEpubEngine().parse(empty.path),
      throwsA(isA<FormatException>()),
    );
  });
}
