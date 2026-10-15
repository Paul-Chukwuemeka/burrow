// Seam-routing tests (retire-dart-engine Task 6).
//
// Every parse/metadata/hydrate call site reaches the content engine through
// `createEpubEngine`, never `DocumentParser` directly. These tests pin the
// seam's `hydrateImages`/`hydrateFonts`/`clearCacheFor` routing for both
// engine ids: the Dart engine must hydrate deferred image bytes through its
// isolate re-read (the reader's Dart path) and no-op font hydration (Dart
// embeds font bytes at parse time), while the Rust engine hydrates through
// its own handle.
//
// `RustLib.init()` dlopens the host build from `rust/target/release/`;
// `test/flutter_test_config.dart` builds it on demand.
import 'dart:typed_data';

import 'package:burrow/models/style_run.dart';
import 'package:burrow/services/document_parser.dart';
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

  test('dart engine hydrates deferred image bytes through the seam', () async {
    final engine = createEpubEngine(dartEpubEngineId);
    final doc = await engine.parse(_projection);
    final image = doc.chapters.single.images.single;
    expect(image.bytes, isNotEmpty);
    expect(image.sourceKey, isNotNull);

    final hydrated = await engine.hydrateImages(_stripBytes(doc), _projection);
    final filled = hydrated.chapters.single.images.single;
    expect(filled.bytes, isNotEmpty);
    // PNG magic: the bytes are the real archive entry.
    expect(filled.bytes.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
  });

  test('dart engine font hydration is a no-op (bytes embedded at parse)',
      () async {
    final engine = createEpubEngine(dartEpubEngineId);
    final doc = await engine.parse(_embeddedFont);
    final hydrated = await engine.hydrateFonts(doc, _embeddedFont);
    expect(identical(hydrated, doc), isTrue);
  });

  test('rust engine hydrates through the seam, not a direct call', () async {
    final engine = createEpubEngine(rustEpubEngineId);
    final doc = await engine.parse(_projection);
    expect(doc.chapters.single.images.single.bytes, isEmpty);
    final hydrated = await engine.hydrateImages(doc, _projection);
    expect(hydrated.chapters.single.images.single.bytes, isNotEmpty);

    final fonts = await engine.hydrateFonts(
      await engine.parse(_embeddedFont),
      _embeddedFont,
    );
    expect(fonts.fontFaces['Burrow Serif']!.bytes, isNotEmpty);
  });

  test('clearCacheFor routes through the seam without throwing', () {
    // Missing file: both engines are best-effort no-ops here (Rust writes no
    // cache entry in Phase A; Dart deletes only its own namespace entry).
    createEpubEngine(dartEpubEngineId).clearCacheFor('/definitely/missing.epub');
    createEpubEngine(rustEpubEngineId).clearCacheFor('/definitely/missing.epub');
  });
}
