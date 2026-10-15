import '../../models/document.dart';
import 'epub_cache.dart';

/// Canonical engine id understood by `createEpubEngine` (see
/// `epub_engine_factory.dart`).
///
/// The Dart engine is retired (retire-dart-engine Task 7): `rust` is the only
/// engine. The Dart-namespaced cache keys it once wrote are still deleted as
/// orphans (see [legacyDartEngineId]) but never read.
const String rustEpubEngineId = 'rust';

/// The content-engine seam.
///
/// The reader (and the library metadata worker) talk to an [EpubEngine]
/// rather than a concrete parser, so the parse implementation stays behind
/// one interface. The interface is shaped like the retired static Dart-parser
/// API (parse / extractMetadata / clearCacheFor / hydrate).
abstract class EpubEngine {
  /// Parses a document into chapters. Heavy work may run off the main isolate.
  Future<ParsedDocument> parse(String path);

  /// Extracts only metadata and cover bytes from a document.
  Future<ParsedMetadata> extractMetadata(String path);

  /// Deletes every engine's cache entry for [path], if one exists — the
  /// active namespace plus orphaned entries from the retired Dart engine.
  ///
  /// Synchronous and best-effort: call sites include batch deletes that run
  /// inside a `FakeAsync` zone where async disk IO never completes.
  void clearCacheFor(String path);

  /// Fills deferred inline-image bytes from the source file.
  ///
  /// Runs off the open path (after the first paint). A missing entry leaves
  /// that image's bytes empty — the renderer shows a sized placeholder — so
  /// a moved or damaged source degrades one image instead of failing the
  /// whole open. Never throws; returns [doc] unchanged when nothing is
  /// deferred or the book cannot be opened.
  Future<ParsedDocument> hydrateImages(ParsedDocument doc, String path);

  /// Fills deferred `@font-face` bytes from the source file.
  ///
  /// Engines that embed font bytes at parse time return [doc] unchanged.
  /// Never throws; returns [doc] unchanged when nothing is deferred or the
  /// book cannot be opened.
  Future<ParsedDocument> hydrateFonts(ParsedDocument doc, String path);
}

/// Disk-cache key for [path] as seen by [engineId].
///
/// Flipping engines must never read another engine's cached output, so the key
/// folds in the engine id alongside the file identity and cache schema tag.
/// Missing/unreadable sources still yield a stable key rather than throwing.
String cacheKeyFor(String path, {required String engineId}) =>
    EpubCache.keyFor(path, engineId: engineId);
