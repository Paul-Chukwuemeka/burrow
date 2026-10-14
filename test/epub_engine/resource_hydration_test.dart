// Hydration tests for the Rust resource-by-reference engine (Task 8).
//
// The Rust `RustEpubEngine.parse` keeps `ImageRun.bytes` empty and carries
// only `sourceKey` references (spec D15); bytes are fetched lazily through
// the Rust handle via `read_resource` instead of re-reading the archive with
// Dart. A missing entry degrades to a sized placeholder (empty bytes), never
// a failed book. `@font-face` families flow into `EpubCssParser
// .loadEmbeddedFonts` unchanged; a font file that is missing is skipped.
//
// `RustLib.init()` dlopens the host build from `rust/target/release/`;
// `test/flutter_test_config.dart` builds it on demand.
import 'dart:typed_data';

import 'package:burrow/services/epub/rust_epub_engine.dart';
import 'package:burrow/services/epub_css_parser.dart';
import 'package:burrow/src/rust/api/epub.dart';
import 'package:burrow/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';

const _projection = 'test/fixtures/epub/projection.epub';
const _missingImage = 'test/fixtures/epub/missing-image.epub';
const _embeddedFont = 'test/fixtures/epub/embedded-font.epub';

void main() {
  setUpAll(() async {
    await RustLib.init();
  });

  test('image bytes are fetched lazily through the Rust handle', () async {
    const engine = RustEpubEngine();
    final doc = await engine.parse(_projection);
    final image = doc.chapters.single.images.single;
    // Bytes stay empty on parse; only the reference crosses the FFI (D15).
    expect(image.bytes, isEmpty);
    expect(image.sourceKey, 'oebps/images/pic.png');

    final handle = await openEpub(path: _projection);
    final bytes = await engine.readResource(handle, image.sourceKey!);
    expect(bytes, isNotEmpty);
    // PNG magic: the bytes are the real entry.
    expect(bytes.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
  });

  test('missing image yields a sized placeholder, never a failure', () async {
    const engine = RustEpubEngine();
    final doc = await engine.parse(_missingImage);
    expect(doc.chapters.single.images, hasLength(1));
    final hydrated = await engine.hydrateImages(doc, _missingImage);
    final image = hydrated.chapters.single.images.single;
    // No backing entry: bytes stay empty so the renderer shows its sized
    // placeholder, and the book still opens.
    expect(image.bytes, isEmpty);
    expect(
      hydrated.chapters.single.body.contains('\u{FFFC}'),
      isTrue,
    );
  });

  test('parse + hydrate fills deferred image bytes from Rust', () async {
    const engine = RustEpubEngine();
    final doc = await engine.parse(_projection);
    final hydrated = await engine.hydrateImages(doc, _projection);
    final image = hydrated.chapters.single.images.single;
    expect(image.bytes, isNotEmpty);
    expect(image.intrinsicWidth, 8);
    expect(image.intrinsicHeight, 4);
  });

  test('font faces hydrate through Rust; loadEmbeddedFonts skips missing',
      () async {
    const engine = RustEpubEngine();
    final doc = await engine.parse(_embeddedFont);
    expect(doc.fontFaces.keys, contains('Burrow Serif'));

    final hydrated = await engine.hydrateFonts(doc, _embeddedFont);
    final face = hydrated.fontFaces['Burrow Serif']!;
    expect(face.bytes, isNotNull);
    expect(face.bytes, isNotEmpty);

    // A font whose file is missing keeps null bytes, which
    // `loadEmbeddedFonts` skips without throwing.
    final missing = {
      'Ghost': const FontFaceInfo(family: 'Ghost', src: 'oebps/fonts/ghost.ttf'),
    };
    expect(await EpubCssParser.loadEmbeddedFonts(missing), isEmpty);
  });

  test('readResource throws for a missing entry', () async {
    const engine = RustEpubEngine();
    final handle = await openEpub(path: _missingImage);
    // FRB surfaces the Rust `Err(String)` as a thrown string, not an
    // `Exception` instance.
    expect(
      engine.readResource(handle, 'oebps/images/ghost.png'),
      throwsA(anything),
    );
  });

  test('FontFaceInfo bytes round-trip through Uint8List', () async {
    const engine = RustEpubEngine();
    final handle = await openEpub(path: _embeddedFont);
    final faces = await fontFaces(handle: handle);
    expect(faces.single.family, 'Burrow Serif');
    final bytes = await engine.readResource(handle, faces.single.src);
    final info = FontFaceInfo(
      family: faces.single.family,
      src: faces.single.src,
      bytes: Uint8List.fromList(bytes),
    );
    expect(info.bytes, isNotEmpty);
  });
}
