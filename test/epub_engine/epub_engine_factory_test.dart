import 'package:burrow/services/epub/epub_engine_factory.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('factory returns the Dart engine for "dart" and throws for unknown', () {
    expect(createEpubEngine('dart'), isA<DartEpubEngine>());
    expect(() => createEpubEngine('nope'), throwsArgumentError);
  });

  test('factory returns the Rust engine for "rust"', () {
    expect(createEpubEngine('rust'), isA<RustEpubEngine>());
  });

  test('rust id falls back to Dart when the native lib is unavailable', () async {
    // Final fix Critical 2: a missing `.so` (e.g. iOS in Phase A) must never
    // brick the EPUB path — the default `rust` id degrades to Dart.
    await withRustAvailability(false, () async {
      expect(createEpubEngine('rust'), isA<DartEpubEngine>());
      expect(createEpubEngine('dart'), isA<DartEpubEngine>());
    });
    // Flag restored: the Rust engine is back once the library loads.
    expect(createEpubEngine('rust'), isA<RustEpubEngine>());
  });
}
