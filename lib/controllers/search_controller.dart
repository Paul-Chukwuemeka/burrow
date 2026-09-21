import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../models/book.dart';
import '../services/book_search.dart';
import '../services/document_parser.dart';

class ReaderSearchController extends ChangeNotifier {
  ReaderSearchController({required this.book});

  final Book book;

  BookSearch? _search;
  PdfTextSearcher? _pdfSearcher;
  VoidCallback? _pdfSearcherListener;
  bool _searchOpen = false;
  final TextEditingController searchController = TextEditingController();
  final FocusNode searchFocusNode = FocusNode();
  List<SearchResult> _searchResults = [];
  int _currentResultIndex = -1;
  bool _searchDone = false;

  bool get isPdf => book.format == BookFormat.pdf;
  bool get searchOpen => _searchOpen;
  List<SearchResult> get searchResults => List.unmodifiable(_searchResults);
  int get currentResultIndex => _currentResultIndex;
  bool get searchDone => _searchDone;

  void initPdfSearch(PdfViewerController pdfController) {
    if (!isPdf) return;
    if (_pdfSearcher != null) return;
    _pdfSearcher = PdfTextSearcher(pdfController);
    _pdfSearcherListener = onPdfSearchChanged;
    _pdfSearcher!.addListener(_pdfSearcherListener!);
  }

  PdfTextSearcher? get pdfSearcher => _pdfSearcher;

  BookSearch? get bookSearch => _search;

  void setChapters(List<Chapter> chapters) {
    if (isPdf || _search != null) return;
    _search = BookSearch(
      chapters: chapters,
      onResults: (results) {
        _searchResults = results;
        if (_currentResultIndex == -1 && results.isNotEmpty) {
          _currentResultIndex = 0;
        }
        notifyListeners();
      },
      onDone: () {
        _searchDone = true;
        notifyListeners();
      },
    );
  }

  void onPdfSearchChanged() {
    if (_pdfSearcher == null) return;
    final matches = _pdfSearcher!.matches;
    _searchResults = [
      for (final m in matches)
        SearchResult(chapter: m.pageNumber, offset: 0, length: 0, snippet: ''),
    ];
    _currentResultIndex = _pdfSearcher!.currentIndex ?? -1;
    if (!_pdfSearcher!.isSearching) {
      _searchDone = true;
    }
    notifyListeners();
  }

  void onSearchTextChanged() {
    final q = searchController.text.trim();
    if (q.isEmpty) {
      _pdfSearcher?.resetTextSearch();
      _searchResults = [];
      _currentResultIndex = -1;
      _searchDone = false;
      notifyListeners();
      return;
    }
    _searchDone = false;
    if (isPdf) {
      _pdfSearcher?.startTextSearch(q);
    } else {
      _search?.search(q);
    }
    _currentResultIndex = -1;
    notifyListeners();
  }

  void submitSearch() {
    final q = searchController.text.trim();
    if (q.isEmpty) return;
    _searchDone = false;
    if (isPdf) {
      _pdfSearcher?.startTextSearch(q, searchImmediately: true);
    } else {
      _search?.searchImmediate(q);
    }
    _currentResultIndex = -1;
    notifyListeners();
  }

  void toggleSearch() {
    _searchOpen = !_searchOpen;
    if (_searchOpen) {
      searchFocusNode.requestFocus();
    } else {
      searchController.clear();
      _searchResults = [];
      _currentResultIndex = -1;
      _searchDone = false;
      // Safe: `?.` short-circuits without evaluating the argument when the
      // receiver is null, so `_pdfSearcherListener!` never throws here — but
      // only while both fields are always set/cleared together (see below).
      if (_pdfSearcherListener != null) {
        _pdfSearcher?.removeListener(_pdfSearcherListener!);
      }
      _pdfSearcher?.resetTextSearch();
      _pdfSearcher?.dispose();
      _pdfSearcher = null;
      _pdfSearcherListener = null;
      _search?.dispose();
      _search = null;
    }
    notifyListeners();
  }

  void jumpToResult(int index) {
    if (index < 0 || index >= _searchResults.length) return;
    _currentResultIndex = index;
    notifyListeners();
    if (isPdf) {
      _pdfSearcher?.goToMatchOfIndex(index);
    }
  }

  void prevResult() {
    if (_searchResults.isEmpty) return;
    final idx = _currentResultIndex <= 0
        ? _searchResults.length - 1
        : _currentResultIndex - 1;
    jumpToResult(idx);
  }

  void nextResult() {
    if (_searchResults.isEmpty) return;
    final idx = _currentResultIndex >= _searchResults.length - 1
        ? 0
        : _currentResultIndex + 1;
    jumpToResult(idx);
  }

  @override
  void dispose() {
    _search?.dispose();
    // Same `?.` short-circuit guarantee as in toggleSearch: both fields are
    // set together in initPdfSearch and nulled together above/below.
    if (_pdfSearcherListener != null) {
      _pdfSearcher?.removeListener(_pdfSearcherListener!);
    }
    _pdfSearcher?.resetTextSearch();
    _pdfSearcher?.dispose();
    _pdfSearcher = null;
    _pdfSearcherListener = null;
    searchController.dispose();
    searchFocusNode.dispose();
    super.dispose();
  }
}
