import 'dart:io';
import 'package:burrow/models/book.dart';
import 'package:burrow/services/library_service.dart';
import 'package:flutter_test/flutter_test.dart';

Book _b(String id, String path) => Book(
      id: id,
      title: id,
      author: '',
      path: path,
      format: BookFormat.epub,
      addedAt: 1000,
    );

void main() {
  test('reconcile flags only truly missing files', () async {
    final dir = await Directory.systemTemp.createTemp('burrow-missing');
    final kept = File('${dir.path}/kept.epub')..writeAsBytesSync([1, 2, 3]);
    final gone = '${dir.path}/gone.epub';
    final lib = LibraryService();
    lib.debugAddAll([_b('k', kept.path), _b('g', gone)]);
    await lib.reconcileMissingFiles();
    expect(lib.isMissing('g'), isTrue);
    expect(lib.isMissing('k'), isFalse);
    expect(lib.storageUnavailable, isFalse);
  });

  test('mass vanish means storage unavailable, not missing', () async {
    final lib = LibraryService();
    lib.debugAddAll([
      _b('a', '/tmp/burrow-nope/a.epub'),
      _b('b', '/tmp/burrow-nope/b.epub'),
    ]);
    await lib.reconcileMissingFiles();
    // Both parents missing + 100% missing -> guard trips.
    expect(lib.storageUnavailable, isTrue);
    expect(lib.missingIds, isEmpty);
  });
}
