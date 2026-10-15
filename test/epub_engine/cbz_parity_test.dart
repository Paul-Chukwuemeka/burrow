// Parity test for the Rust CBZ parser (retire-dart-engine Task 2).
//
// For the committed `mini.cbz` fixture, `RustEpubEngine.parse` (via the FFI
// `parseCbz` port of `DocumentParser._parseComicBook`'s CBZ branch) must equal
// `DartEpubEngine.parse` on title, chapter count, page order, per-image
// intrinsic dimensions, and cover bytes. The fixture archives `page10` before
// `page2`, so only a natural sort yields `page1, page2, page10` (Review
// Focus #3).
//
// `RustLib.init()` dlopens the host build from `rust/target/release/`;
// `test/flutter_test_config.dart` builds it on demand.
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:burrow/services/epub/dart_epub_engine.dart';
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

  test('Rust CBZ parse matches the Dart engine', () async {
    final dart = await const DartEpubEngine().parse(_fixture);
    final actual = await const RustEpubEngine().parse(_fixture);

    expect(actual.title, dart.title);
    expect(actual.author, dart.author);
    expect(actual.chapters, hasLength(dart.chapters.length));

    for (var i = 0; i < dart.chapters.length; i++) {
      final expected = dart.chapters[i];
      final chapter = actual.chapters[i];
      expect(chapter.title, expected.title, reason: 'chapter $i title');
      expect(chapter.body, expected.body, reason: 'chapter $i body');
      expect(
        chapter.images,
        hasLength(expected.images.length),
        reason: 'chapter $i images',
      );
      for (var j = 0; j < expected.images.length; j++) {
        final want = expected.images[j];
        final got = chapter.images[j];
        expect(got.offset, want.offset, reason: 'chapter $i image $j offset');
        expect(got.bytes, want.bytes, reason: 'chapter $i image $j bytes');
        expect(
          got.intrinsicWidth,
          want.intrinsicWidth,
          reason: 'chapter $i image $j width',
        );
        expect(
          got.intrinsicHeight,
          want.intrinsicHeight,
          reason: 'chapter $i image $j height',
        );
        expect(
          got.fullWidth,
          want.fullWidth,
          reason: 'chapter $i image $j fullWidth',
        );
      }
    }

    expect(actual.coverBytes, dart.coverBytes);
  });

  test('page2 sorts before page10 (natural sort)', () async {
    final actual = await const RustEpubEngine().parse(_fixture);
    expect(
      actual.chapters.map((c) => c.title).toList(),
      ['page1', 'page2', 'page10'],
    );
  });

  test('Rust CBZ parse rejects corrupt archives like the Dart engine',
      () async {
    final tmp = await Directory.systemTemp.createTemp('burrow_cbz_parity');
    addTearDown(() => tmp.deleteSync(recursive: true));

    final garbage = File('${tmp.path}/garbage.cbz')
      ..writeAsBytesSync([1, 2, 3, 4, 5]);
    await expectLater(
      const RustEpubEngine().parse(garbage.path),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      const DartEpubEngine().parse(garbage.path),
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
    await expectLater(
      const DartEpubEngine().parse(noImages.path),
      throwsA(isA<FormatException>()),
    );
  });
}
