// Tests for lib/services/dictionary_files.dart — pure fs helpers, no
// path_provider.

import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:burrow/services/dictionary_files.dart';

void main() {
  late Directory scratch;

 setUpAll(() {});
  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('dict_files_test');
  });

  tearDown(() => scratch.delete(recursive: true));

  group('decompressAndVerify', () {
    test('round-trips a small xz container', () async {
      // The archive package's XZEncoder only supports uncompressed blocks,
      // which is fine: a valid xz container decodable by XZDecoder is all the
      // helper needs. Production decodes the real CLI xz artifact.
      const payload = 'dictionary payload bytes for the round trip test';
      final source = Uint8List.fromList(payload.codeUnits);
      final xzBytes = XZEncoder().encode(source);

      final xzFile = File('${scratch.path}/container.xz')
        ..writeAsBytesSync(xzBytes);
      final outFile = File('${scratch.path}/out.sqlite');

      final digest = sha256.convert(xzBytes).toString();
      await decompressAndVerify(
        xz: xzFile,
        out: outFile,
        expectedSha256: digest,
      );

      expect(outFile.existsSync(), true);
      expect(outFile.lengthSync(), source.length);
      expect(
        String.fromCharCodes(outFile.readAsBytesSync()),
        payload,
      );
    });

    test('sha mismatch throws StateError and removes container and out', () async {
      final xzFile = File('${scratch.path}/container.xz')
        ..writeAsBytesSync(XZEncoder().encode('data'.codeUnits));
      final outFile = File('${scratch.path}/out.sqlite')
        ..writeAsStringSync('stale previous database');

      await expectLater(
        decompressAndVerify(
          xz: xzFile,
          out: outFile,
          expectedSha256: '0${'0' * 63}',
        ),
        throwsStateError,
      );
      expect(xzFile.existsSync(), false, reason: 'container must be deleted');
      expect(outFile.existsSync(), false, reason: 'stale out must be deleted');
    });

    test('empty expectedSha256 skips integrity check but still decodes',
        () async {
      final xzFile = File('${scratch.path}/container.xz')
        ..writeAsBytesSync(
          XZEncoder().encode('unchecked payload'.codeUnits),
        );
      final outFile = File('${scratch.path}/out.sqlite');

      await decompressAndVerify(xz: xzFile, out: outFile, expectedSha256: '');
      expect(outFile.existsSync(), true);
    });

    test('undecodable container throws StateError and deletes all artifacts',
        () async {
      final garbage = Uint8List.fromList(
        List.generate(64, (i) => (i * 7 + 13) & 0xFF),
      );
      final xzFile = File('${scratch.path}/container.xz')
        ..writeAsBytesSync(garbage);
      final outFile = File('${scratch.path}/out.sqlite')
        ..writeAsStringSync('stale');

      final sha = sha256.convert(garbage).toString();
      await expectLater(
        decompressAndVerify(
          xz: xzFile,
          out: outFile,
          expectedSha256: sha, // hash matches: failure must surface at decode
        ),
        throwsStateError,
      );
      expect(xzFile.existsSync(), false, reason: 'container must be deleted');
      expect(outFile.existsSync(), false, reason: 'stale out must be deleted');
      expect(
        File('${scratch.path}/out.sqlite.tmp').existsSync(),
        false,
        reason: 'partial tmp out must be deleted',
      );
    });
  });

  group('cleanupDictionaryArtifacts', () {
    test('deletes exactly the 4 obsolescent names, keeps the live pair',
        () async {
      final names = [
        'dictionary_full.sqlite',
        'dictionary_full.sqlite.tmp',
        'dictionary.sqlite.tmp',
        'dictionary.sqlite.xz.tmp',
        'dictionary.sqlite',
        'dictionary.sqlite.xz',
        'unrelated.txt',
      ];
      for (final name in names) {
        File('${scratch.path}/$name').writeAsStringSync('x');
      }

      await cleanupDictionaryArtifacts(scratch);

      expect(
        scratch.listSync().map((e) => e.path.split('/').last).toSet(),
        {'dictionary.sqlite', 'dictionary.sqlite.xz', 'unrelated.txt'},
      );
    });
  });
}
