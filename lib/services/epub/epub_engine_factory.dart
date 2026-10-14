import 'dart_epub_engine.dart';
import 'epub_engine.dart';
import 'rust_epub_engine.dart';
import 'rust_status.dart';

export 'dart_epub_engine.dart';
export 'epub_engine.dart';
export 'rust_epub_engine.dart';
export 'rust_status.dart';

/// Creates the content engine for [engineId].
///
/// When the native library failed to load ([isRustEngineAvailable] is false —
/// e.g. a platform without the `.so`, such as iOS in Phase A), a request for
/// the `rust` engine falls back to the Dart engine so the app never ends up
/// with zero working engines. Throws [ArgumentError] for an unknown id
/// instead of guessing: a typo in the persisted flag must fail loudly rather
/// than silently serve another engine's output.
EpubEngine createEpubEngine(String engineId) {
  switch (engineId) {
    case dartEpubEngineId:
      return const DartEpubEngine();
    case rustEpubEngineId:
      if (!isRustEngineAvailable) return const DartEpubEngine();
      return const RustEpubEngine();
    default:
      throw ArgumentError.value(engineId, 'engineId', 'Unknown EPUB engine');
  }
}
