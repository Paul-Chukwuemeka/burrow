// Smoke test for the flutter_rust_bridge wiring (Task 1).
//
// `RustLib.init()` loads the host build of the Rust engine from
// `rust/target/release/librust_lib_burrow.so`. That artifact is gitignored, so
// `test/flutter_test_config.dart` builds it on demand before the suite runs.
// (Android builds compile the engine themselves via the Gradle
// `buildRustEngine` task; there is no iOS path yet.)
import 'package:burrow/src/rust/api/epub.dart';
import 'package:burrow/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('rust engine responds over FFI', () async {
    await RustLib.init();
    expect(engineVersion(), isNotEmpty);
  });
}
