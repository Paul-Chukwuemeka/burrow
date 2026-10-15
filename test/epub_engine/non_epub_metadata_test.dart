// Non-EPUB metadata parity (retire-dart-engine Task 4b).
//
// For every non-EPUB fixture (TXT/CBZ/CBR/PDF), `RustEpubEngine.extractMetadata`
// (via the FFI `extractMetadataTxt/Cbz/Cbr/Pdf` ports of
// `DocumentParser._extractMetadataIsolate`'s per-format branches) must equal
// `DartEpubEngine.extractMetadata` on every `ParsedMetadata` field.
//
// The test exercises the FFI path directly: each case also calls the raw Rust
// metadata function and pins its title/series/cover, so the suite cannot pass
// by Dart-vs-Dart delegation (the pre-Task-4b engine delegated non-EPUB
// metadata to `DocumentParser`, and these FFI functions did not exist).
//
// `RustLib.init()` dlopens the host build from `rust/target/release/`;
// `test/flutter_test_config.dart` builds it on demand.
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:burrow/services/document_parser.dart';
import 'package:burrow/services/epub/dart_epub_engine.dart';
import 'package:burrow/services/epub/rust_epub_engine.dart';
import 'package:burrow/src/rust/api/epub.dart' as rust;
import 'package:burrow/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';

const _txtFixtures = [
  'test/fixtures/epub/plain.txt',
  'test/fixtures/epub/chapters.txt',
  'test/fixtures/epub/latin1-bom.txt',
];
const _cbzFixture = 'test/fixtures/epub/mini.cbz';
const _cbrFixture = 'test/fixtures/epub/mini.cbr';
const _pdfFixture = 'test/fixtures/epub/mini.pdf';

/// Every `ParsedMetadata` field must agree between the two engines.
void _expectSameMetadata(
  ParsedMetadata actual,
  ParsedMetadata expected,
  String reason,
) {
  expect(actual.title, expected.title, reason: '$reason title');
  expect(actual.author, expected.author, reason: '$reason author');
  expect(
    actual.description,
    expected.description,
    reason: '$reason description',
  );
  expect(
    actual.annotation,
    expected.annotation,
    reason: '$reason annotation',
  );
  expect(actual.genre, expected.genre, reason: '$reason genre');
  expect(
    actual.seriesName,
    expected.seriesName,
    reason: '$reason seriesName',
  );
  expect(
    actual.seriesIndex,
    expected.seriesIndex,
    reason: '$reason seriesIndex',
  );
  expect(actual.publisher, expected.publisher, reason: '$reason publisher');
  expect(actual.isbn, expected.isbn, reason: '$reason isbn');
  expect(actual.language, expected.language, reason: '$reason language');
  expect(
    actual.publicationDate,
    expected.publicationDate,
    reason: '$reason publicationDate',
  );
  expect(actual.rights, expected.rights, reason: '$reason rights');
  expect(actual.type, expected.type, reason: '$reason type');
  expect(actual.source, expected.source, reason: '$reason source');
  expect(actual.titleSort, expected.titleSort, reason: '$reason titleSort');
  expect(actual.authorSort, expected.authorSort, reason: '$reason authorSort');
  if (expected.coverBytes == null) {
    expect(actual.coverBytes, isNull, reason: '$reason coverBytes');
  } else {
    expect(
      actual.coverBytes,
      orderedEquals(expected.coverBytes!),
      reason: '$reason coverBytes',
    );
  }
}

