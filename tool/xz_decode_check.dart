// tool/xz_decode_check.dart
//
// Task 4 Step 0 gate: prove the chosen xz decoder decodes the real spike
// artifact end-to-end and measure how long it takes.
//
//   dart run tool/xz_decode_check.dart <in.xz> [<expected.out>]
//
// Ruling recorded in the plan ledger: the Step-0 candidate `es_compression`
// provides NO xz codec (Brotli/Lz4/Zstd only — verified on pub.dev), so the
// fallback FFI shim is NOT needed either: `archive` (already a runtime
// dependency) ships XZDecoder with streaming decode. Chosen: archive 4.5.2.

import 'dart:io';

import 'package:archive/archive_io.dart';

Future<void> main(List<String> args) async {
  if (args.length < 1) {
    stderr.writeln('usage: dart run tool/xz_decode_check.dart <in.xz>');
    return;
  }
  final watch = Stopwatch()..start();
  final out = OutputFileStream('/tmp/opencode/decode_check.sqlite');
  final input = InputFileStream(args[0]);
  final ok = XZDecoder().decodeStream(input, out);
  watch.stop();
  final bytes = out.length;
  await out.close();
  input.close();
  // A verification script's mandated report.
  // ignore: avoid_print
  print('decoded=$ok bytes=$bytes elapsed=${watch.elapsed}');
  if (args.length > 1 && int.parse(args[1]) != bytes) {
    stderr.writeln('LENGTH MISMATCH (expected ${args[1]})');
  }
}
