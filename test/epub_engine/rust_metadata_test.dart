// Golden tests for the Rust OPF metadata path (retire-dart-engine Task 7).
//
// The Dart oracle is retired: `readMetadata` (Rust) is pinned directly
// against committed fixture expectations, so the library metadata path stays
// covered without a cross-engine comparison. `RustLib.init()` dlopens the
// host build from `rust/target/release/`; `test/flutter_test_config.dart`
// builds it on demand.
import 'package:burrow/src/rust/api/epub.dart';
import 'package:burrow/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';

const _fixture = 'test/fixtures/epub/minimal.epub';

void main() {
  setUpAll(() async {
    await RustLib.init();
  });

  test('rust metadata carries the full OPF record', () async {
    final rust = await readMetadata(path: _fixture);

    expect(rust.title, 'Minimal Book');
    expect(rust.author, 'A. Author');
    expect(rust.description, 'A tiny synthetic book for Rust engine tests.');
    expect(rust.publisher, 'Burrow Test Press');
    expect(rust.isbn, '978-0-306-40615-7');
    expect(rust.language, 'en');
    expect(rust.publicationDate, '2026-01-02');
    expect(rust.rights, 'Public Domain');
    expect(rust.genre, 'Fiction, Testing');
    expect(rust.seriesName, 'Burrow Chronicles');
    expect(rust.seriesIndex, 2.0);
    expect(rust.coverBytes, isNotNull);
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
