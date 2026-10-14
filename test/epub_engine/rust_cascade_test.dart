// Dart adapter / parity test for the Rust CSS cascade (Task 6).
//
// Two things are pinned here:
//  * the computed styles cross FFI intact and style *every* matching element,
//    including repeated identical paragraphs (Review Focus #2);
//  * for the properties the Dart engine also resolves, Rust's computed values
//    feed the existing `EpubCssParser.propsToCssStyle` to exactly the same
//    result as the Dart cascade on `external-css.epub`.
//
// Inheritance and presentational hints are Rust *improvements* over the Dart
// substring-mapping cascade (design D11), so they are asserted separately and
// deliberately not compared to Dart. `RustLib.init()` dlopens the host build
// from `rust/target/release/`; `test/flutter_test_config.dart` builds it on
// demand.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:burrow/models/css_style.dart';
import 'package:burrow/services/epub_css_parser.dart';
import 'package:burrow/src/rust/api/epub.dart';
import 'package:burrow/src/rust/epub/cascade.dart' as rust;
import 'package:burrow/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;

const _repeated = 'test/fixtures/epub/repeated-paragraphs.epub';
const _external = 'test/fixtures/epub/external-css.epub';

const _externalManifest = <String, String>{
  'css1': 'OEBPS/styles/main.css',
  'font1': 'OEBPS/fonts/burrow.woff2',
  'ch1': 'OEBPS/ch1.xhtml',
};

void main() {
  setUpAll(() async {
    await RustLib.init();
  });

  test('every repeated class paragraph is styled over FFI', () async {
    final handle = await openEpub(path: _repeated);
    final tree = await blockTree(handle: handle, chapterKey: 'ch1.xhtml');

    final notes = tree.nodes
        .where((n) => (n.attrs.class_ ?? '').split(' ').contains('note'))
        .toList();
    expect(notes, hasLength(2), reason: 'Dart heuristic styles the first twice');
    for (final note in notes) {
      expect(note.style.fontSize, '14px');
      expect(note.style.color, '#333333');
      expect(note.style.declared, contains('font-size'));
    }
  });

  test('inheritance flows font-family to descendants over FFI', () async {
    final handle = await openEpub(path: _external);
    final tree = await blockTree(handle: handle, chapterKey: 'ch1.xhtml');

    final h1 = tree.nodes.firstWhere((n) => n.attrs.tag == 'h1');
    final note = tree.nodes.firstWhere(
      (n) => (n.attrs.class_ ?? '').contains('note'),
    );
    // `body { font-family: … }` is inherited, never re-declared on descendants.
    for (final node in [h1, note]) {
      expect(node.style.fontFamily, "'Burrow Serif', serif");
      expect(node.style.declared, isNot(contains('font-family')));
    }
  });

  test('presentational hints and descendant combinators apply', () async {
    final handle = await openEpub(path: _external);
    final tree = await blockTree(handle: handle, chapterKey: 'ch1.xhtml');

    final hinted = tree.nodes.firstWhere((n) => n.attrs.align == 'right');
    expect(hinted.style.textAlign, 'right');

    final nested = tree.nodes.firstWhere(
      (n) =>
          n.attrs.tag == 'p' &&
          n.style.textAlign == 'justify',
    );
    expect(nested.style.textAlign, 'justify');
  });

  test('computed styles match the Dart cascade for shared properties',
      () async {
    final archive = _openArchive(_external);
    Uint8List readEntry(String name) => _readEntry(archive, name);

    // The parser stores resolved rules against the exact DOM elements it saw,
    // so hand it *our* document rather than letting it parse its own.
    final document =
        html_parser.parse(utf8.decode(readEntry('OEBPS/ch1.xhtml')));
    final parser = EpubCssParser.parse(
      spinePaths: const ['OEBPS/ch1.xhtml'],
      manifest: _externalManifest,
      readEntry: readEntry,
      chapterDom: {'oebps/ch1.xhtml': document},
    );

    final handle = await openEpub(path: _external);
    final tree = await blockTree(handle: handle, chapterKey: 'ch1.xhtml');

    void compare(rust.ComputedStyle rustStyle, CssStyle dartStyle) {
      final fromRust =
          EpubCssParser.propsToCssStyle(_declaredProps(rustStyle));
      _expectSameStyle(fromRust, dartStyle);
    }

    final h1 = document.querySelector('h1.title')!;
    final rustH1 = tree.nodes.firstWhere((n) => n.attrs.tag == 'h1');
    compare(rustH1.style, parser.resolveStyle('oebps/ch1.xhtml', h1));

    final notes = document.querySelectorAll('p.note');
    expect(notes, hasLength(2));
    final rustNotes = tree.nodes
        .where((n) => (n.attrs.class_ ?? '').contains('note'))
        .toList();
    expect(rustNotes, hasLength(2));
    for (var i = 0; i < 2; i++) {
      compare(rustNotes[i].style, parser.resolveStyle('oebps/ch1.xhtml', notes[i]));
    }

    final nested = document.querySelector('.box p')!;
    final rustNested = tree.nodes.firstWhere(
      (n) => n.attrs.tag == 'p' && n.style.textAlign == 'justify',
    );
    compare(rustNested.style, parser.resolveStyle('oebps/ch1.xhtml', nested));
  });

  test('@font-face extraction matches the Dart parser', () async {
    final archive = _openArchive(_external);
    Uint8List readEntry(String name) => _readEntry(archive, name);
    final dartFaces = EpubCssParser.parse(
      spinePaths: const ['OEBPS/ch1.xhtml'],
      manifest: _externalManifest,
      readEntry: readEntry,
    ).fontFaces;

    final handle = await openEpub(path: _external);
    final faces = await fontFaces(handle: handle);
    expect(faces, hasLength(1));
    expect(faces.single.family, 'Burrow Serif');
    expect(faces.single.src, 'oebps/fonts/burrow.woff2');
    // Dart preserves the CSS file's path case; Rust returns a normalised key.
    expect(
      faces.single.src.toLowerCase(),
      dartFaces['Burrow Serif']!.src.toLowerCase(),
    );

    // The metadata path populates the same faces.
    final meta = await metadata(handle: handle);
    expect(meta.fontFaces.single.family, 'Burrow Serif');
  });
}

