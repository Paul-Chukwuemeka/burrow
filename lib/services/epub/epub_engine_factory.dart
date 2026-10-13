import '../document_parser.dart';
import 'dart_epub_engine.dart';
import 'epub_engine.dart';

export 'dart_epub_engine.dart';
export 'epub_engine.dart';

/// Creates the content engine for [engineId].
///
/// Throws [ArgumentError] for an unknown id instead of guessing: a typo in the
/// persisted flag must fail loudly rather than silently serve another engine's
/// output.
EpubEngine createEpubEngine(String engineId) {
  switch (engineId) {
    case dartEpubEngineId:
      return const DartEpubEngine();
    case rustEpubEngineId:
      return const _RustEpubEngineStub();
    default:
      throw ArgumentError.value(engineId, 'engineId', 'Unknown EPUB engine');
  }
}

/// Placeholder registration for the native engine.
///
/// The Dart seam (and the factory test) land now so the flag can be threaded
/// through before the Rust parser exists; every method throws until the Rust
/// metadata/parse paths replace this stub in later tasks.
class _RustEpubEngineStub implements EpubEngine {
  const _RustEpubEngineStub();

  @override
  Future<ParsedDocument> parse(String path) async =>
      throw UnimplementedError('Rust EPUB parse is not implemented yet');

  @override
  Future<ParsedMetadata> extractMetadata(String path) async =>
      throw UnimplementedError('Rust EPUB metadata is not implemented yet');

  @override
  void clearCacheFor(String path) =>
      throw UnimplementedError('Rust EPUB cache is not implemented yet');
}
