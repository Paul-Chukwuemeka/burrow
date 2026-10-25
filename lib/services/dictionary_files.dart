// lib/services/dictionary_files.dart
//
// Pure file-system helpers for the downloadable Wiktionary dictionary.
// Kept free of any path_provider/service plumbing so it is unit-testable.

import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';

/// Artifact temp/obsolescent names deleted on [cleanupDictionaryArtifacts].
const List<String> dictionaryCleanupNames = [
  // legacy Open English WordNet builds and their partial downloads
  'dictionary_full.sqlite',
  'dictionary_full.sqlite.tmp',
  // new-build temp names
  'dictionary.sqlite.tmp',
  'dictionary.sqlite.xz.tmp',
];

/// Deletes exactly [dictionaryCleanupNames] from [dir] when present.
Future<void> cleanupDictionaryArtifacts(Directory dir) async {
  for (final name in dictionaryCleanupNames) {
    final file = File('${dir.path}/$name');
    if (file.existsSync()) {
      await file.delete();
    }
  }
}

/// Verifies [xz]'s sha256 against [expectedSha256] (streaming, chunked) and
/// then decodes xz → [out], via an `out.tmp` sibling that is renamed on
/// success.
///
/// An empty [expectedSha256] skips the integrity check (pre-release builds —
/// the pinned hash is filled at release time).
///
/// On hash mismatch: throws `StateError('Dictionary download integrity check
/// failed')` after deleting the container and any stale/partial output file.
Future<void> decompressAndVerify({
  required File xz,
  required File out,
  required String expectedSha256,
}) async {
  final tmpOut = File('${out.path}.tmp');

  if (expectedSha256.isNotEmpty) {
    final digest = await _hashSha256(xz);
    if (digest != expectedSha256) {
      // Mismatch path: container and any stale/partial output must not
      // survive.
      await _deleteAll([xz, out, tmpOut]);
      throw StateError('Dictionary download integrity check failed');
    }
  }

  // Stale partial output from a failed previous attempt must not leak into
  // the renamed result.
  await _deleteAll([tmpOut, out]);

  final input = InputFileStream(xz.path);
  final output = OutputFileStream(tmpOut.path);
  try {
    XZDecoder().decodeStream(input, output);
  } finally {
    await output.close();
    input.close();
  }
  await tmpOut.rename(out.path);
}

/// Streams the file through sha256 in chunks; never loads it into memory.
Future<String> _hashSha256(File file) async {
  final collector = _DigestSink();
  final chunkSink = sha256.startChunkedConversion(collector);
  await for (final chunk in file.openRead()) {
    chunkSink.add(chunk);
  }
  chunkSink.close();
  return collector.digest.toString();
}

class _DigestSink implements Sink<Digest> {
  Digest? _digest;

  Digest get digest => _digest!;

  @override
  void add(Digest data) => _digest = data;

  @override
  void close() {}
}

/// Deletes [paths] when they exist.
Future<void> _deleteAll(List<File> paths) async {
  for (final f in paths) {
    if (f.existsSync()) await f.delete();
  }
}
