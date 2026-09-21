import 'dart:io';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../models/book.dart';
import '../models/reader_settings.dart';

class PdfReaderController extends ChangeNotifier {
  PdfReaderController({required this.book, required this.settings}) {
    _checkFileExists();
  }

  final Book book;
  final ReaderSettings settings;

  final PdfViewerController pdfController = PdfViewerController();
  int pdfPage = 1;
  int pdfPageCount = 0;
  List<PdfOutlineNode> pdfOutline = [];
  bool pdfLoading = true;
  bool? pdfFileExists;
  Future<void> _checkFileExists() async {
    try {
      pdfFileExists = await File(book.path).exists();
    } catch (_) {
      pdfFileExists = false;
    }
    notifyListeners();
  }

  void onPdfViewChanged() {
    if (!pdfController.isReady) return;
    final count = pdfController.pageCount;
    final page = pdfController.pageNumber ?? 1;
    if (count == 0) return;
    if (page != pdfPage || count != pdfPageCount) {
      pdfPage = page;
      pdfPageCount = count;
      notifyListeners();
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

  @override
  void dispose() {
    super.dispose();
  }
}