Map<String, String> _declaredProps(rust.ComputedStyle style) {
  final values = <String, String?>{
    'font-family': style.fontFamily,
    'font-size': style.fontSize,
    'font-weight': style.fontWeight,
    'font-style': style.fontStyle,
    'color': style.color,
    'line-height': style.lineHeight,
    'letter-spacing': style.letterSpacing,
    'word-spacing': style.wordSpacing,
    'text-align': style.textAlign,
    'text-indent': style.textIndent,
    'text-decoration': style.textDecoration,
    'text-transform': style.textTransform,
    'white-space': style.whiteSpace,
    'margin-top': style.marginTop,
    'margin-right': style.marginRight,
    'margin-bottom': style.marginBottom,
    'margin-left': style.marginLeft,
    'padding-top': style.paddingTop,
    'padding-right': style.paddingRight,
    'padding-bottom': style.paddingBottom,
    'padding-left': style.paddingLeft,
    'width': style.width,
    'height': style.height,
    'max-width': style.maxWidth,
    'max-height': style.maxHeight,
    'vertical-align': style.verticalAlign,
  };
  final declared = <String, String>{};
  for (final property in style.declared) {
    final value = values[property];
    if (value != null) declared[property] = value;
  }
  return declared;
}

void _expectSameStyle(CssStyle rust, CssStyle dart) {
  expect(rust.fontSize, dart.fontSize, reason: 'font-size');
  expect(rust.color, dart.color, reason: 'color');
  expect(rust.textAlign, dart.textAlign, reason: 'text-align');
  expect(rust.textIndent, dart.textIndent, reason: 'text-indent');
  expect(rust.marginTop, dart.marginTop, reason: 'margin-top');
  expect(rust.marginRight, dart.marginRight, reason: 'margin-right');
  expect(rust.marginBottom, dart.marginBottom, reason: 'margin-bottom');
  expect(rust.marginLeft, dart.marginLeft, reason: 'margin-left');
  expect(rust.fontWeight, dart.fontWeight, reason: 'font-weight');
  expect(rust.fontStyle, dart.fontStyle, reason: 'font-style');
  expect(rust.textDecoration, dart.textDecoration, reason: 'text-decoration');
  expect(rust.fontFamily, dart.fontFamily, reason: 'font-family');
  expect(rust.lineHeight, dart.lineHeight, reason: 'line-height');
  expect(rust.letterSpacing, dart.letterSpacing, reason: 'letter-spacing');
  expect(rust.wordSpacing, dart.wordSpacing, reason: 'word-spacing');
  expect(rust.textTransform, dart.textTransform, reason: 'text-transform');
  expect(rust.whiteSpace, dart.whiteSpace, reason: 'white-space');
  expect(rust.width, dart.width, reason: 'width');
  expect(rust.height, dart.height, reason: 'height');
  expect(rust.maxWidth, dart.maxWidth, reason: 'max-width');
  expect(rust.maxHeight, dart.maxHeight, reason: 'max-height');
}

Archive _openArchive(String path) =>
    ZipDecoder().decodeBytes(File(path).readAsBytesSync());

Uint8List _readEntry(Archive archive, String name) {
  final file = archive.files.firstWhere(
    (f) => f.name.toLowerCase() == name.toLowerCase(),
    orElse: () => throw StateError('missing entry: $name'),
  );
  return file.content;
}
