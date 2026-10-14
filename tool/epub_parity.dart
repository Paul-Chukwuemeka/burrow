// Synthetic EPUB parity gate (Task 9).
//
// Compares `DartEpubEngine.parse` against `RustEpubEngine.parse` over a corpus
// directory and fails on UNCLASSIFIED diffs (see
// `lib/services/epub/epub_parity.dart` and `test/fixtures/epub/ledger.json`).
// The gate is "zero unclassified diffs", not zero diffs.
//
// This script is intentionally `dart:io`-only: the engines themselves need
// Flutter (they share the reader's parser), so the comparison runs inside
// `flutter test` (`test/epub_engine/parity_test.dart`) and this script drives
// it, forwarding the exit code.
//
// Usage (from the package root):
//   dart tool/epub_parity.dart --corpus test/fixtures/epub --fail-on-unclassified
//   dart tool/epub_parity.dart --corpus <dir> [--ledger <file>] [--fail-on-unclassified]
//
// The real-book corpus is NOT run here: it lives outside git (licensed books)
// and runs as a scheduled nightly job (see `.github/workflows/`).
import 'dart:io';

void main(List<String> args) async {
  var corpus = 'test/fixtures/epub';
  var ledger = 'test/fixtures/epub/ledger.json';
  var failOnUnclassified = false;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--corpus':
        corpus = _value(args, i++);
      case '--ledger':
        ledger = _value(args, i++);
      case '--fail-on-unclassified':
        failOnUnclassified = true;
      case '--help' || '-h':
        _usage();
        return;
      default:
        stderr.writeln('Unknown argument: ${args[i]}');
        _usage();
        exitCode = 2;
        return;
    }
  }

  if (!Directory(corpus).existsSync()) {
    stderr.writeln('Corpus directory not found: $corpus');
    exitCode = 2;
    return;
  }
  if (!File(ledger).existsSync()) {
    stderr.writeln('Ledger file not found: $ledger');
    exitCode = 2;
    return;
  }
  if (!File('test/epub_engine/parity_test.dart').existsSync()) {
    stderr.writeln('Run from the package root (test/epub_engine/ missing).');
    exitCode = 2;
    return;
  }

  final result = await Process.start(
    'flutter',
    ['test', 'test/epub_engine/parity_test.dart', '--reporter', 'expanded'],
    environment: {
      ...Platform.environment,
      'EPUB_PARITY_CORPUS': corpus,
      'EPUB_PARITY_LEDGER': ledger,
      if (failOnUnclassified) 'EPUB_PARITY_FAIL_ON_UNCLASSIFIED': '1',
    },
    mode: ProcessStartMode.inheritStdio,
  );
  exitCode = await result.exitCode;
}

String _value(List<String> args, int i) {
  if (i + 1 >= args.length) {
    stderr.writeln('Missing value for ${args[i]}');
    _usage();
    exit(2);
  }
  return args[i + 1];
}

void _usage() {
  // ignore: avoid_print, CLI usage text.
  print(
    'Usage: dart tool/epub_parity.dart [--corpus <dir>] [--ledger <file>] [--fail-on-unclassified]',
  );
}
