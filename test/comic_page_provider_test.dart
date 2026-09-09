import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:burrow/services/comic_page_provider.dart';
import 'package:flutter_test/flutter_test.dart';

/// Minimal 1×1 white PNG.
final _tinyPng = Uint8List.fromList([
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, // PNG sig
  0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, // IHDR
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
  0xde, 0x00, 0x00, 0x00, 0x0c, 0x49, 0x44, 0x41, // IDAT
  0x54, 0x08, 0xd7, 0x63, 0xf8, 0xcf, 0xc0, 0x00,
  0x00, 0x00, 0x02, 0x00, 0x01, 0xe2, 0x21, 0xbc,
  0x33, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, // IEND
  0x44, 0xae, 0x42, 0x60, 0x82,
]);

Future<String> _createCbz(List<String> names) async {
  final archive = Archive();
  for (var i = 0; i < names.length; i++) {
    archive.addFile(ArchiveFile(names[i], _tinyPng.length, _tinyPng));
  }
  final bytes = ZipEncoder().encode(archive)!;
  final tmp = await Directory.systemTemp.createTemp('comic_test');
  final file = File('${tmp.path}/test.cbz');
  await file.writeAsBytes(bytes);
  return file.path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ComicPageProvider', () {
    test('open detects correct page count and metadata', () async {
      final path = await _createCbz(['page001.png', 'page002.png', 'page003.png']);
      final provider = await ComicPageProvider.open(path);

      expect(provider.pageCount, 3);
      expect(provider.pages, hasLength(3));
      expect(provider.pages[0].entryName, 'page001.png');
      expect(provider.pages[1].entryName, 'page002.png');
      expect(provider.pages[2].entryName, 'page003.png');

      provider.dispose();
    });

    test('open sorts entries naturally', () async {
      final path = await _createCbz([
        'chapter1_page10.png',
        'chapter1_page2.png',
        'chapter1_page1.png',
      ]);
      final provider = await ComicPageProvider.open(path);

      expect(provider.pages[0].entryName, 'chapter1_page1.png');
      expect(provider.pages[1].entryName, 'chapter1_page2.png');
      expect(provider.pages[2].entryName, 'chapter1_page10.png');

      provider.dispose();
    });

    test('loadPage returns correct bytes', () async {
      final path = await _createCbz(['a.png', 'b.png']);
      final provider = await ComicPageProvider.open(path);

      final bytes0 = await provider.loadPage(0);
      final bytes1 = await provider.loadPage(1);
      expect(bytes0, equals(_tinyPng));
      expect(bytes1, equals(_tinyPng));

      provider.dispose();
    });

    test('LRU cache keeps recently loaded pages', () async {
      final path = await _createCbz(['a.png', 'b.png', 'c.png']);
      final provider = await ComicPageProvider.open(path);

      await provider.loadPage(0);
      await provider.loadPage(1);
      expect(provider.isCached(0), isTrue);
      expect(provider.isCached(1), isTrue);

      provider.dispose();
    });

    test('peekPage returns cached page without loading', () async {
      final path = await _createCbz(['a.png']);
      final provider = await ComicPageProvider.open(path);

      expect(provider.peekPage(0), isNull);
      await provider.loadPage(0);
      expect(provider.peekPage(0), isNotNull);

      provider.dispose();
    });

    test('evictOutside removes pages outside margin', () async {
      final path = await _createCbz([
        'a.png', 'b.png', 'c.png', 'd.png', 'e.png',
      ]);
      final provider = await ComicPageProvider.open(path);

      for (var i = 0; i < 5; i++) {
        await provider.loadPage(i);
      }
      expect(provider.isCached(2), isTrue);

      provider.evictOutside(2, margin: 1);
      // 2±1 → keep 1,2,3. Evict 0 and 4.
      expect(provider.isCached(0), isFalse);
      expect(provider.isCached(1), isTrue);
      expect(provider.isCached(2), isTrue);
      expect(provider.isCached(3), isTrue);
      expect(provider.isCached(4), isFalse);

      provider.dispose();
    });

    test('throws FormatException for archive with no images', () async {
      final archive = Archive();
      archive.addFile(ArchiveFile('readme.txt', 5, [0x68, 0x65, 0x6c, 0x6c, 0x6f]));
      final bytes = ZipEncoder().encode(archive)!;
      final tmp = await Directory.systemTemp.createTemp('comic_test');
      final file = File('${tmp.path}/no_images.cbz');
      await file.writeAsBytes(bytes);

      expect(
        () => ComicPageProvider.open(file.path),
        throwsFormatException,
      );
    });
  });
}
