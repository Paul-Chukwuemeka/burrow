// Golden tests for the Rust flat-run engine (retire-dart-engine Task 7).
//
// The Dart oracle is retired: `RustEpubEngine.parse` is pinned directly
// against committed fixture expectations — body text, run boundaries, image
// references, and chapter titles/TOC agreement.
//
// `RustLib.init()` dlopens the host build from `rust/target/release/`;
// `test/flutter_test_config.dart` builds it on demand.
import 'dart:ui';

import 'package:burrow/models/style_run.dart';
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

  test('Rust prefers the EPUB3 nav over the NCX when both exist', () async {
    // Pins the accepted nav-first precedence: both TOCs describe the same
    // documents with different titles, so only the nav titles may surface.
    final doc =
        await const RustEpubEngine().parse('test/fixtures/epub/dual-toc.epub');
    expect(doc.chapters, hasLength(2));
    expect(
      doc.chapters.map((c) => c.title).toList(),
      ['Nav One', 'Nav Two'],
    );
    expect(doc.chapters[0].body, 'One\n\nFirst.');
    expect(doc.chapters[1].body, 'Two\n\nSecond.');
  });

  test('Rust falls back to the natural-sorted manifest list with no spine',
      () async {
    // An empty <spine/> falls back to every XHTML manifest entry in natural
    // order (ch2 before ch10), not manifest insertion order.
    final doc =
        await const RustEpubEngine().parse('test/fixtures/epub/no-spine.epub');
    expect(doc.chapters, hasLength(2));
    expect(doc.chapters.map((c) => c.title).toList(), ['Two', 'Ten']);
    expect(doc.chapters[0].body, 'Two\n\nSecond.');
    expect(doc.chapters[1].body, 'Ten\n\nTenth.');
  });

  test('Rust keeps damaged books readable when spine idrefs miss', () async {
    // Every spine idref misses the manifest: no crash, falls back to the
    // manifest list instead of throwing "no readable text".
    final doc = await const RustEpubEngine()
        .parse('test/fixtures/epub/dangling-spine.epub');
    expect(doc.chapters, hasLength(2));
    expect(doc.chapters.map((c) => c.title).toList(), ['One', 'Two']);
    expect(doc.chapters[0].body, 'One\n\nFirst.');
    expect(doc.chapters[1].body, 'Two\n\nSecond.');
  });

  test('Rust keeps text with a sourceless placeholder for a missing image',
      () async {
    // The <img> target is absent from the archive: the text survives with one
    // U+FFFC placeholder whose image carries no source key and 0x0 intrinsics.
    final doc = await const RustEpubEngine()
        .parse('test/fixtures/epub/missing-image.epub');
    expect(doc.chapters, hasLength(1));
    final chapter = doc.chapters.single;
    expect(chapter.title, 'Missing');
    expect(chapter.body, 'Missing\n\nBefore \u{FFFC} after.');
    expect(chapter.images, hasLength(1));
    final image = chapter.images.single;
    expect(image.offset, 16);
    expect(image.sourceKey, isNull);
    expect(image.intrinsicWidth, 0);
    expect(image.intrinsicHeight, 0);
    expect(image.bytes, isEmpty);
  });

  test('Rust keeps an SVG image as a placeholder with decoded intrinsics',
      () async {
    // SVG <img> files are valid entries: one placeholder with the archive key
    // and the width/height decoded from the SVG root.
    final doc = await const RustEpubEngine()
        .parse('test/fixtures/epub/svg-image.epub');
    expect(doc.chapters, hasLength(1));
    final chapter = doc.chapters.single;
    expect(chapter.title, 'Svg');
    expect(chapter.body, 'Svg\n\nBefore \u{FFFC} after.');
    expect(chapter.images, hasLength(1));
    final image = chapter.images.single;
    expect(image.sourceKey, 'oebps/images/pic.svg');
    expect(image.intrinsicWidth, 300);
    expect(image.intrinsicHeight, 150);
  });

  test('Rust drops scripts and never fetches remote targets', () async {
    // The <script> subtree vanishes (no "boom"), the remote <img>/<a> targets
    // are never fetched: the image is a sourceless placeholder, the link keeps
    // only its text.
    final doc = await const RustEpubEngine()
        .parse('test/fixtures/epub/scripted.epub');
    expect(doc.chapters, hasLength(1));
    final chapter = doc.chapters.single;
    expect(chapter.title, 'One'); // document <title> wins over the <h1>.
    expect(
      chapter.body,
      'Scripted\n\nSafe body text.\n\n\u{FFFC}\n\nexternal',
    );
    expect(chapter.images, hasLength(1));
    expect(chapter.images.single.sourceKey, isNull);
  });

  test('Rust recovers readable text from unclosed tags in place', () async {
    // Unclosed <div>/<p> elements recover via the HTML5 parser and keep
    // "Chapter one body"; the well-formed sibling chapter is unaffected.
    // (chapters[0].title is '' — the quick-xml title lookup drops the whole
    // tree when the root never closes; reported, deliberately unpinned.)
    final doc = await const RustEpubEngine()
        .parse('test/fixtures/epub/malformed.epub');
    expect(doc.title, 'Malformed');
    expect(doc.chapters, hasLength(2));
    expect(
      doc.chapters[0].body,
      'Chapter one\n\nChapter one body\n\n\nChapter one second paragraph',
    );
    expect(doc.chapters[1].title, 'Two');
    expect(doc.chapters[1].body, 'Two\n\nChapter two body');
  });

  test('Rust resolves the OPF cover href even when the filename hides it',
      () async {
    // The cover filename contains no "cover": resolution must go through
    // `meta name="cover"` to the manifest href, not a filename scan.
    final doc = await const RustEpubEngine()
        .parse('test/fixtures/epub/opaque-cover.epub');
    expect(doc.chapters, hasLength(1));
    expect(doc.chapters.single.title, 'One');
    expect(doc.chapters.single.body, 'One\n\nFront cover.');
    expect(doc.coverBytes, hasLength(73));
    final meta = await const RustEpubEngine()
        .extractMetadata('test/fixtures/epub/opaque-cover.epub');
    expect(meta.coverBytes, hasLength(73));
  });

  test('Rust marks the OPF-declared cover image full-width inline', () async {
    // The inline <img> is the OPF-declared cover though neither its id nor its
    // filename says "cover": it still renders full-width with real intrinsics.
    final doc = await const RustEpubEngine()
        .parse('test/fixtures/epub/cover-inline.epub');
    expect(doc.chapters, hasLength(1));
    final chapter = doc.chapters.single;
    expect(chapter.body, 'Cover Inline\n\nSee \u{FFFC} here.');
    expect(chapter.images, hasLength(1));
    final image = chapter.images.single;
    expect(image.sourceKey, 'oebps/images/front.png');
    expect(image.intrinsicWidth, 8);
    expect(image.intrinsicHeight, 4);
    expect(image.fullWidth, isTrue);
    final meta = await const RustEpubEngine()
        .extractMetadata('test/fixtures/epub/cover-inline.epub');
    expect(meta.coverBytes, hasLength(74));
  });

  test('Rust applies the external cascade: specificity and hints', () async {
    // External stylesheet: class beats tag (14px notes over 12px paragraphs),
    // the descendant combinator justifies the nested paragraph, and the
    // presentational `align` hint becomes text-align on the last paragraph.
    final doc = await const RustEpubEngine()
        .parse('test/fixtures/epub/external-css.epub');
    expect(doc.chapters, hasLength(1));
    final chapter = doc.chapters.single;
    expect(
      chapter.body,
      'Styled Chapter\n\nFirst note.\n\nSecond note.\n\n'
      'Nested paragraph.\n\nHinted paragraph.',
    );
    expect(chapter.runs, hasLength(6));
    String textOf(StyleRun run) =>
        chapter.body.substring(run.start, run.end);
    final titleRun = chapter.runs.singleWhere((r) => r.css?.fontSize == 24.0);
    expect(textOf(titleRun), 'Styled Chapter');
    final noteRuns =
        chapter.runs.where((r) => r.css?.fontSize == 14.0).toList();
    expect(noteRuns, hasLength(2));
    for (final run in noteRuns) {
      expect(run.css?.color, const Color(0xFF336699));
    }
    expect(textOf(noteRuns[0]), 'First note.');
    expect(textOf(noteRuns[1]), 'Second note.');
    final nested =
        chapter.runs.singleWhere((r) => textOf(r) == 'Nested paragraph.');
    expect(nested.css?.textAlign, TextAlign.justify);
    final hinted =
        chapter.runs.singleWhere((r) => textOf(r) == 'Hinted paragraph.');
    expect(hinted.css?.textAlign, TextAlign.right);
    final familyRun = chapter.runs.firstWhere(
      (r) => (r.css?.fontFamily ?? '').contains('Burrow Serif'),
    );
    expect([familyRun.start, familyRun.end], [0, 79]);
    expect(doc.fontFaces, contains('Burrow Serif'));
    expect(doc.fontFaces['Burrow Serif']?.src, 'oebps/fonts/burrow.woff2');
  });

  test('Rust styles both identical paragraphs, not the first twice', () async {
    // Two identical `.note` paragraphs under an inline <style> rule: the
    // selector cascade must style each occurrence (a substring cascade styled
    // the first paragraph twice and left the second plain).
    final doc = await const RustEpubEngine().parse(
      'test/fixtures/epub/repeated-paragraphs.epub',
    );
    expect(doc.chapters, hasLength(1));
    final chapter = doc.chapters.single;
    expect(chapter.body, 'Repeated\n\nSame text.\n\nSame text.\n\nPlain.');
    expect(chapter.runs, hasLength(3));
    final noteRuns =
        chapter.runs.where((r) => r.css?.fontSize == 14.0).toList();
    expect(noteRuns, hasLength(2));
    expect(
      noteRuns.map((r) => [r.start, r.end]).toList(),
      [
        [10, 20],
        [22, 32],
      ],
    );
    for (final run in noteRuns) {
      expect(run.css?.color, const Color(0xFF333333));
      expect(chapter.body.substring(run.start, run.end), 'Same text.');
    }
  });
}
