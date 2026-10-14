// Pins the final-fix Critical 1: `annotation`/`type`/`source` must survive
// the Rust metadata path.
//
// The parity differ compares these fields, but no earlier fixture set them,
// so the gate passed vacuously while the Rust DTO dropped them (and the
// library worker overwrote the book's values with null). This test fails
// while the Rust engine drops the fields and passes once both engines agree
// on `annotated-meta.epub` — with non-null expectations so it can never pass
// vacuously again.
import 'package:burrow/services/epub/dart_epub_engine.dart';
import 'package:burrow/services/epub/rust_epub_engine.dart';
import 'package:burrow/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';

const _fixture = 'test/fixtures/epub/annotated-meta.epub';

void main() {
  setUpAll(() async {
    await RustLib.init();
  });

  test('rust metadata keeps annotation/type/source like the Dart engine', () async {
    const dartEngine = DartEpubEngine();
    const rustEngine = RustEpubEngine();
    final dartMeta = await dartEngine.extractMetadata(_fixture);
    final rustMeta = await rustEngine.extractMetadata(_fixture);

    // Non-null on the Dart side proves the fixture actually covers the fields.
    expect(dartMeta.annotation, 'A Calibre annotation for parity.');
    expect(dartMeta.type, 'Text');
    expect(dartMeta.source, 'https://example.com/annotated-meta');

    expect(rustMeta.annotation, dartMeta.annotation);
    expect(rustMeta.type, dartMeta.type);
    expect(rustMeta.source, dartMeta.source);
  });

  test('rust parse keeps annotation/type/source on the document', () async {
    const dartEngine = DartEpubEngine();
    const rustEngine = RustEpubEngine();
    final dartDoc = await dartEngine.parse(_fixture);
    final rustDoc = await rustEngine.parse(_fixture);

    expect(rustDoc.annotation, dartDoc.annotation);
    expect(rustDoc.type, dartDoc.type);
    expect(rustDoc.source, dartDoc.source);
    expect(rustDoc.annotation, isNotNull);
    expect(rustDoc.type, isNotNull);
    expect(rustDoc.source, isNotNull);
  });
}
