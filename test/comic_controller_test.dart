import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:burrow/controllers/comic_controller.dart';
import 'package:burrow/models/book.dart';
import 'package:burrow/models/reader_settings.dart';
import 'package:burrow/services/comic_page_provider.dart';
import 'package:burrow/services/library_service.dart';
import 'package:burrow/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';

Book _comic() => Book(
  id: 'c1',
  title: 'Comic',
  author: '',
  path: '/tmp/c.cbz',
  format: BookFormat.cbz,
  addedAt: 1,
);

void main() {
  test('notePageChanged records a flip', () {
    var flips = 0;
    final ctrl = ComicReaderController(
      book: _comic(),
      settings: ReaderSettings(),
      library: LibraryService(),
      onPageFlipped: () => flips++,
    );

    ctrl.notePageChanged(3);

    expect(ctrl.comicPage, 3);
    expect(flips, 1);
    ctrl.dispose();
  });

  test('nearestPageIndex falls back to current page when no keys are laid out',
      () {
    final ctrl = ComicReaderController(
      book: _comic(),
      settings: ReaderSettings(),
      library: LibraryService(),
    );
    ctrl.comicPage = 4;
    expect(ctrl.nearestPageIndex(0), 4);
    ctrl.dispose();
  });

  test('vertical zoom controllers are per-page and disposed', () {
    final ctrl = ComicReaderController(
      book: _comic(),
      settings: ReaderSettings(),
      library: LibraryService(),
    );
    expect(identical(ctrl.verticalTransformer(0), ctrl.verticalTransformer(0)), isTrue);
    expect(identical(ctrl.verticalTransformer(0), ctrl.verticalTransformer(1)), isFalse);
    ctrl.dispose();
  });

  test('prefetch swallows a failing page and does not wedge the loading set',
      () async {
    final ctrl = ComicReaderController(
      book: _comic(),
      settings: ReaderSettings(),
      library: LibraryService(),
    );
    final source = _FakeSource(10, failOn: {2});
    ctrl.comicPageProvider = source;

    await ctrl.prefetchComicPages(1);

    // The failing page must not remain marked as loading.
    expect(ctrl.comicPagesLoading, isNot(contains(2)));
    expect(source.loads, greaterThan(0));
    ctrl.dispose();
  });

  test('comicError strips the exception type prefix', () async {
    final ctrl = ComicReaderController(
      book: Book(
        id: 'c1',
        title: 'Comic',
        author: '',
        path: '/definitely/missing.cbz',
        format: BookFormat.cbz,
        addedAt: 1,
      ),
      settings: ReaderSettings(),
      library: LibraryService(),
    );
    await ctrl.loadComicPages();
    expect(ctrl.comicError, isNotNull);
    expect(ctrl.comicError, isNot(contains('FormatException')));
    expect(ctrl.comicError, isNot(contains('Exception')));
    ctrl.dispose();
  });

  test('comicError surfaces the friendly FormatException message', () async {
    final archive = Archive()
      ..addFile(ArchiveFile('readme.txt', 5, [104, 101, 108, 108, 111]));
    final bytes = ZipEncoder().encode(archive);
    final tmp = await Directory.systemTemp.createTemp('comic_ctrl_test');
    final file = File('${tmp.path}/no_images.cbz');
    await file.writeAsBytes(bytes);

    final ctrl = ComicReaderController(
      book: Book(
        id: 'c2',
        title: 'Comic',
        author: '',
        path: file.path,
        format: BookFormat.cbz,
        addedAt: 1,
      ),
      settings: ReaderSettings(),
      library: LibraryService(),
    );
    await ctrl.loadComicPages();
    expect(ctrl.comicError, 'No images found in comic archive');
    expect(ctrl.comicError, isNot(contains('FormatException')));
    expect(ctrl.comicError, isNot(contains('Exception')));
    ctrl.dispose();
    tmp.deleteSync(recursive: true);
  });

  test('loadComicPages opens a CBR through the content-engine seam', () async {
    // The non-CBZ branch parses via `createEpubEngine(library.epubEngine)`
    // (retire-dart-engine Task 6). The fixture archives `page10` before
    // `page2`, so only a natural sort yields three pages in order.
    await RustLib.init();
    final ctrl = ComicReaderController(
      book: Book(
        id: 'cbr1',
        title: 'Mini CBR',
        author: '',
        path: 'test/fixtures/epub/mini.cbr',
        format: BookFormat.cbr,
        addedAt: 1,
      ),
      settings: ReaderSettings(),
      library: LibraryService(),
    );
    await ctrl.loadComicPages();
    expect(ctrl.comicError, isNull);
    expect(ctrl.comicLoading, isFalse);
    expect(ctrl.comicPages, hasLength(3));
    for (final page in ctrl.comicPages) {
      expect(page, isNotEmpty);
    }
    ctrl.dispose();
  });
}

class _FakeSource implements ComicPageSource {
  _FakeSource(this.pageCount, {this.failOn = const {}});
  @override
  final int pageCount;
  final Set<int> failOn;
  int loads = 0;
  @override
  final List<ComicPageMeta> pages = [];
  final Map<int, Uint8List> cache = {};
  @override
  Future<Uint8List> loadPage(int index) async {
    loads++;
    if (failOn.contains(index)) throw const FormatException('bad page');
    final b = Uint8List.fromList([index]);
    cache[index] = b;
    return b;
  }

  @override
  Uint8List? peekPage(int index) => cache[index];
  @override
  bool isCached(int index) => cache.containsKey(index);
  @override
  void evictOutside(int center, {int margin = 5}) {}
  @override
  void dispose() {}
}
