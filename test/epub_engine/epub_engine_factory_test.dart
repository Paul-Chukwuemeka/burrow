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
}
