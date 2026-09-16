import 'dart:async';
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

  /// Per-page keys for the vertical list. Comic pages have variable heights,
  /// so jumps target actual item positions via [Scrollable.ensureVisible]
  /// instead of assuming every page is exactly one viewport tall.
  final Map<int, GlobalKey> _verticalPageKeys = {};

  /// Stable key for vertical-list item [index], created on demand.
  GlobalKey verticalPageKey(int index) =>
      _verticalPageKeys.putIfAbsent(index, () => GlobalKey());

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
    _verticalPageKeys.clear();
    try {
      if (book.format == BookFormat.cbz) {
        final provider = await ComicPageProvider.open(book.path);
        if (!_mounted) return;
        comicPageProvider = provider;
        if (provider.pageCount == 0) {
          comicPages = [];
          comicLoading = false;
          notifyListeners();
          return;
        }
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
        // Backfill deferred covers (no-op when one already exists).
        unawaited(library.setCoverIfMissing(book, firstBytes));
        return;
      }

      final doc = await DocumentParser.parse(book.path);
      final pages = <Uint8List>[];
      for (final chapter in doc.chapters) {
        for (final img in chapter.images) {
          pages.add(img.bytes);
        }
      }
      if (!_mounted) return;
      comicPages = pages;
      if (pages.isEmpty) {
        comicLoading = false;
        notifyListeners();
        return;
      }
      comicPage = book.lastChapter.clamp(0, pages.length - 1);
      comicLoading = false;
      notifyListeners();
      comicPageController = PageController(
        initialPage: comicPage.clamp(0, math.max(0, comicPages.length - 1)),
      );
      restoreComicPosition();
      // CBR covers are deferred by metadata extraction; save the first page.
      if (pages.isNotEmpty) {
        unawaited(library.setCoverIfMissing(book, pages.first));
      }
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

  /// Flips one page in [direction] (+1 forward, -1 back).
  ///
  /// In vertical mode there is no [PageView], so the flip scrolls the vertical
  /// list (which approximates one viewport per page, matching the slider and
  /// the position listener). [verticalViewportHeight] must be supplied by the
  /// caller (it owns the [BuildContext]) when in vertical mode.
  void flip(int direction, {double? verticalViewportHeight}) {
    if (comicPageCount == 0) return;
    final target = comicPage + (_isRtl ? -direction : direction);
    if (target < 0 || target >= comicPageCount) return;
    if (_isVertical) {
      _scrollVerticalTo(target, verticalViewportHeight);
      return;
    }
    final pc = comicPageController;
    if (pc == null || !pc.hasClients) return;
    pc.animateToPage(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  void jumpToPage(int page, {double? verticalViewportHeight}) {
    if (page < 0 || page >= comicPageCount) return;
    if (_isVertical) {
      _scrollVerticalTo(page, verticalViewportHeight);
      return;
    }
    final pc = comicPageController;
    if (pc == null || !pc.hasClients) return;
    pc.animateToPage(
      page,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  void _scrollVerticalTo(int page, double? viewportHeight) {
    // Prefer the item's actual position: pages have variable heights, so
    // `page * viewportHeight` drifts near the end of mixed-height comics.
    final ctx = _verticalPageKeys[page]?.currentContext;
    if (ctx != null) {
      unawaited(
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: 0.0,
        ),
      );
      return;
    }
    // Fallback for the first frame (items not built yet): offset math with
    // hasClients + extent guards so it can never throw.
    final c = comicVerticalScrollController;
    if (c == null ||
        !c.hasClients ||
        viewportHeight == null ||
        viewportHeight <= 0) {
      return;
    }
    c.animateTo(
      (page * viewportHeight).clamp(0.0, c.position.maxScrollExtent),
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
