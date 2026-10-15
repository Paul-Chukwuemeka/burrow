// Golden tests for the Rust flat-run engine (retire-dart-engine Task 7).
//
// The Dart oracle is retired: `RustEpubEngine.parse` is pinned directly
// against committed fixture expectations — body text, run boundaries, image
// references, and chapter titles/TOC agreement.
//
// `RustLib.init()` dlopens the host build from `rust/target/release/`;
// `test/flutter_test_config.dart` builds it on demand.
import 'package:burrow/services/epub/rust_epub_engine.dart';
import 'package:burrow/src/rust/api/epub.dart';
import 'package:burrow/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';

const _minimal = 'test/fixtures/epub/minimal.epub';
const _nav = 'test/fixtures/epub/nav.epub';
const _ncx = 'test/fixtures/epub/ncx.epub';
const _anchorSplit = 'test/fixtures/epub/anchor-split.epub';

void main() {
  setUpAll(() async {
    await RustLib.init();
  });

  test('Rust parse of minimal.epub keeps titles, bodies, and metadata',
      () async {
    final doc = await const RustEpubEngine().parse(_minimal);

    expect(doc.title, 'Minimal Book');
    expect(doc.author, 'A. Author');
    expect(doc.language, 'en');
    expect(doc.chapters, hasLength(2));
    expect(doc.chapters[0].title, 'One');
    expect(doc.chapters[0].body, 'One\n\nThe first chapter.');
    expect(doc.chapters[0].runs, isEmpty);
    expect(doc.chapters[0].images, isEmpty);
    expect(doc.chapters[1].title, 'Two');
    expect(doc.chapters[1].body, 'Two\n\nThe second chapter.');
  });

  test('Rust titles/TOC agree with the chapter titles', () async {
    for (final path in [_nav, _ncx]) {
      final handle = await openEpub(path: path);
      expect(await chapterTitles(handle: handle), hasLength(2));
      expect(await chapterCount(handle: handle), 2);
    }
    final navHandle = await openEpub(path: _nav);
    expect(await chapterTitles(handle: navHandle), ['1 One', 'Two']);
    final ncxHandle = await openEpub(path: _ncx);
    expect(await chapterTitles(handle: ncxHandle), ['One', 'Two']);
  });

  test('Rust parse of projection.epub keeps one placeholder per image',
      () async {
    final rust =
        await const RustEpubEngine().parse('test/fixtures/epub/projection.epub');
    final chapter = rust.chapters.single;
    expect('\u{FFFC}'.allMatches(chapter.body).length, chapter.images.length);
    expect(chapter.images.single.sourceKey, 'oebps/images/pic.png');
  });

  test('Rust parse splits a single-file book at its TOC anchors', () async {
    final doc = await const RustEpubEngine().parse(_anchorSplit);

    // One chapter per TOC fragment, in document order.
    expect(doc.chapters, hasLength(3));
    expect(
      doc.chapters.map((c) => c.title).toList(),
      ['Part One', 'Part Two', 'Part Three'],
    );
    expect(doc.chapters[0].body, 'First body.\n\n');
    expect(doc.chapters[1].body, 'Second body with emphasis.\n\n');
    expect(doc.chapters[1].runs, hasLength(1));
    expect(doc.chapters[2].images, hasLength(1));
    expect(doc.chapters[2].images.single.sourceKey, isNotNull);

    // The flattened chapter list agrees with the TOC titles.
    final handle = await openEpub(path: _anchorSplit);
    expect(await chapterTitles(handle: handle),
        [for (final c in doc.chapters) c.title]);
    expect(await chapterCount(handle: handle), doc.chapters.length);
  });
}
