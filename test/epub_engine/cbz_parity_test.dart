// Golden tests for the Rust CBZ parser (retire-dart-engine Task 7).
//
// The Dart oracle is retired: `RustEpubEngine.parse` is pinned directly
// against committed fixture expectations — natural-sorted pages, per-image
// dimensions, first-page cover, and corrupt-archive rejection. The fixture
// archives `page10` before `page2`, so only a natural sort yields
// `page1, page2, page10`.
//
// `RustLib.init()` dlopens the host build from `rust/target/release/`;
// `test/flutter_test_config.dart` builds it on demand.
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:burrow/services/epub/rust_epub_engine.dart';
import 'package:burrow/src/rust/api/epub.dart' as rust;
import 'package:burrow/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';

const _fixture = 'test/fixtures/epub/mini.cbz';

void main() {
  setUpAll(() async {
    await RustLib.init();
  });

  test('Rust CBZ FFI lists pages natural-sorted with dimensions', () async {
    final parsed = await rust.parseCbz(path: _fixture);
    expect(
      parsed.pages.map((p) => p.entryName).toList(),
      ['page1.png', 'page2.png', 'page10.png'],
    );
    expect(
      parsed.pages.map((p) => p.title).toList(),
      ['page1', 'page2', 'page10'],
    );
    expect(
      parsed.pages.map((p) => (p.width, p.height)).toList(),
      [(4, 4), (8, 6), (6, 8)],
    );
    for (final page in parsed.pages) {
      expect(page.imageBytes, isNotEmpty);
    }
    // The cover is the first page's bytes.
    expect(parsed.coverBytes, parsed.pages.first.imageBytes);
  });

  test('Rust CBZ parse yields one full-page image chapter per page', () async {
    final actual = await const RustEpubEngine().parse(_fixture);

    expect(actual.title, 'mini');
    expect(actual.author, isEmpty);
    expect(
      actual.chapters.map((c) => c.title).toList(),
      ['page1', 'page2', 'page10'],
    );
    for (final chapter in actual.chapters) {
      expect(chapter.body, '\uFFFC');
      expect(chapter.images, hasLength(1));
      final image = chapter.images.single;
      expect(image.offset, 0);
      expect(image.bytes, isNotEmpty);
      expect(image.fullWidth, isTrue);
    }
    expect(
      actual.chapters.map((c) => c.title).toList(),
      ['page1', 'page2', 'page10'],
    );
    expect(
      actual.chapters.map((c) => c.images.single.bytes).toList(),
      (await rust.parseCbz(path: _fixture)).pages
          .map((p) => p.imageBytes)
          .toList(),
    );
    expect(actual.coverBytes, actual.chapters.first.images.single.bytes);
  });

  test('Rust CBZ parse rejects corrupt archives as FormatException', () async {
    final tmp = await Directory.systemTemp.createTemp('burrow_cbz_golden');
    addTearDown(() => tmp.deleteSync(recursive: true));

    final garbage = File('${tmp.path}/garbage.cbz')
      ..writeAsBytesSync([1, 2, 3, 4, 5]);
    await expectLater(
      const RustEpubEngine().parse(garbage.path),
      throwsA(isA<FormatException>()),
    );

    // A valid ZIP with no images.
    final archive = Archive();
    archive.addFile(ArchiveFile('notes.txt', 12, 'Not a page.\n'.codeUnits));
    final noImages = File('${tmp.path}/no-images.cbz')
      ..writeAsBytesSync(ZipEncoder().encode(archive));
    await expectLater(
      const RustEpubEngine().parse(noImages.path),
      throwsA(isA<FormatException>()),
    );
  });
}
