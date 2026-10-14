import 'package:flutter/foundation.dart';

/// Whether the native Rust engine can be used on this device.
///
/// Set once from `main()` after `RustLib.init()`: a failed init (missing
/// `.so`/`.dylib`, dlopen error) leaves the app with zero working engines
/// unless the factory falls back to Dart — the default engine id is `rust`.
///
/// The `.so` is currently built for Android only (see the Gradle
/// `cargo-ndk` task); iOS packaging is out of scope for Phase A (no Xcode
/// runner wired up yet), so iOS always runs with this set to false and gets
/// the Dart engine. See the README "EPUB engine" section.
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
