// Non-EPUB metadata goldens (retire-dart-engine Task 7).
//
// The Dart oracle is retired: `RustEpubEngine.extractMetadata` is pinned
// directly against committed fixture expectations for every non-EPUB format
// (TXT/CBZ/CBR/PDF) — filename-derived title, first-page comic cover,
// deferred CBR cover.
//
// Each case also calls the raw Rust metadata function and pins its
// title/series/cover, so the suite exercises the FFI path directly.
//
// `RustLib.init()` dlopens the host build from `rust/target/release/`;
// `test/flutter_test_config.dart` builds it on demand.
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:burrow/services/epub/rust_epub_engine.dart';
import 'package:burrow/src/rust/api/epub.dart' as rust;
import 'package:burrow/src/rust/frb_generated.dart';
import 'package:burrow/utils/cover_prep.dart';
import 'package:flutter_test/flutter_test.dart';

const _txtFixtures = [
  'test/fixtures/epub/plain.txt',
  'test/fixtures/epub/chapters.txt',
  'test/fixtures/epub/latin1-bom.txt',
];
const _cbzFixture = 'test/fixtures/epub/mini.cbz';
const _cbrFixture = 'test/fixtures/epub/mini.cbr';
const _pdfFixture = 'test/fixtures/epub/mini.pdf';

void main() {
  setUpAll(() async {
    await RustLib.init();
  });

  for (final path in _txtFixtures) {
    test('Rust TXT metadata for $path', () async {
      final actual = await const RustEpubEngine().extractMetadata(path);
      final stem = path.split('/').last.split('.').first;

      expect(actual.title, stem);
      expect(actual.author, isEmpty);
      expect(actual.coverBytes, isNull);
      expect(actual.seriesName, isNull);
      expect(actual.seriesIndex, isNull);

      // The FFI path itself: the raw Rust DTO carries the same
      // filename-derived title and empty author, with no cover and no series.
      final raw = await rust.extractMetadataTxt(path: path);
      expect(raw.title, stem, reason: 'FFI title for $path');
      expect(raw.author, isEmpty, reason: 'FFI author for $path');
      expect(raw.coverBytes, isNull, reason: 'FFI cover for $path');
      expect(raw.seriesName, isNull, reason: 'FFI seriesName for $path');
      expect(raw.seriesIndex, isNull, reason: 'FFI seriesIndex for $path');
    });
  }

  test('Rust CBZ metadata carries the first page as cover', () async {
    const path = _cbzFixture;
    final actual = await const RustEpubEngine().extractMetadata(path);

    expect(actual.title, 'mini');
    expect(actual.author, isEmpty);
    expect(actual.coverBytes, isNotNull);

    // The FFI path itself: raw Rust cover is the first page's bytes (the
    // engine downscales it on the metadata path).
    final raw = await rust.extractMetadataCbz(path: path);
    expect(raw.title, 'mini', reason: 'FFI title');
    expect(raw.author, isEmpty, reason: 'FFI author');
    expect(raw.coverBytes, isNotNull, reason: 'FFI cover present');
    final downscaled = prepareCover(raw.coverBytes);
    expect(
      actual.coverBytes,
      orderedEquals(downscaled!),
      reason: 'engine cover is the downscaled FFI cover',
    );
  });

  test('Rust CBR metadata defers the cover', () async {
    const path = _cbrFixture;
    final actual = await const RustEpubEngine().extractMetadata(path);

    expect(actual.title, 'mini');
    expect(actual.author, isEmpty);
    expect(actual.coverBytes, isNull);

    // The FFI path itself: like the parse path, the CBR cover is deferred
    // (null) and only the filename-derived title crosses the boundary.
    final raw = await rust.extractMetadataCbr(path: path);
    expect(raw.title, 'mini', reason: 'FFI title');
    expect(raw.author, isEmpty, reason: 'FFI author');
    expect(raw.coverBytes, isNull, reason: 'FFI cover deferred');
  });

  test('Rust PDF metadata is the filename title with no cover', () async {
    const path = _pdfFixture;
    final actual = await const RustEpubEngine().extractMetadata(path);

    expect(actual.title, 'mini');
    expect(actual.author, isEmpty);
    expect(actual.coverBytes, isNull);

    // The FFI path itself: filename title, empty author, no cover.
    final raw = await rust.extractMetadataPdf(path: path);
    expect(raw.title, 'mini', reason: 'FFI title');
    expect(raw.author, isEmpty, reason: 'FFI author');
    expect(raw.coverBytes, isNull, reason: 'FFI cover');
  });

  test('Rust comic metadata infers series from the filename', () async {
    final tmp = await Directory.systemTemp.createTemp('burrow_meta_7');
    addTearDown(() => tmp.deleteSync(recursive: true));

    // Same archive bytes as the fixture, renamed so `parseComicSeries` finds
    // ("Saga", 54): the engine and the raw FFI DTOs must agree.
    final cbzBytes = File(_cbzFixture).readAsBytesSync();
    final renamed = File('${tmp.path}/Saga #054.cbz')
      ..writeAsBytesSync(cbzBytes);
    final actual = await const RustEpubEngine().extractMetadata(renamed.path);
    expect(actual.title, 'Saga #054');
    expect(actual.seriesName, 'Saga');
    expect(actual.seriesIndex, 54);
    final raw = await rust.extractMetadataCbz(path: renamed.path);
    expect(raw.seriesName, 'Saga', reason: 'FFI seriesName');
    expect(raw.seriesIndex, 54, reason: 'FFI seriesIndex');
    expect(raw.title, 'Saga #054', reason: 'FFI title');

    final renamedCbr = File('${tmp.path}/Saga #054.cbr')
      ..writeAsBytesSync(File(_cbrFixture).readAsBytesSync());
    final actualCbr = await const RustEpubEngine().extractMetadata(
      renamedCbr.path,
    );
    expect(actualCbr.seriesName, 'Saga');
    expect(actualCbr.seriesIndex, 54);
    final rawCbr = await rust.extractMetadataCbr(path: renamedCbr.path);
    expect(rawCbr.seriesName, 'Saga', reason: 'FFI CBR seriesName');
    expect(rawCbr.seriesIndex, 54, reason: 'FFI CBR seriesIndex');
  });

  test('Rust CBZ metadata rejects corrupt archives as FormatException',
      () async {
    final tmp = await Directory.systemTemp.createTemp('burrow_meta_7_bad');
    addTearDown(() => tmp.deleteSync(recursive: true));

    final garbage = File('${tmp.path}/garbage.cbz')
      ..writeAsBytesSync([1, 2, 3, 4, 5]);
    await expectLater(
      const RustEpubEngine().extractMetadata(garbage.path),
      throwsA(isA<FormatException>()),
    );

    final archive = Archive();
    archive.addFile(ArchiveFile('notes.txt', 12, 'Not a page.\n'.codeUnits));
    final noImages = File('${tmp.path}/no-images.cbz')
      ..writeAsBytesSync(ZipEncoder().encode(archive));
    await expectLater(
      const RustEpubEngine().extractMetadata(noImages.path),
      throwsA(isA<FormatException>()),
    );
  });
}
