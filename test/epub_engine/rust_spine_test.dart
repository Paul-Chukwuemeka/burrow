// Parity test for the Rust spine/TOC path (Task 4).
//
// The Rust `chapterTitles` / `toc` outputs must agree with the Dart engine on
// books whose TOC covers every spine document, so Task 10 can migrate the
// chapter list to Rust without changing navigation (spec D7/D14). Dart's
// `TocEntry` is not exposed publicly, so parity is asserted through the chapter
// titles the Dart parser produces. On TOC-less books Rust titles each document
// from its own `<title>` while Dart leaves them empty — a deliberate
// improvement (spec D11), asserted at the bottom so the divergence stays
// classified.
import 'dart:io';

import 'package:burrow/services/document_parser.dart';
import 'package:burrow/src/rust/api/epub.dart';
import 'package:burrow/src/rust/epub/model.dart';
import 'package:burrow/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';

const _nav = 'test/fixtures/epub/nav.epub';
const _ncx = 'test/fixtures/epub/ncx.epub';
const _minimal = 'test/fixtures/epub/minimal.epub';

/// The chapter titles the Dart engine produces for [path].
List<String> _dartTitles(String path) {
  final doc = DocumentParser.parseEpubBytes(File(path).readAsBytesSync());
  return [for (final chapter in doc.chapters) chapter.title];
}

void main() {
  setUpAll(() async {
    await RustLib.init();
  });

  for (final path in [_nav, _ncx]) {
    test('rust TOC titles match the Dart engine for $path', () async {
      final handle = await openEpub(path: path);
      expect(await chapterTitles(handle: handle), _dartTitles(path));
    });
  }

  test('the handle reports spine order, TOC, and chapter count', () async {
    final handle = await openEpub(path: _nav);
    expect(await spine(handle: handle), [
      'oebps/text/ch1.xhtml',
      'oebps/text/ch2.xhtml',
    ]);
    expect(await chapterCount(handle: handle), 2);
    expect(await toc(handle: handle), const [
      TocEntryDto(fileKey: 'oebps/text/ch1.xhtml', title: 'One'),
      TocEntryDto(
        fileKey: 'oebps/text/ch2.xhtml',
        fragment: 'sec%202',
        title: 'Two',
      ),
    ]);
  });

  test('rust titles a TOC-less book where Dart leaves titles empty', () async {
    final handle = await openEpub(path: _minimal);
    expect(await chapterTitles(handle: handle), ['One', 'Two']);
    expect(_dartTitles(_minimal), ['', '']);
  });
}
