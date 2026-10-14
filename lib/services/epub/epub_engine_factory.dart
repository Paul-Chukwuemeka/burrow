import 'dart_epub_engine.dart';
import 'epub_engine.dart';
import 'rust_epub_engine.dart';

export 'dart_epub_engine.dart';
export 'epub_engine.dart';
export 'rust_epub_engine.dart';

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
      return const RustEpubEngine();
    default:
      throw ArgumentError.value(engineId, 'engineId', 'Unknown EPUB engine');
  }
}
