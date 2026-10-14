// Regression test: a corrupt EPUB under the `rust` engine must surface a
// [FormatException] — the class the library metadata worker treats as
// "permanently unreadable, mark complete and skip" — exactly like the Dart
// engine. Before the seam normalization the Rust backend threw a bare
// `String` ("Not a valid EPUB file"), which fell through to the worker's
// generic catch, left `metadataComplete == false`, and retried the book on
// every launch.
//
// Genuinely-transient failures (e.g. a missing file) must stay non-`Format`
// so real retries still happen.
import 'dart:io';

import 'package:burrow/services/epub/epub_engine_factory.dart';
import 'package:burrow/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpAll(() async {
    await RustLib.init();
  });

  late Directory dir;
  late String corruptEpub;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('rust_corrupt_epub');
    corruptEpub = '${dir.path}/corrupt.epub';
    // Random bytes: not a ZIP at all, so both engines reject it outright.
    File(corruptEpub).writeAsBytesSync(const [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
  });
  tearDown(() {
    dir.deleteSync(recursive: true);
  });

  test('dart baseline: corrupt EPUB metadata throws FormatException', () async {
    final engine = createEpubEngine(dartEpubEngineId);
    await expectLater(
      engine.extractMetadata(corruptEpub),
      throwsA(isA<FormatException>()),
    );
  });

  test('rust: corrupt EPUB metadata throws FormatException (no retry)', () async {
    final engine = createEpubEngine(rustEpubEngineId);
    await expectLater(
      engine.extractMetadata(corruptEpub),
      throwsA(isA<FormatException>()),
    );
  });

  test('rust: corrupt EPUB parse throws FormatException', () async {
    final engine = createEpubEngine(rustEpubEngineId);
    await expectLater(
      engine.parse(corruptEpub),
      throwsA(isA<FormatException>()),
    );
  });

  test('rust: missing file stays transient (non-FormatException)', () async {
    final engine = createEpubEngine(rustEpubEngineId);
    await expectLater(
      engine.extractMetadata('${dir.path}/missing.epub'),
      throwsA(isNot(isA<FormatException>())),
    );
  });

  test('seam predicate: invalid/too-large are permanent, IO is transient', () {
    expect(
      isRustCorruptEpubFailure('Not a valid EPUB file'),
      isTrue,
    );
    expect(
      isRustCorruptEpubFailure('EPUB file too large (limit 100 MB)'),
      isTrue,
    );
    expect(
      isRustCorruptEpubFailure('Archive decompressed size exceeds 512 MB'),
      isTrue,
    );
    expect(
      isRustCorruptEpubFailure(
        'Cannot open EPUB: No such file or directory (os error 2)',
      ),
      isFalse,
    );
    expect(
      isRustCorruptEpubFailure(const FormatException('Not a valid EPUB file')),
      isFalse,
    );
  });
}
