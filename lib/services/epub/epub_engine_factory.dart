import 'epub_engine.dart';
import 'rust_epub_engine.dart';
import 'rust_status.dart';

export 'epub_engine.dart';
export 'rust_epub_engine.dart';
export 'rust_status.dart';

/// Creates the content engine for [engineId].
///
/// `rust` is the only engine (the Dart engine was retired in Task 7).
/// Throws [ArgumentError] for any other id — including the retired `dart` id
/// — instead of guessing: a typo in a persisted value must fail loudly rather
/// than silently serve another engine's output. Callers holding a persisted
/// value normalize it to [rustEpubEngineId] before calling (see
/// `LibraryService.epubEngine`).
///
/// Note: there is deliberately no fallback when the native library failed to
/// load ([isRustEngineAvailable] is false). The Dart fallback is gone, so the
/// engine surfaces the FFI error and the caller degrades (placeholder UI,
/// retryable metadata) instead of bricking on a missing engine.
EpubEngine createEpubEngine(String engineId) {
  switch (engineId) {
    case rustEpubEngineId:
      return const RustEpubEngine();
    default:
      throw ArgumentError.value(engineId, 'engineId', 'Unknown EPUB engine');
  }
}
