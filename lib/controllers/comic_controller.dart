import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/book.dart';
import '../models/reader_settings.dart';
import '../services/comic_page_provider.dart';
import '../services/document_parser.dart';
import '../services/library_service.dart';

class ComicReaderController extends ChangeNotifier {
  ComicReaderController({
    required this.book,
    required this.settings,
    required this.library,
  });

  final Book book;
  final ReaderSettings settings;
  final LibraryService library;

  List<Uint8List> comicPages = [];
  int comicPage = 0;
  bool comicLoading = true;
  ScrollController? comicVerticalScrollController;
  bool comicVerticalListenerAttached = false;
  ComicPageProvider? comicPageProvider;
  final Set<int> comicPagesLoading = {};
  PageController? comicPageController;
  bool comicPreviewVisible = false;
  final ScrollController comicPreviewScrollController = ScrollController();

  bool get isLazy => comicPageProvider != null;

  int get comicPageCount =>
      isLazy ? comicPageProvider!.pageCount : comicPages.length;

  BoxFit get boxFit {
    switch (settings.comicFitMode) {
      case ComicFitMode.fitWidth:
        return BoxFit.fitWidth;
      case ComicFitMode.fitHeight:
        return BoxFit.fitHeight;
      case ComicFitMode.contain:
        return BoxFit.contain;
    }
  }

  bool get _isVertical =>
      settings.comicReadingMode == ComicReadingMode.vertical;

  bool get _isRtl =>
      settings.comicReadingDirection == ComicReadingDirection.rtl;

  bool _mounted = true;

  Future<void> loadComicPages({VoidCallback? onLoaded}) async {
    try {
      if (book.format == BookFormat.cbz) {
        final provider = await ComicPageProvider.open(book.path);
        if (!_mounted) return;
        comicPageProvider = provider;
        comicPage = book.lastChapter.clamp(0, provider.pageCount - 1);
        final firstBytes = await provider.loadPage(comicPage);
        if (!_mounted) return;
        comicPages = [firstBytes];
        comicLoading = false;
        notifyListeners();
        comicPageController = PageController(
          initialPage: comicPage.clamp(0, math.max(0, comicPageCount - 1)),
        );
        onLoaded?.call();
        return;
      }

      final doc = await DocumentParser.parse(book.path, book.format);
      final pages = <Uint8List>[];
      for (final chapter in doc.chapters) {
        for (final img in chapter.images) {
          pages.add(img.bytes);
        }
      }
      if (!_mounted) return;
      comicPages = pages;
      comicPage = book.lastChapter.clamp(0, pages.length - 1);
      comicLoading = false;
      notifyListeners();
      comicPageController = PageController(
        initialPage: comicPage.clamp(0, math.max(0, comicPages.length - 1)),
      );
      restoreComicPosition();
    } catch (e) {
      if (!_mounted) return;
      comicLoading = false;
      notifyListeners();
    }
  }

  void restoreComicPosition() {
    if (_isVertical) {
      comicVerticalScrollController ??= ScrollController();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_mounted || comicVerticalScrollController == null) return;
        final offset = book.lastOffset;
        if (offset > 0) {
          comicVerticalScrollController!.jumpTo(offset.toDouble());
        }
      });
    }
  }

  void onPageChanged(int i) {
    comicPage = i;
    notifyListeners();
    library.savePosition(
      id: book.id,
      chapter: i,
      offset: 0,
      progress: comicPageCount == 0 ? 0 : i / comicPageCount,
    );
    if (isLazy) prefetchComicPages(i);
    if (comicPreviewVisible) scrollToPreviewPage(i);
  }

  void onVerticalScroll() {
    if (!_mounted) return;
    final count = comicPageCount;
    if (count == 0) return;
    final viewportHeight = MediaQueryData.fromView(
            WidgetsBinding.instance.platformDispatcher.views.first)
        .size.height;
    if (viewportHeight <= 0) return;
    final newIndex = (comicVerticalScrollController!.offset / viewportHeight)
        .round()
        .clamp(0, count - 1);
    if (newIndex != comicPage) {
      comicPage = newIndex;
      notifyListeners();
      library.savePosition(
        id: book.id,
        chapter: newIndex,
        offset: comicVerticalScrollController!.offset.toInt(),
        progress: newIndex / count,
      );
      if (isLazy) prefetchComicPages(newIndex);
      if (comicPreviewVisible) scrollToPreviewPage(newIndex);
    }
  }

  void prefetchComicPages(int center) {
    final provider = comicPageProvider;
    if (provider == null) return;
    const buffer = 5;
    for (var i = center - buffer; i <= center + buffer; i++) {
      if (i < 0 || i >= provider.pageCount) continue;
      if (provider.isCached(i) || comicPagesLoading.contains(i)) continue;
      comicPagesLoading.add(i);
      provider.loadPage(i).then((_) {
        comicPagesLoading.remove(i);
        if (_mounted) notifyListeners();
      });
    }
    provider.evictOutside(center, margin: 10);
  }

  void scrollToPreviewPage(int page) {
    if (!comicPreviewScrollController.hasClients) return;
    final target = (page * 56.0) - 80.0;
    comicPreviewScrollController.jumpTo(
      target.clamp(0.0, comicPreviewScrollController.position.maxScrollExtent),
    );
  }

  void flip(int direction) {
    if (comicPageCount == 0) return;
    final target = comicPage + (_isRtl ? -direction : direction);
    if (target < 0 || target >= comicPageCount) return;
    comicPageController?.animateToPage(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  void jumpToPage(int page) {
    comicPageController?.animateToPage(
      page,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  void togglePreview() {
    comicPreviewVisible = !comicPreviewVisible;
    notifyListeners();
  }

  @override
  void dispose() {
    _mounted = false;
    comicPageController?.dispose();
    comicVerticalScrollController?.dispose();
    comicVerticalListenerAttached = false;
    comicPageProvider?.dispose();
    comicPageProvider = null;
    comicPreviewScrollController.dispose();
    super.dispose();
  }
}
