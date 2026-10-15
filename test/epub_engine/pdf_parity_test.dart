// Golden tests for the Rust PDF stub (retire-dart-engine Task 7).
//
// The Dart oracle is retired: the stub contract is pinned directly — PDF is
// not reflowed by any engine (rendering stays in `pdfrx`); the engine returns
// an empty-chapter stub (title from the filename, empty author, one
// `Chapter('', '')`, no cover bytes; metadata is filename title + empty
// author).
//
// Fixture: `test/fixtures/epub/mini.pdf`, a minimal valid one-page PDF.
//
// `RustLib.init()` dlopens the host build from `rust/target/release/`;
// `test/flutter_test_config.dart` builds it on demand.
import 'package:burrow/services/epub/rust_epub_engine.dart';
import 'package:burrow/src/rust/api/epub.dart' as rust;
import 'package:burrow/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';

const _fixture = 'test/fixtures/epub/mini.pdf';

void main() {
  setUpAll(() async {
    await RustLib.init();
  });

  test('Rust PDF FFI returns the empty-chapter stub', () async {
    final chapters = await rust.parsePdf(path: _fixture);
    expect(chapters, hasLength(1));
    expect(chapters.single.title, isEmpty);
    expect(chapters.single.body, isEmpty);
    expect(chapters.single.runs, isEmpty);
    expect(chapters.single.images, isEmpty);
  });

  test('Rust PDF parse is the empty-chapter stub', () async {
    final actual = await const RustEpubEngine().parse(_fixture);

    expect(actual.title, 'mini');
    expect(actual.author, isEmpty);
    expect(actual.chapters, hasLength(1));
    expect(actual.chapters.single.title, isEmpty);
    expect(actual.chapters.single.body, isEmpty);
    expect(actual.chapters.single.runs, isEmpty);
    expect(actual.chapters.single.images, isEmpty);
    expect(actual.coverBytes, isNull);
  });

  test('Rust PDF metadata is the filename title with no cover', () async {
    final actual = await const RustEpubEngine().extractMetadata(_fixture);
    expect(actual.title, 'mini');
    expect(actual.author, isEmpty);
    expect(actual.coverBytes, isNull);
  });
}
