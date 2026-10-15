// Pins that `annotation`/`type`/`source` survive the Rust metadata path
// (retire-dart-engine Task 7).
//
// The parity differ once compared these fields, but no earlier fixture set
// them, so the gate passed vacuously while the Rust DTO dropped them (and the
// library worker overwrote the book's values with null). This test pins the
// fields directly against `annotated-meta.epub` — with non-null expectations
// so it can never pass vacuously again.
import 'package:burrow/services/epub/rust_epub_engine.dart';
import 'package:burrow/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';

const _fixture = 'test/fixtures/epub/annotated-meta.epub';

void main() {
  setUpAll(() async {
    await RustLib.init();
  });

  test('rust metadata keeps annotation/type/source', () async {
    const engine = RustEpubEngine();
    final meta = await engine.extractMetadata(_fixture);

    // Non-null proves the fixture actually covers the fields.
    expect(meta.annotation, 'A Calibre annotation for parity.');
    expect(meta.type, 'Text');
    expect(meta.source, 'https://example.com/annotated-meta');
  });

  test('rust parse keeps annotation/type/source on the document', () async {
    const engine = RustEpubEngine();
    final doc = await engine.parse(_fixture);

    expect(doc.annotation, 'A Calibre annotation for parity.');
    expect(doc.type, 'Text');
    expect(doc.source, 'https://example.com/annotated-meta');
  });
}
