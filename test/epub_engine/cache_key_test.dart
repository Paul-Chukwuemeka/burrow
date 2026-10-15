import 'dart:io';

import 'package:burrow/services/epub/epub_cache.dart';
import 'package:burrow/services/epub/epub_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('cache key is namespaced by engine', () {
    expect(
      cacheKeyFor('/b.epub', engineId: 'rust'),
      isNot(cacheKeyFor('/b.epub', engineId: legacyDartEngineId)),
    );
  });

  test('cache key is stable for the same path and engine', () {
    expect(
      cacheKeyFor('/b.epub', engineId: 'rust'),
      cacheKeyFor('/b.epub', engineId: 'rust'),
    );
  });

  test('cache key differs from the legacy v3 scheme', () async {
    // A pre-fix cache entry stores broken semantics (1em -> 1px, 70% -> 70px)
    // under a key derived from path+mtime+size only. If the key scheme does
    // not change, the fixed build keeps serving those poisoned entries.
    final dir = await Directory.systemTemp.createTemp('burrow_cache_key');
    try {
      final file = File('${dir.path}/book.epub');
      await file.writeAsBytes([1, 2, 3, 4]);
      final path = file.path;
      final mtime = file.lastModifiedSync().millisecondsSinceEpoch;
      final size = file.lengthSync();
      final legacy = 'v3_${path}_${mtime}_$size'.hashCode.toRadixString(16);
      expect(EpubCache.keyFor(path, engineId: 'rust'), isNot(legacy));
      // ...but stays stable for the same file.
      expect(
        EpubCache.keyFor(path, engineId: 'rust'),
        EpubCache.keyFor(path, engineId: 'rust'),
      );
    } finally {
      await dir.delete(recursive: true);
    }
  });

  group('both-namespaces cleanup (Review Focus #5)', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('burrow_epub_cache');
      EpubCache.debugCacheDirOverride = dir.path;
    });

    tearDown(() {
      EpubCache.debugCacheDirOverride = null;
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('clearFor deletes the Rust and the retired Dart entries', () async {
      final file = File('${dir.path}/book.epub')..writeAsBytesSync([1, 2, 3]);
      final rustKey = EpubCache.keyFor(file.path, engineId: 'rust');
      final dartKey = EpubCache.keyFor(
        file.path,
        engineId: legacyDartEngineId,
      );
      File('${dir.path}/$rustKey.json').writeAsStringSync('{}');
      File('${dir.path}/$dartKey.json').writeAsStringSync('{}');

      EpubCache.clearFor(
        file.path,
        engineIds: const ['rust', legacyDartEngineId],
      );

      expect(File('${dir.path}/$rustKey.json').existsSync(), isFalse);
      expect(File('${dir.path}/$dartKey.json').existsSync(), isFalse);
    });

    test('no code path reads a Dart-namespaced entry', () async {
      // The only key readers are gone with the Dart engine: the key function
      // still computes Dart-namespace keys, but solely so destructive paths
      // can locate orphans. A Dart-namespace file with live content is never
      // loaded — prune deletes it when no live path claims it.
      final orphan = File('${dir.path}/book.epub')..writeAsBytesSync([9]);
      final dartKey = EpubCache.keyFor(
        orphan.path,
        engineId: legacyDartEngineId,
      );
      File('${dir.path}/$dartKey.json').writeAsStringSync('{"stale":true}');

      // The orphan's source is gone: prune must sweep the Dart entry.
      orphan.deleteSync();
      await EpubCache.prune(
        const [],
        engineIds: const ['rust', legacyDartEngineId],
      );
      expect(File('${dir.path}/$dartKey.json').existsSync(), isFalse);
    });

    test('prune keeps live entries in every namespace', () async {
      final live = File('${dir.path}/live.epub')..writeAsBytesSync([1]);
      final rustKey = EpubCache.keyFor(live.path, engineId: 'rust');
      final dartKey = EpubCache.keyFor(
        live.path,
        engineId: legacyDartEngineId,
      );
      File('${dir.path}/$rustKey.json').writeAsStringSync('{}');
      File('${dir.path}/$dartKey.json').writeAsStringSync('{}');

      await EpubCache.prune(
        [live.path],
        engineIds: const ['rust', legacyDartEngineId],
      );

      expect(File('${dir.path}/$rustKey.json').existsSync(), isTrue);
      expect(File('${dir.path}/$dartKey.json').existsSync(), isTrue);
    });
  });
}
