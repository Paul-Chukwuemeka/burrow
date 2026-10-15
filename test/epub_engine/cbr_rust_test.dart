// Rust CBR parser tests (retire-dart-engine Task 3).
//
// For the committed `mini.cbr` fixture (authored with `rars`' own writer by
// `rust/examples/build_cbr_fixture.rs` — no local RAR encoder exists),
// `RustEpubEngine.parse` (via the FFI `parseCbr` port of
// `DocumentParser._parseComicBook`'s CBR branch) must list pages
// natural-sorted with intrinsic dimensions and the first page's bytes as the
// cover. The fixture archives `page10` before `page2`, so only a natural
// sort yields `page1, page2, page10` (Review Focus #3).
//
// There is deliberately NO Dart-vs-Rust parity test here: the Dart `rar`
// plugin resolves to a `MethodChannel` off Android, which has no binding on
// the host, so `DartEpubEngine` cannot open a valid CBR under `flutter test`.
// Parity against an externally-produced CBR (and a device run with a
// user-supplied CBR) remains an open coverage gap — see the Task 3 report.
//
// `RustLib.init()` dlopens the host build from `rust/target/release/`;
// `test/flutter_test_config.dart` builds it on demand.
import 'dart:io';

import 'package:burrow/services/epub/rust_epub_engine.dart';
import 'package:burrow/src/rust/api/epub.dart' as rust;
import 'package:burrow/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';

const _fixture = 'test/fixtures/epub/mini.cbr';

void main() {
  setUpAll(() async {
    await RustLib.init();
  });

  test('Rust CBR FFI lists pages natural-sorted with dimensions', () async {
    final parsed = await rust.parseCbr(path: _fixture);
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

  test('Rust CBR engine parse yields one full-page image chapter per page',
      () async {
    final actual = await const RustEpubEngine().parse(_fixture);
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
      actual.chapters.map((c) => c.images.single.bytes).toList(),
      (await rust.parseCbr(path: _fixture)).pages
          .map((p) => p.imageBytes)
          .toList(),
    );
    expect(actual.coverBytes, actual.chapters.first.images.single.bytes);
  });

  test('Rust CBR parse rejects corrupt archives as FormatException',
      () async {
    final tmp = await Directory.systemTemp.createTemp('burrow_cbr_rust');
    addTearDown(() => tmp.deleteSync(recursive: true));

    final garbage = File('${tmp.path}/garbage.cbr')
      ..writeAsBytesSync([1, 2, 3, 4, 5]);
    await expectLater(
      const RustEpubEngine().parse(garbage.path),
      throwsA(isA<FormatException>()),
    );

    // An empty file is not a RAR archive at all.
    final empty = File('${tmp.path}/empty.cbr')..writeAsBytesSync([]);
    await expectLater(
      const RustEpubEngine().parse(empty.path),
      throwsA(isA<FormatException>()),
    );
  });
}
