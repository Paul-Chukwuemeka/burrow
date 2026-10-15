// Seam-routing tests (retire-dart-engine Task 7).
//
// Every parse/metadata/hydrate call site reaches the content engine through
// `createEpubEngine`. These tests pin the seam's `hydrateImages`/
// `hydrateFonts`/`clearCacheFor` routing for the single remaining engine:
// the Rust engine hydrates deferred image bytes and font bytes through its
// own handle, and `clearCacheFor` clears every engine namespace without
// throwing.
//
// `RustLib.init()` dlopens the host build from `rust/target/release/`;
// `test/flutter_test_config.dart` builds it on demand.
import 'dart:typed_data';

import 'package:burrow/models/document.dart';
import 'package:burrow/services/epub/epub_engine_factory.dart';
import 'package:burrow/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';

const _projection = 'test/fixtures/epub/projection.epub';
const _embeddedFont = 'test/fixtures/epub/embedded-font.epub';

/// Simulates the reader's cache-hit path: image bytes deferred, archive
/// references retained.
ParsedDocument _stripBytes(ParsedDocument doc) => ParsedDocument(
  title: doc.title,
  author: doc.author,
  chapters: [
    for (final ch in doc.chapters)
      Chapter(ch.title, ch.body, ch.runs, [
        for (final img in ch.images) img.copyWith(bytes: Uint8List(0)),
      ]),
  ],
);

void main() {
  setUpAll(() async {
    await RustLib.init();
  });

  test('rust engine hydrates deferred image bytes through the seam', () async {
    final engine = createEpubEngine(rustEpubEngineId);
    final doc = await engine.parse(_projection);
    expect(doc.chapters.single.images.single.bytes, isEmpty);

    final hydrated = await engine.hydrateImages(_stripBytes(doc), _projection);
    final filled = hydrated.chapters.single.images.single;
    expect(filled.bytes, isNotEmpty);
    // PNG magic: the bytes are the real archive entry.
    expect(filled.bytes.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
  });

  test('rust engine hydrates fonts through the seam', () async {
    final engine = createEpubEngine(rustEpubEngineId);
    final fonts = await engine.hydrateFonts(
      await engine.parse(_embeddedFont),
      _embeddedFont,
    );
    expect(fonts.fontFaces['Burrow Serif']!.bytes, isNotEmpty);
  });

  test('clearCacheFor routes through the seam without throwing', () {
    // Missing file: best-effort no-op across every engine namespace.
    createEpubEngine(rustEpubEngineId).clearCacheFor('/definitely/missing.epub');
  });
}
