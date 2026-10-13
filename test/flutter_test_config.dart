// Pre-test hook for the whole `test/` tree.
//
// `test/epub_engine/rust_smoke_test.dart` calls `RustLib.init()`, which dlopens
// the host build of the Rust engine from `rust/target/release/`. That directory
// is gitignored, so on a clean checkout/worktree `flutter test` would go red.
// This hook builds the host library when (and only when) it is missing, letting
// the Dart test suite bootstrap itself. Android builds do not rely on this: the
// Gradle `buildRustEngine` task compiles the engine for each ABI.
import 'dart:async';
import 'dart:io';

/// The host dynamic library stem produced by `cargo build --release`.
const _stem = 'rust_lib_burrow';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  await _ensureHostRustLib();
  await testMain();
}

Future<void> _ensureHostRustLib() async {
  final packageRoot = _findPackageRoot();
  final libName = Platform.isMacOS
      ? 'lib$_stem.dylib'
      : Platform.isWindows
          ? '$_stem.dll'
          : 'lib$_stem.so';
  final lib = File('${packageRoot.path}/rust/target/release/$libName');

  // Cheap when the engine is already built (the common case).
  if (lib.existsSync()) return;

  stdout.writeln('[rust] $libName missing; running cargo build --release…');
  final sep = Platform.isWindows ? ';' : ':';
  final cargoBin = Platform.isWindows
      ? '${Platform.environment['USERPROFILE']}\\.cargo\\bin'
      : '${Platform.environment['HOME']}/.cargo/bin';
  final result = Process.runSync(
    'cargo',
    const ['build', '--release'],
    workingDirectory: '${packageRoot.path}/rust',
    environment: {
      ...Platform.environment,
      'PATH': '$cargoBin$sep${Platform.environment['PATH'] ?? ''}',
    },
    runInShell: Platform.isWindows,
  );
  if (result.exitCode != 0) {
    stderr
      ..writeln(result.stdout)
      ..writeln(result.stderr);
    throw StateError(
      'cargo build --release failed (exit ${result.exitCode}); '
      'the Rust engine host library is required to run these tests.',
    );
  }
}

/// Walks up from the current directory to the package root (the dir holding
/// `rust/Cargo.toml`). `flutter test` normally runs from the package root.
Directory _findPackageRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (File('${dir.path}/rust/Cargo.toml').existsSync()) return dir;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError(
    'Could not locate rust/Cargo.toml from ${Directory.current.path}; '
    'run `flutter test` from the package root.',
  );
}
