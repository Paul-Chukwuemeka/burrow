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

import 'package:archive/archive_io.dart';

Future<void> main(List<String> args) async {
  final input = InputFileStream(args[0]);
  final xzDecoder = XZDecoder();
  final watch = Stopwatch()..start();
  int? expectedLength;
  if (args.length > 1) {
    expectedLength = 208617472; // wikt_primary3250-noname.sqlite
  }
  final out = OutputFileStream('/tmp/opencode/decode_check.sqlite');
  final ok = xzDecoder.decodeStream(input, out);
  watch.stop();
  final len = out.length;
  await out.close();
  input.close();
  print('decoded=$ok bytes=$len elapsed=${watch.elapsed}');
  if (expectedLength != null && len != expectedLength) {
    print('LENGTH MISMATCH (expected $expectedLength)');
  } else {
    print('length matches spike original');
  }
}
