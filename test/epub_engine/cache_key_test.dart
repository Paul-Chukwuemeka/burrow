import 'package:burrow/services/epub/epub_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('cache key is namespaced by engine', () {
    expect(
      cacheKeyFor('/b.epub', engineId: 'dart'),
      isNot(cacheKeyFor('/b.epub', engineId: 'rust')),
    );
  });

  test('cache key is stable for the same path and engine', () {
    expect(
      cacheKeyFor('/b.epub', engineId: 'dart'),
      cacheKeyFor('/b.epub', engineId: 'dart'),
    );
  });
}
