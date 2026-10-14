import '../document_parser.dart';

/// Canonical engine ids understood by `createEpubEngine` (see
/// `epub_engine_factory.dart`).
///
/// [dartEpubEngineId] is the id the Dart parser stamps into its disk-cache keys
/// (see [DocumentParser.engineId]); [rustEpubEngineId] selects the native
/// engine, which is the default (see `LibraryService.epubEngine`).
const String dartEpubEngineId = DocumentParser.engineId;
const String rustEpubEngineId = 'rust';

/// The content-engine seam.
///
/// The reader (and, later, the library metadata worker) talk to an [EpubEngine]
/// rather than [DocumentParser] directly, so the Dart and Rust content engines
/// are interchangeable behind a reversible flag (design D8). The interface is
/// deliberately shaped like the existing static `DocumentParser` API so the
/// Dart adapter is a pure delegation.
abstract class EpubEngine {
  /// Parses a document into chapters. Heavy work may run off the main isolate.
  Future<ParsedDocument> parse(String path);

  /// Extracts only metadata and cover bytes from a document.
  Future<ParsedMetadata> extractMetadata(String path);

  /// Deletes this engine's cache entry for [path], if one exists.
  ///
  /// Synchronous and best-effort: call sites include batch deletes that run
  /// inside a `FakeAsync` zone where async disk IO never completes.
  void clearCacheFor(String path);
}

/// Disk-cache key for [path] as seen by [engineId] (design D13).
///
/// Flipping the engine flag must never read the other engine's cached output,
/// so the key folds in the engine id alongside the file identity and cache
/// schema tag. Missing/unreadable sources still yield a stable key rather than
/// throwing.
String cacheKeyFor(String path, {required String engineId}) =>
    DocumentParser.cacheKeyFor(path, engineId: engineId);
