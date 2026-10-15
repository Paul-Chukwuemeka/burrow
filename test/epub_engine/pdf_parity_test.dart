// Parity test for the Rust PDF stub (retire-dart-engine Task 4).
//
// PDF is not reflowed by either engine — rendering stays in `pdfrx`. The Dart
// isolate's PDF branch (`DocumentParser._parseIsolate`, the `pdf` case)
// returns an empty-chapter stub (title from the filename, empty author, one
// `Chapter('', '')`, no cover bytes; metadata is filename title + empty
// author). The Rust engine must produce the same stub over FFI (`parsePdf`)
// so `BookFormat.pdf` can route to Rust.
//
// Fixture: `test/fixtures/epub/mini.pdf`, a minimal valid one-page PDF
// (590 bytes, `%PDF-1.4`, correct xref, single "Hello, Burrow!" page —
// verified with pypdf). Neither engine reads the PDF bytes on the parse path,
// so any valid PDF pins the stub contract.
//
// `RustLib.init()` dlopens the host build from `rust/target/release/`;
// `test/flutter_test_config.dart` builds it on demand.
import 'package:burrow/services/epub/dart_epub_engine.dart';
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

  test('Rust PDF parse matches the Dart engine stub', () async {
    final dart = await const DartEpubEngine().parse(_fixture);
    final actual = await const RustEpubEngine().parse(_fixture);

    // The Dart stub itself: one empty chapter, filename title, no cover.
    expect(dart.chapters, hasLength(1));
    expect(dart.chapters.single.title, isEmpty);
    expect(dart.chapters.single.body, isEmpty);

    expect(actual.title, dart.title);
    expect(actual.author, dart.author);
    expect(actual.chapters, hasLength(dart.chapters.length));
    for (var i = 0; i < dart.chapters.length; i++) {
      expect(actual.chapters[i].title, dart.chapters[i].title);
      expect(actual.chapters[i].body, dart.chapters[i].body);
      expect(actual.chapters[i].runs, dart.chapters[i].runs);
      expect(
        actual.chapters[i].images,
        hasLength(dart.chapters[i].images.length),
      );
    }
    expect(actual.coverBytes, dart.coverBytes);
  });

  test('Rust PDF metadata matches the Dart engine', () async {
    final dart = await const DartEpubEngine().extractMetadata(_fixture);
    final actual = await const RustEpubEngine().extractMetadata(_fixture);
    expect(actual.title, dart.title);
    expect(actual.author, dart.author);
    expect(actual.coverBytes, dart.coverBytes);
  });
}
