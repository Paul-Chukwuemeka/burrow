// Parity test for the Rust OPF metadata path (Task 3).
//
// `readMetadata` (Rust) and `DartEpubEngine.extractMetadata` (Dart) must agree
// field by field on the committed synthetic fixture, so Task 10 can migrate the
// library metadata path to Rust without changing observable behaviour (spec
// D14, criterion 12). `RustLib.init()` dlopens the host build from
// `rust/target/release/`; `test/flutter_test_config.dart` builds it on demand.
import 'package:burrow/services/epub/dart_epub_engine.dart';
import 'package:burrow/src/rust/api/epub.dart';
import 'package:burrow/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';

const _fixture = 'test/fixtures/epub/minimal.epub';

void main() {
  setUpAll(() async {
    await RustLib.init();
  });

  test('rust metadata matches the Dart engine field by field', () async {
    final rust = await readMetadata(path: _fixture);
    final dart = await const DartEpubEngine().extractMetadata(_fixture);

    expect(rust.title, dart.title);
    expect(rust.author, dart.author);
    expect(rust.description, dart.description);
    expect(rust.publisher, dart.publisher);
    expect(rust.isbn, dart.isbn);
    expect(rust.language, dart.language);
    expect(rust.publicationDate, dart.publicationDate);
    expect(rust.rights, dart.rights);
    expect(rust.genre, dart.genre);
    expect(rust.seriesName, dart.seriesName);
    expect(rust.seriesIndex, dart.seriesIndex);
    expect(rust.coverBytes, dart.coverBytes);
  });

  test('the opaque handle exposes the same metadata', () async {
    final handle = await openEpub(path: _fixture);
    final viaHandle = await metadata(handle: handle);
    final direct = await readMetadata(path: _fixture);

    // `MetadataDto.==` compares `Uint8List` by identity, so compare the
    // value fields (and cover bytes by content) explicitly.
    expect(viaHandle.title, direct.title);
    expect(viaHandle.author, direct.author);
    expect(viaHandle.seriesName, direct.seriesName);
    expect(viaHandle.seriesIndex, direct.seriesIndex);
    expect(viaHandle.coverBytes, orderedEquals(direct.coverBytes!));
  });

  test('percent-encoded paths parse without throwing', () async {
    final rust = await readMetadata(
      path: 'test/fixtures/epub/percent-path.epub',
    );
    expect(rust.title, 'Percent Paths');
    expect(rust.coverBytes, isNotNull);
  });
}
