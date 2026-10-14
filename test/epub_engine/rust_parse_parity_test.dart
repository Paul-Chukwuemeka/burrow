// Parity test for the Rust flat-run engine (Task 7, Step 7).
//
// The Rust `RustEpubEngine.parse` must produce the same flat chapters the Dart
// engine does for a book the Dart engine gets right: identical body text,
// identical run boundaries (offset + emphasis), the same images, and the same
// metadata. `minimal.epub` is unstyled, so its runs are empty on both sides —
// the parity here is the body's whitespace collapse and the chapter split.
//
// It also pins the chapter-titles/TOC parity: the Rust TOC's titles must equal
// the chapter titles the Dart engine derives, so Task 10 can migrate the
// chapter list without changing navigation.
//
// `RustLib.init()` dlopens the host build from `rust/target/release/`;
// `test/flutter_test_config.dart` builds it on demand.
import 'package:burrow/services/epub/dart_epub_engine.dart';
import 'package:burrow/services/epub/rust_epub_engine.dart';
import 'package:burrow/src/rust/api/epub.dart';
import 'package:burrow/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';

const _minimal = 'test/fixtures/epub/minimal.epub';
const _nav = 'test/fixtures/epub/nav.epub';
const _ncx = 'test/fixtures/epub/ncx.epub';

void main() {
  setUpAll(() async {
    await RustLib.init();
  });

  test('Rust parse matches the Dart engine for minimal.epub', () async {
    final dart = await const DartEpubEngine().parse(_minimal);
    final rust = await const RustEpubEngine().parse(_minimal);

    expect(rust.title, dart.title);
    expect(rust.author, dart.author);
    expect(rust.language, dart.language);
    expect(rust.chapters, hasLength(dart.chapters.length));

    for (var i = 0; i < dart.chapters.length; i++) {
      final expected = dart.chapters[i];
      final actual = rust.chapters[i];
      expect(actual.body, expected.body, reason: 'chapter $i body');
      expect(actual.runs, expected.runs, reason: 'chapter $i runs');
      expect(actual.images, hasLength(expected.images.length));
    }
  });

  test('Rust titles/TOC agree with the Dart chapter titles', () async {
    for (final path in [_nav, _ncx]) {
      final dartTitles = [
        for (final chapter
            in (await const DartEpubEngine().parse(path)).chapters)
          chapter.title,
      ];
      final handle = await openEpub(path: path);
      final tocTitles = [for (final entry in await toc(handle: handle)) entry.title];
      // Every Dart chapter title appears in the Rust TOC for these books (the
      // TOC covers every spine document).
      expect(tocTitles, dartTitles, reason: path);
      expect(await chapterTitles(handle: handle), dartTitles, reason: path);
    }
  });

  test('Rust parse of projection.epub keeps one placeholder per image',
      () async {
    final rust =
        await const RustEpubEngine().parse('test/fixtures/epub/projection.epub');
    final chapter = rust.chapters.single;
    expect('\u{FFFC}'.allMatches(chapter.body).length, chapter.images.length);
    expect(chapter.images.single.sourceKey, 'oebps/images/pic.png');
  });
}
