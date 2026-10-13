import 'package:burrow/services/epub/epub_engine_factory.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('factory returns the Dart engine for "dart" and throws for unknown', () {
    expect(createEpubEngine('dart'), isA<DartEpubEngine>());
    expect(() => createEpubEngine('nope'), throwsArgumentError);
  });

  test('rust is registered as a stub that is not yet implemented', () async {
    final engine = createEpubEngine('rust');
    await expectLater(engine.parse('/tmp/book.epub'), throwsUnimplementedError);
    await expectLater(
      engine.extractMetadata('/tmp/book.epub'),
      throwsUnimplementedError,
    );
    expect(
      () => engine.clearCacheFor('/tmp/book.epub'),
      throwsUnimplementedError,
    );
  });
}
