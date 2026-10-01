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

  test('importFileFast auto relinks moved file', () async {
    final dir = await Directory.systemTemp.createTemp('burrow-relink');
    final f = File('${dir.path}/moved.epub')..writeAsBytesSync([9, 9, 9]);
    final st = await f.stat();
    final lib = LibraryService();
    // Old ghost entry with same fingerprint, different path.
    lib.debugAddAll([
      Book(id: 'ghost', title: 'G', author: '', path: '${dir.path}/old.epub', format: BookFormat.epub, addedAt: 1, fileSize: st.size, mtimeMs: st.modified.millisecondsSinceEpoch),
    ]);
    await lib.reconcileMissingFiles();
    expect(lib.isMissing('ghost'), isTrue);
    final result = await lib.importFileFast(f.path);
    expect(result?.id, 'ghost');
    expect(lib.isMissing('ghost'), isFalse);
    expect(lib.bookById('ghost')?.path, f.path);
  });

  test('removeAllMissing drops ghosts and keeps progress of rest', () async {
    final lib = LibraryService();
    lib.debugAddAll([_b('g1', '/tmp/burrow-nope/x.epub'), _b('k1', '/tmp/burrow-nope/y.epub')]);
    // Force missing without storage guard tripping: single file case tested elsewhere;
    // here call remove directly after manual mark.
    lib.debugMarkMissing('g1');
    final n = await lib.removeAllMissing();
    expect(n, 1);
    expect(lib.bookById('g1'), isNull);
    expect(lib.bookById('k1'), isNotNull);
  });
}
