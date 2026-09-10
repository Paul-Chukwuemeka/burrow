import 'dart:typed_data';
import 'dart:math' as math;

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

  Future<void> loadComicPages({
    required VoidCallback onMounted,
    required void Function(String error) onError,
    required VoidCallback onLoaded,
  }) async {
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
        onLoaded();
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
      onError('Failed to load comic: $e');
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
    final viewportHeight = WidgetsBinding
            .instance.platformDispatcher.views.first.physicalSize.height /
        WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;
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
      target.clamp(
        0.0,
        comicPreviewScrollController.position.maxScrollExtent,
      ),
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

  void flip(int direction, BuildContext context) {
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

  Widget buildPaginated(
    BuildContext context,
    ReaderTheme theme, {
    required Widget Function(Widget child) chromeWrapper,
    required void Function(VoidCallback) onToggleChrome,
  }) {
    return Stack(
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) {
            final w = context.size?.width ?? MediaQuery.sizeOf(context).width;
            final dx = details.localPosition.dx;
            if (dx < w * 0.3) {
              flip(-1, context);
            } else if (dx > w * 0.7) {
              flip(1, context);
            } else {
              onToggleChrome(() {});
            }
          },
          child: PageView.builder(
            reverse: _isRtl,
            controller: comicPageController!,
            itemCount: comicPageCount,
            onPageChanged: onPageChanged,
            itemBuilder: (context, i) => Center(
              child: isLazy
                  ? _LazyComicPageWidget(
                      provider: comicPageProvider!,
                      pageIndex: i,
                      fit: boxFit,
                    )
                  : Image.memory(
                      comicPages[i],
                      fit: boxFit,
                    ),
            ),
          ),
        ),
        IgnorePointer(
          ignoring: false,
          child: chromeWrapper(const SizedBox.shrink()),
        ),
      ],
    );
  }

  Widget buildVertical(
    BuildContext context,
    ReaderTheme theme, {
    required Widget Function(Widget child) chromeWrapper,
    required void Function(VoidCallback) onToggleChrome,
  }) {
    comicVerticalScrollController ??= ScrollController();
    final controller = comicVerticalScrollController!;
    if (!comicVerticalListenerAttached) {
      comicVerticalListenerAttached = true;
      controller.addListener(onVerticalScroll);
    }
    return Stack(
      children: [
        ListView.builder(
          controller: controller,
          padding: EdgeInsets.zero,
          itemCount: comicPageCount,
          itemBuilder: (context, i) => InteractiveViewer(
            minScale: 1.0,
            maxScale: 4.0,
            child: Center(
              child: isLazy
                  ? _LazyComicPageWidget(
                      provider: comicPageProvider!,
                      pageIndex: i,
                      fit: boxFit,
                    )
                  : Image.memory(
                      comicPages[i],
                      fit: boxFit,
                    ),
            ),
          ),
        ),
        IgnorePointer(
          ignoring: false,
          child: chromeWrapper(const SizedBox.shrink()),
        ),
      ],
    );
  }

  Widget buildPreviewStrip(
    BuildContext context,
    ReaderTheme theme, {
    required void Function(int) onPageJump,
  }) {
    final count = comicPageCount;
    if (count == 0) return const SizedBox.shrink();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      scrollToPreviewPage(comicPage);
    });
    return SizedBox(
      height: 80,
      child: ListView.builder(
        controller: comicPreviewScrollController,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        itemCount: count,
        itemBuilder: (context, i) {
          final isCurrent = i == comicPage;
          return GestureDetector(
            onTap: () => onPageJump(i),
            child: Container(
              width: 52,
              margin: const EdgeInsets.symmetric(horizontal: 2),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: isCurrent
                              ? theme.accent
                              : theme.muted.withValues(alpha: 0.3),
                          width: isCurrent ? 2 : 1,
                        ),
                        borderRadius: BorderRadius.circular(3),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: isLazy
                          ? _LazyComicPageWidget(
                              provider: comicPageProvider!,
                              pageIndex: i,
                              fit: BoxFit.cover,
                            )
                          : (i < comicPages.length
                              ? Image.memory(comicPages[i],
                                  fit: BoxFit.cover)
                              : Container(
                                  color: theme.muted.withValues(alpha: 0.2))),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${i + 1}',
                    style: TextStyle(
                      fontSize: 9,
                      color: isCurrent ? theme.accent : theme.muted,
                      fontWeight: isCurrent
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _LazyComicPageWidget extends StatefulWidget {
  const _LazyComicPageWidget({
    required this.provider,
    required this.pageIndex,
    required this.fit,
  });

  final ComicPageProvider provider;
  final int pageIndex;
  final BoxFit fit;

  @override
  State<_LazyComicPageWidget> createState() => _LazyComicPageWidgetState();
}

class _LazyComicPageWidgetState extends State<_LazyComicPageWidget> {
  Uint8List? _bytes;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _bytes = widget.provider.peekPage(widget.pageIndex);
    if (_bytes == null) _load();
  }

  @override
  void didUpdateWidget(covariant _LazyComicPageWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pageIndex != widget.pageIndex) {
      _bytes = widget.provider.peekPage(widget.pageIndex);
      if (_bytes == null && !_loading) _load();
    }
  }

  Future<void> _load() async {
    if (_loading) return;
    _loading = true;
    final bytes = await widget.provider.loadPage(widget.pageIndex);
    if (!mounted) return;
    setState(() {
      _bytes = bytes;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_bytes != null) {
      return Image.memory(_bytes!, fit: widget.fit);
    }
    final meta = widget.provider.pages[widget.pageIndex];
    final screenW = MediaQuery.sizeOf(context).width;
    final aspect = meta.intrinsicHeight > 0
        ? meta.intrinsicWidth / meta.intrinsicHeight
        : 0.67;
    final h = screenW / aspect;
    return Container(
      width: screenW,
      height: h,
      color: const Color(0xFF1A1A2E),
    );
  }
}
