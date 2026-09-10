import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../models/book.dart';
import '../models/reader_settings.dart';

class PdfReaderController extends ChangeNotifier {
  PdfReaderController({required this.book, required this.settings});

  final Book book;
  final ReaderSettings settings;

  final PdfViewerController pdfController = PdfViewerController();
  int pdfPage = 1;
  int pdfPageCount = 0;
  List<PdfOutlineNode> pdfOutline = [];
  bool pdfLoading = true;
  late final bool pdfFileExists = _checkFileExists();
  PdfTextSearcher? pdfSearcher;

  bool _checkFileExists() => Uri.file(book.path).toFilePath().isNotEmpty;

  void onPdfViewChanged() {
    if (!pdfController.isReady) return;
    final count = pdfController.pageCount;
    final page = pdfController.pageNumber ?? 1;
    if (count == 0) return;
    if (page != pdfPage || count != pdfPageCount) {
      pdfPage = page;
      pdfPageCount = count;
      notifyListeners();
      onPositionChanged?.call(page - 1, 0);
      onBookmarkCheck?.call();
    }
  }

  Future<void> loadPdfOutline(PdfDocument document) async {
    try {
      final outline = await document.loadOutline();
      pdfOutline = outline;
      notifyListeners();
    } catch (e) {
      debugPrint('Failed to load PDF outline: $e');
    }
  }

  void jumpToPdfPage(int pageNumber) {
    if (!pdfController.isReady) return;
    pdfController.goToPage(pageNumber: pageNumber);
    onShowChrome?.call();
  }

  @override
  void dispose() {
    pdfController.removeListener(onPdfViewChanged);
    pdfSearcher?.resetTextSearch();
    pdfSearcher = null;
    super.dispose();
  }

  // Callbacks set by the parent reader screen.
  void Function(int chapter, int offset)? onPositionChanged;
  VoidCallback? onBookmarkCheck;
  VoidCallback? onShowChrome;

  Widget buildPdf(
    ReaderTheme theme, {
    required Widget Function(Widget child) chromeWrapper,
    required void Function(Offset position, String word, int start, int end)
        onWordSelected,
    required VoidCallback onDismissWord,
  }) {
    if (!pdfFileExists) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 48),
            SizedBox(height: 12),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 32),
              child: Text('File not found', textAlign: TextAlign.center),
            ),
          ],
        ),
      );
    }
    final viewer = PdfViewer.file(
      book.path,
      initialPageNumber: book.lastChapter + 1 < 1 ? 1 : book.lastChapter + 1,
      controller: pdfController,
      params: PdfViewerParams(
        backgroundColor: theme.background,
        textSelectionParams: PdfTextSelectionParams(
          enabled: true,
          onTextSelectionChange: (selection) async {
            if (!selection.hasSelectedText) {
              onDismissWord();
              return;
            }
            final selectedText = await selection.getSelectedText();
            final trimmed = selectedText.trim();
            if (trimmed.isNotEmpty && trimmed.length < 50) {
              final words = trimmed.split(RegExp(r'\s+'));
              final word = words.first
                  .replaceAll(RegExp(r'[^a-zA-Z\u00C0-\u024F]'), '');
              if (word.length >= 2) {
                onWordSelected(Offset.zero, word, 0, 0);
              }
            }
          },
        ),
        scrollPhysics: settings.pdfContinuousScroll
            ? null
            : const NeverScrollableScrollPhysics(),
        layoutPages:
            settings.pdfLayoutDirection == PdfLayoutDirection.vertical
                ? null
                : (pages, params) {
                    final margin = params.margin;
                    final height = pages.fold(
                            0.0,
                            (prev, page) =>
                                math.max(prev, page.height)) +
                        margin * 2;
                    final pageLayouts = <Rect>[];
                    double x = margin;
                    final rtl = settings.pdfLayoutDirection ==
                        PdfLayoutDirection.horizontalRtl;
                    for (final page in pages) {
                      pageLayouts.add(
                        Rect.fromLTWH(
                          x,
                          (height - page.height) / 2,
                          page.width,
                          page.height,
                        ),
                      );
                      x += page.width + margin;
                    }
                    if (rtl) {
                      final totalWidth = x;
                      for (var i = 0; i < pageLayouts.length; i++) {
                        final r = pageLayouts[i];
                        pageLayouts[i] = Rect.fromLTWH(
                          totalWidth - r.right,
                          r.top,
                          r.width,
                          r.height,
                        );
                      }
                    }
                    return PdfPageLayout(
                      pageLayouts: pageLayouts,
                      documentSize: Size(x, height),
                    );
                  },
        onDocumentChanged: (document) {
          if (document == null) return;
          pdfLoading = false;
          notifyListeners();
          loadPdfOutline(document);
        },
        viewerOverlayBuilder: (context, size, handleLinkTap) => [],
        pagePaintCallbacks: [
          if (pdfSearcher != null) pdfSearcher!.pageTextMatchPaintCallback,
        ],
      ),
    );

    return Stack(
      children: [
        Positioned.fill(child: viewer),
        if (pdfLoading)
          Positioned.fill(
            child: Container(
              color: theme.background,
              child: Center(
                child: CircularProgressIndicator(color: theme.accent),
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

  String get centerLabel =>
      pdfPageCount == 0 ? '-/-' : 'Page $pdfPage of $pdfPageCount';

  int get sliderMax => pdfPageCount > 1 ? pdfPageCount : 1;

  int get sliderValue => pdfPage.clamp(1, pdfPageCount > 0 ? pdfPageCount : 1);

  String get sliderLabel => pdfPageCount == 0
      ? '-/-'
      : '${((pdfPage / pdfPageCount) * 100).round()}%';

  void onSliderChanged(int v) {
    if (pdfController.isReady) pdfController.goToPage(pageNumber: v);
  }
}
