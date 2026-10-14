// Reversal test (Task 11): the engine flag stays reversible after the
// default flips to `rust`. `createEpubEngine('dart')` must keep working with
// no revert — the Dart engine remains a usable fallback behind the flag.
import 'dart:io';

import 'package:burrow/services/document_parser.dart';
import 'package:burrow/services/epub/epub_engine_factory.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('switching back to dart needs no revert', () async {
    final engine = createEpubEngine('dart');
    expect(
      await engine.parse('test/fixtures/epub/minimal.epub'),
      isA<ParsedDocument>(),
    );
  });

  test('rust engine falls back to Dart for non-EPUB books', () async {
    // The reader opens every reflowable format through the engine seam, so a
    // TXT book must parse under the `rust` default without touching FFI.
    final tmp = await Directory.systemTemp.createTemp('burrow_engine_txt');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final book = File('${tmp.path}/notes.txt');
    await book.writeAsString('Hello.\n\nSecond paragraph.\n');
    final doc = await createEpubEngine('rust').parse(book.path);
    expect(doc.chapters, isNotEmpty);
    expect(doc.chapters.first.body, contains('Hello.'));
  });
}
