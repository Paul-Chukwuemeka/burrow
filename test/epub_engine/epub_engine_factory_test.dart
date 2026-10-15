import 'package:burrow/services/epub/epub_engine_factory.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('factory returns the Rust engine for "rust"', () {
    expect(createEpubEngine('rust'), isA<RustEpubEngine>());
  });

  test('factory rejects the retired "dart" id instead of resolving it', () {
    // The Dart engine is deleted: a stale persisted `dart` flag must fail
    // loudly here (and be normalized to `rust` at load) rather than resolve.
    expect(() => createEpubEngine('dart'), throwsArgumentError);
  });

  test('factory throws for unknown ids', () {
    expect(() => createEpubEngine('nope'), throwsArgumentError);
  });
}
