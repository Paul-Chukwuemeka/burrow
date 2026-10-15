import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Disk-cache helpers for parsed documents (retire-dart-engine Task 7).
///
/// Moved out of the retired Dart parser: the key scheme, the sync
/// best-effort deletes, and the background prune are engine-agnostic file
/// operations now shared by the single remaining (Rust) engine.
///
/// The Rust engine writes no cache entries of its own. These helpers exist so
/// delete/relink/prune can still locate and remove orphaned entries left by
/// the retired Dart engine: every destructive path clears **both** engine
/// namespaces ([legacyDartEngineId] plus the caller's engine id), so switching
/// or deleting can never leak the other namespace's entries. No code path
/// *reads* a Dart-namespaced entry anymore — the keys survive only for
/// deletion.
///
/// Keys fold in path + mtime + size alongside the engine id and the schema
/// tag, so a stale entry can never serve wrong content.
abstract final class EpubCache {
  /// Schema tag for the on-disk parsed-document cache. Bump whenever the
  /// cached *meaning* changes, not just its shape: v4 invalidates entries
  /// written before CSS declaration values kept their units (pre-fix caches
  /// store e.g. `font-size:1em` as 1px and `70%` as 70px).
  static const schemaTag = 'v4';

  /// Memoized cache dir (see [_resolveCacheDirPath]). Lets selection-speed
  /// paths clear entries without awaiting async disk IO (which never
  /// completes inside a testWidgets FakeAsync zone).
  static String? _cacheDirPathCache;

  /// Test-only override for the cache directory, so tests can point the
  /// helpers at a temp dir without touching the platform channel.
  @visibleForTesting
  static String? debugCacheDirOverride;

  /// Resolves (and creates) the cache directory, or throws when the platform
  /// directory is unavailable. Must be called on the main isolate.
  static Future<String> _resolveCacheDirPath() async {
    final override = debugCacheDirOverride;
    if (override != null) {
      final dir = Directory(override);
      if (!dir.existsSync()) await dir.create(recursive: true);
      return _cacheDirPathCache = dir.path;
    }
    final tmp = await getTemporaryDirectory();
    final dir = Directory('${tmp.path}/burrow_doc_cache');
    if (!dir.existsSync()) await dir.create(recursive: true);
    return _cacheDirPathCache = dir.path;
  }

  /// Main-isolate-safe resolver: returns null when the cache directory cannot
  /// be resolved (e.g. the platform channel is unavailable).
  static Future<String?> _safeCacheDirPath() async {
    try {
      return await _resolveCacheDirPath();
    } catch (_) {
      return null;
    }
  }

  /// Disk-cache key for [path] as seen by [engineId].
  ///
  /// Missing/unreadable sources yield a stable key rather than throwing, which
  /// is what the legacy internal callers relied on (they wrapped the private
  /// key function in try/catch).
  static String keyFor(String path, {required String engineId}) {
    var mtime = 0;
    var size = 0;
    try {
      final file = File(path);
      mtime = file.lastModifiedSync().millisecondsSinceEpoch;
      size = file.lengthSync();
    } catch (_) {
      // Missing or unreadable source: fold in zeroes so callers still get a
      // stable, engine-namespaced key instead of an exception.
    }
    // Bump the schema tag when the cached shape changes so stale entries from
    // an older format are ignored instead of deserialized with missing fields.
    // v3: images/fonts store archive entry names instead of base64 bytes.
    // v4: CSS values keep their units (see schemaTag).
    final id = '${schemaTag}_${engineId}_${path}_${mtime}_$size';
    // 32-bit hashCode is sufficient for cache keys; collisions fall through
    // to a full parse and the stale entry is harmless.
    return id.hashCode.toRadixString(16);
  }

  static void _deleteCacheFile(
    String path,
    String cacheDirPath,
    String engineId,
  ) {
    try {
      final key = keyFor(path, engineId: engineId);
      final file = File('$cacheDirPath/$key.json');
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
  }

  /// Deletes the cache entry for [path] in every namespace in [engineIds].
  ///
  /// Synchronous best-effort twin of the old async deleter, for code paths
  /// that must never await async disk IO — notably batch selection deletes,
  /// which widget tests drive inside a FakeAsync zone where method-channel
  /// and async file calls never complete. Uses the memoized cache dir and is
  /// a no-op when the dir was never resolved this session; orphaned entries
  /// are swept by [prune], and the cache key folds in path + mtime + size so
  /// a stale entry can never serve wrong content.
  static void clearFor(String path, {required List<String> engineIds}) {
    // The test override wins over the memoized dir so tests can point the
    // helpers at a temp dir.
    final dirPath = debugCacheDirOverride ?? _cacheDirPathCache;
    if (dirPath == null) return;
    for (final engineId in engineIds) {
      _deleteCacheFile(path, dirPath, engineId);
    }
  }

  /// Deletes cache entries that no longer correspond to any of [paths], then
  /// trims the cache to [maxBytes] by removing the least recently modified
  /// files. This also sweeps entries from earlier cache schema versions.
  ///
  /// The sweep runs in a background isolate so a large cache never janks the
  /// UI thread at startup.
  static Future<void> prune(
    Iterable<String> paths, {
    int maxBytes = 256 * 1024 * 1024,
    required List<String> engineIds,
  }) async {
    if (_pruneRunning) return;
    final dirPath = await _safeCacheDirPath();
    if (dirPath == null) return;
    _pruneRunning = true;
    try {
      await compute(_pruneCacheIsolate, (
        dirPath,
        [for (final p in paths) p],
        maxBytes,
        engineIds,
      ));
    } catch (_) {
    } finally {
      _pruneRunning = false;
    }
  }

  static bool _pruneRunning = false;

  static void _pruneCacheIsolate(
    (String, List<String>, int, List<String>) args,
  ) {
    final (dirPath, paths, maxBytes, engineIds) = args;
    try {
      final dir = Directory(dirPath);
      if (!dir.existsSync()) return;
      final valid = <String>{};
      for (final p in paths) {
        for (final engine in engineIds) {
          try {
            valid.add(keyFor(p, engineId: engine));
          } catch (_) {}
        }
      }

      final files = <File>[];
      var total = 0;
      for (final entity in dir.listSync()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        final base = name.endsWith('.json')
            ? name.substring(0, name.length - '.json'.length)
            : name;
        if (!valid.contains(base)) {
          try {
            entity.deleteSync();
          } catch (_) {}
          continue;
        }
        files.add(entity);
        total += entity.lengthSync();
      }

      if (total > maxBytes && files.isNotEmpty) {
        files.sort(
          (a, b) => a.statSync().modified.compareTo(b.statSync().modified),
        );
        for (final f in files) {
          if (total <= maxBytes) break;
          final size = f.lengthSync();
          try {
            f.deleteSync();
            total -= size;
          } catch (_) {}
        }
      }
    } catch (_) {}
  }
}

/// Engine id the retired Dart parser stamped into its disk-cache keys.
///
/// No code path reads these entries anymore; the id survives only so
/// delete/relink/prune can find and remove orphaned Dart-namespace files.
const String legacyDartEngineId = 'dart';
