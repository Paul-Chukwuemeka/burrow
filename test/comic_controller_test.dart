import 'dart:typed_data';

import 'package:burrow/controllers/comic_controller.dart';
import 'package:burrow/models/book.dart';
import 'package:burrow/models/reader_settings.dart';
import 'package:burrow/services/comic_page_provider.dart';
import 'package:burrow/services/library_service.dart';
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
