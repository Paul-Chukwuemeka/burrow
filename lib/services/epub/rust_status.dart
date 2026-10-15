import 'package:flutter/foundation.dart';

/// Whether the native Rust engine can be used on this device.
///
/// Set once from `main()` after `RustLib.init()`: a failed init (missing
/// `.so`/`.dylib`, dlopen error) leaves the app with zero working engines —
/// the Dart engine is retired, so there is no fallback and callers degrade
/// (placeholder UI, retryable metadata). The default engine id is `rust`.
///
/// The `.so` is currently built for Android only (see the Gradle
/// `cargo-ndk` task); no iOS `.so` is packaged, so on iOS this stays false
/// and reading hard-fails until a cargokit/FFI packaging step lands.
/// See the README "Platform support / known issues" section.
///
/// Defaults to true so unit tests (which `RustLib.init()` in `setUpAll`)
/// keep exercising the real Rust path.
bool _rustEngineAvailable = true;

/// True when `RustLib.init()` succeeded and the Rust FFI can be called.
bool get isRustEngineAvailable => _rustEngineAvailable;

/// Records the outcome of `RustLib.init()`. Called once from `main()`.
void setRustEngineAvailable(bool available) {
  _rustEngineAvailable = available;
}

/// Test seam: runs [body] with the availability flag forced to [available],
/// restoring the previous value afterwards.
@visibleForTesting
Future<T> withRustAvailability<T>(bool available, Future<T> Function() body) async {
  final previous = _rustEngineAvailable;
  _rustEngineAvailable = available;
  try {
    return await body();
  } finally {
    _rustEngineAvailable = previous;
  }
}
