// Parity test for the Rust TXT parser (retire-dart-engine Task 1).
//
// For each committed `.txt` fixture, `RustEpubEngine.parse` (via the FFI
// `parseTxt` port of `DocumentParser._parseTxt`/`chapterizeTxt`) must equal
// `DartEpubEngine.parse` on title, per-chapter title/body, and runs/images
// (TXT chapters carry no runs or images, but the assertions pin that).
// Fixtures cover plain UTF-8, heading/blank-run splits, and the
// Latin-1/BOM fallback.
//
// `RustLib.init()` dlopens the host build from `rust/target/release/`;
// `test/flutter_test_config.dart` builds it on demand.
import 'dart:io';

import 'package:burrow/services/epub/dart_epub_engine.dart';
import 'package:burrow/services/epub/rust_epub_engine.dart';
import 'package:burrow/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';

const _fixtures = [
  'test/fixtures/epub/plain.txt',
  'test/fixtures/epub/chapters.txt',
  'test/fixtures/epub/latin1-bom.txt',
];

void main() {
  setUpAll(() async {
    await RustLib.init();
  });

  for (final path in _fixtures) {
    test('Rust TXT parse matches the Dart engine for $path', () async {
      final dart = await const DartEpubEngine().parse(path);
      final rust = await const RustEpubEngine().parse(path);

      expect(rust.title, dart.title);
      expect(rust.author, dart.author);
      expect(rust.chapters, hasLength(dart.chapters.length));

      for (var i = 0; i < dart.chapters.length; i++) {
        final expected = dart.chapters[i];
        final actual = rust.chapters[i];
        expect(actual.title, expected.title, reason: 'chapter $i title');
        expect(actual.body, expected.body, reason: 'chapter $i body');
        expect(actual.runs, expected.runs, reason: 'chapter $i runs');
        expect(
          actual.images,
          hasLength(expected.images.length),
          reason: 'chapter $i images',
        );
      }
    });
  }

  test('Rust TXT parse rejects an empty file like the Dart engine', () async {
    final tmp = await Directory.systemTemp.createTemp('burrow_txt_parity');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final empty = File('${tmp.path}/empty.txt')..writeAsStringSync('   \n  ');
    await expectLater(
      const RustEpubEngine().parse(empty.path),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      const DartEpubEngine().parse(empty.path),
      throwsA(isA<FormatException>()),
    );
  });
}
