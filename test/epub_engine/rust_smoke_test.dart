// Smoke test for the flutter_rust_bridge wiring (Task 1).
//
// Prerequisite: the host build of the Rust engine must exist, because
// `RustLib.init()` loads `rust/target/release/librust_lib_burrow.so`. Build it
// with `cargo build --release` inside `rust/` before running this test on the
// desktop VM. (Android/iOS builds compile the engine themselves via the Gradle
// `buildRustEngine` task.)
import 'package:burrow/src/rust/api/epub.dart';
import 'package:burrow/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('rust engine responds over FFI', () async {
    await RustLib.init();
    expect(engineVersion(), isNotEmpty);
  });
}
