// Metadata-parity test (Task 10, spec criterion 12).
//
// One OPF implementation must serve both library population
// (`EpubEngine.extractMetadata`, used by the library worker and the
// edit-book refetch) and the reader (`EpubEngine.parse`): metadata from the
// two paths must agree. The Rust engine additionally stays total over every
// library format: non-EPUB formats have no OPF, so they are served natively
// by the `extractMetadataTxt/Cbz/Cbr/Pdf` ports rather than failing as
// "not a valid EPUB" (see `non_epub_metadata_test.dart` for the field-by-field
// parity).
import 'dart:io';

import 'package:burrow/services/epub/epub_engine_factory.dart';
import 'package:burrow/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';

const _fixture = 'test/fixtures/epub/minimal.epub';

void main() {
  setUpAll(() async {
    await RustLib.init();
  });

  for (final engineId in [dartEpubEngineId, rustEpubEngineId]) {
    test(
      'library and reader metadata come from one OPF implementation ($engineId)',
      () async {
        final engine = createEpubEngine(engineId);
        final meta = await engine.extractMetadata(_fixture);
        final doc = await engine.parse(_fixture);
        expect(meta.title, doc.title);
        expect(meta.author, doc.author);
      },
    );
  }

  test('rust engine serves non-EPUB metadata natively', () async {
    final engine = createEpubEngine(rustEpubEngineId);
    final dir = await Directory.systemTemp.createTemp('metadata_parity');
    try {
      final txt = File('${dir.path}/notes.txt')
        ..writeAsStringSync('hello');
      final meta = await engine.extractMetadata(txt.path);
      expect(meta.title, 'notes');
      expect(meta.author, isEmpty);
    } finally {
      dir.deleteSync(recursive: true);
    }
  });
}
