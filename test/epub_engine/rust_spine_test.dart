// Golden tests for the Rust spine/TOC path (retire-dart-engine Task 7).
//
// The Dart oracle is retired: the Rust `chapterTitles` / `toc` outputs are
// pinned directly against committed fixture expectations. On TOC-less books
// Rust titles each document from its own `<title>` — a deliberate improvement
// over the retired Dart engine, which left them empty.
import 'package:burrow/src/rust/api/epub.dart';
import 'package:burrow/src/rust/epub/model.dart';
import 'package:burrow/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';

const _nav = 'test/fixtures/epub/nav.epub';
const _ncx = 'test/fixtures/epub/ncx.epub';
const _minimal = 'test/fixtures/epub/minimal.epub';

void main() {
  setUpAll(() async {
    await RustLib.init();
  });

  test('rust TOC titles for the NCX book', () async {
    final handle = await openEpub(path: _ncx);
    expect(await chapterTitles(handle: handle), ['One', 'Two']);
  });

  test('rust TOC titles for the nav book', () async {
    final handle = await openEpub(path: _nav);
    expect(await chapterTitles(handle: handle), ['1 One', 'Two']);
  });

  test('the handle reports spine order, TOC, and chapter count', () async {
    final handle = await openEpub(path: _nav);
    expect(await spine(handle: handle), [
      'oebps/text/ch1.xhtml',
      'oebps/text/ch2.xhtml',
    ]);
    expect(await chapterCount(handle: handle), 2);
    expect(await toc(handle: handle), const [
      TocEntryDto(fileKey: 'oebps/text/ch1.xhtml', title: '1 One'),
      TocEntryDto(
        fileKey: 'oebps/text/ch2.xhtml',
        fragment: 'sec%202',
        title: 'Two',
      ),
    ]);
  });

  test('rust titles a TOC-less book from each document', () async {
    final handle = await openEpub(path: _minimal);
    expect(await chapterTitles(handle: handle), ['One', 'Two']);
  });
}