void main() {
  setUpAll(() async {
    await RustLib.init();
  });

  for (final path in _txtFixtures) {
    test('Rust TXT metadata matches the Dart engine for $path', () async {
      final dart = await const DartEpubEngine().extractMetadata(path);
      final actual = await const RustEpubEngine().extractMetadata(path);
      _expectSameMetadata(actual, dart, path);

      // The FFI path itself: the raw Rust DTO carries the same filename-derived
      // title and empty author, with no cover and no series.
      final raw = await rust.extractMetadataTxt(path: path);
      expect(raw.title, dart.title, reason: 'FFI title for $path');
      expect(raw.author, isEmpty, reason: 'FFI author for $path');
      expect(raw.coverBytes, isNull, reason: 'FFI cover for $path');
      expect(raw.seriesName, isNull, reason: 'FFI seriesName for $path');
      expect(raw.seriesIndex, isNull, reason: 'FFI seriesIndex for $path');
    });
  }

  test('Rust CBZ metadata matches the Dart engine', () async {
    const path = _cbzFixture;
    final dart = await const DartEpubEngine().extractMetadata(path);
    final actual = await const RustEpubEngine().extractMetadata(path);
    _expectSameMetadata(actual, dart, path);

    // The FFI path itself: raw Rust cover is the first page's bytes (the Dart
    // adapter downscales it, exactly like the Dart engine's metadata path).
    final raw = await rust.extractMetadataCbz(path: path);
    expect(raw.title, dart.title, reason: 'FFI title');
    expect(raw.author, isEmpty, reason: 'FFI author');
    expect(raw.seriesName, dart.seriesName, reason: 'FFI seriesName');
    expect(raw.seriesIndex, dart.seriesIndex, reason: 'FFI seriesIndex');
    expect(raw.coverBytes, isNotNull, reason: 'FFI cover present');
    final downscaled = DocumentParser.prepareCover(raw.coverBytes);
    expect(
      actual.coverBytes,
      orderedEquals(downscaled!),
      reason: 'engine cover is the downscaled FFI cover',
    );
  });

  test('Rust CBR metadata matches the Dart engine', () async {
    const path = _cbrFixture;
    final dart = await const DartEpubEngine().extractMetadata(path);
    final actual = await const RustEpubEngine().extractMetadata(path);
    _expectSameMetadata(actual, dart, path);

    // The FFI path itself: like Dart, the CBR cover is deferred (null) and only
    // the filename-derived title/series cross the boundary.
    final raw = await rust.extractMetadataCbr(path: path);
    expect(raw.title, dart.title, reason: 'FFI title');
    expect(raw.author, isEmpty, reason: 'FFI author');
    expect(raw.seriesName, dart.seriesName, reason: 'FFI seriesName');
    expect(raw.seriesIndex, dart.seriesIndex, reason: 'FFI seriesIndex');
    expect(raw.coverBytes, isNull, reason: 'FFI cover deferred like Dart');
  });

  test('Rust PDF metadata matches the Dart engine', () async {
    const path = _pdfFixture;
    final dart = await const DartEpubEngine().extractMetadata(path);
    final actual = await const RustEpubEngine().extractMetadata(path);
    _expectSameMetadata(actual, dart, path);

    // The FFI path itself: filename title, empty author, no cover.
    final raw = await rust.extractMetadataPdf(path: path);
    expect(raw.title, dart.title, reason: 'FFI title');
    expect(raw.author, isEmpty, reason: 'FFI author');
    expect(raw.coverBytes, isNull, reason: 'FFI cover');
  });

  test('Rust comic metadata infers series from the filename', () async {
    final tmp = await Directory.systemTemp.createTemp('burrow_meta_4b');
    addTearDown(() => tmp.deleteSync(recursive: true));

    // Same archive bytes as the fixture, renamed so `parseComicSeries` finds
    // ("Saga", 54): both engines and the raw FFI DTOs must agree.
    final cbzBytes = File(_cbzFixture).readAsBytesSync();
    final renamed = File('${tmp.path}/Saga #054.cbz')
      ..writeAsBytesSync(cbzBytes);
    final dart = await const DartEpubEngine().extractMetadata(renamed.path);
    final actual = await const RustEpubEngine().extractMetadata(renamed.path);
    _expectSameMetadata(actual, dart, renamed.path);
    expect(dart.seriesName, 'Saga');
    expect(dart.seriesIndex, 54);
    final raw = await rust.extractMetadataCbz(path: renamed.path);
    expect(raw.seriesName, 'Saga', reason: 'FFI seriesName');
    expect(raw.seriesIndex, 54, reason: 'FFI seriesIndex');
    expect(raw.title, dart.title, reason: 'FFI title');

    final renamedCbr = File('${tmp.path}/Saga #054.cbr')
      ..writeAsBytesSync(File(_cbrFixture).readAsBytesSync());
    final dartCbr = await const DartEpubEngine().extractMetadata(
      renamedCbr.path,
    );
    final actualCbr = await const RustEpubEngine().extractMetadata(
      renamedCbr.path,
    );
    _expectSameMetadata(actualCbr, dartCbr, renamedCbr.path);
    final rawCbr = await rust.extractMetadataCbr(path: renamedCbr.path);
    expect(rawCbr.seriesName, 'Saga', reason: 'FFI CBR seriesName');
    expect(rawCbr.seriesIndex, 54, reason: 'FFI CBR seriesIndex');
  });

  test('Rust CBZ metadata rejects corrupt archives like the Dart engine',
      () async {
    final tmp = await Directory.systemTemp.createTemp('burrow_meta_4b_bad');
    addTearDown(() => tmp.deleteSync(recursive: true));

    final garbage = File('${tmp.path}/garbage.cbz')
      ..writeAsBytesSync([1, 2, 3, 4, 5]);
    await expectLater(
      const RustEpubEngine().extractMetadata(garbage.path),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      const DartEpubEngine().extractMetadata(garbage.path),
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
    await expectLater(
      const DartEpubEngine().extractMetadata(noImages.path),
      throwsA(isA<FormatException>()),
    );
  });
}
