import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../models/book.dart';
import '../models/reader_settings.dart';
import '../services/book_search.dart';
import '../services/document_parser.dart';
import '../services/paginator.dart';

class ReaderSearchController extends ChangeNotifier {
  ReaderSearchController({
    required this.book,
    required this.onJumpToPdfPage,
    required this.onJumpToFlatPage,
    required this.onShowChrome,
  });

  final Book book;
  final void Function(int page) onJumpToPdfPage;
  final void Function(int flatPage) onJumpToFlatPage;
  final VoidCallback onShowChrome;

  BookSearch? _search;
  PdfTextSearcher? _pdfSearcher;
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
    _pdfSearcher!.addListener(_onPdfSearchChanged);
  }

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

  void _onPdfSearchChanged() {
    if (_pdfSearcher == null) return;
    final matches = _pdfSearcher!.matches;
    _searchResults = [
      for (var i = 0; i < matches.length; i++)
        SearchResult(
          chapter: matches[i].pageNumber,
          offset: 0,
          length: 0,
          snippet: 'Page ${matches[i].pageNumber}',
        ),
    ];
    _currentResultIndex = _pdfSearcher!.currentIndex ?? -1;
    if (!_pdfSearcher!.isSearching) {
      _searchDone = true;
    }
    notifyListeners();
  }

  void onSearchTextChanged() {
    final q = searchController.text;
    if (q.isEmpty) {
      _pdfSearcher?.resetTextSearch();
      _searchResults = [];
      _currentResultIndex = -1;
      _searchDone = false;
      notifyListeners();
      return;
    }
    _initSearch();
    _searchDone = false;
    if (isPdf) {
      _pdfSearcher!.startTextSearch(q);
    } else {
      _search?.search(q);
    }
    _currentResultIndex = -1;
    notifyListeners();
  }

  void submitSearch() {
    final q = searchController.text;
    _initSearch();
    _searchDone = false;
    if (isPdf) {
      _pdfSearcher!.startTextSearch(q, searchImmediately: true);
    } else {
      _search?.searchImmediate(q);
    }
  }

  void _initSearch() {
    if (isPdf) {
      if (_pdfSearcher != null) return;
      return;
    }
    if (_search != null) return;
  }

  void toggleSearch({
    required List<Paginator> paginators,
    required int Function(int chapter) flatIndexForChapter,
    required PageController? pageController,
  }) {
    _searchOpen = !_searchOpen;
    if (_searchOpen) {
      searchFocusNode.requestFocus();
    } else {
      searchController.clear();
      _searchResults = [];
      _currentResultIndex = -1;
      _searchDone = false;
      _search?.dispose();
      _search = null;
      _pdfSearcher?.resetTextSearch();
      _pdfSearcher = null;
    }
    notifyListeners();
  }

  void jumpToResult(
    int index, {
    required List<Paginator> paginators,
    required int Function(int chapter) flatIndexForChapter,
    required PageController? pageController,
  }) {
    if (index < 0 || index >= _searchResults.length) return;
    _currentResultIndex = index;
    if (isPdf) {
      _pdfSearcher?.goToMatchOfIndex(index);
    } else {
      final result = _searchResults[index];
      final pag = paginators[result.chapter];
      final pageIndex = pag.pageIndexFor(result.offset);
      final flat = flatIndexForChapter(result.chapter) + pageIndex;
      pageController?.jumpToPage(flat);
    }
    onShowChrome();
    notifyListeners();
  }

  void prevResult({
    required List<Paginator> paginators,
    required int Function(int chapter) flatIndexForChapter,
    required PageController? pageController,
  }) {
    if (_searchResults.isEmpty) return;
    if (isPdf) {
      _pdfSearcher?.goToPrevMatch();
      return;
    }
    final idx = _currentResultIndex <= 0
        ? _searchResults.length - 1
        : _currentResultIndex - 1;
    jumpToResult(
      idx,
      paginators: paginators,
      flatIndexForChapter: flatIndexForChapter,
      pageController: pageController,
    );
  }

  void nextResult({
    required List<Paginator> paginators,
    required int Function(int chapter) flatIndexForChapter,
    required PageController? pageController,
  }) {
    if (_searchResults.isEmpty) return;
    if (isPdf) {
      _pdfSearcher?.goToNextMatch();
      return;
    }
    final idx = _currentResultIndex >= _searchResults.length - 1
        ? 0
        : _currentResultIndex + 1;
    jumpToResult(
      idx,
      paginators: paginators,
      flatIndexForChapter: flatIndexForChapter,
      pageController: pageController,
    );
  }

  Widget buildSearchOverlay(
    ReaderTheme theme, {
    List<Chapter>? chapters,
    required MediaQueryData mediaQuery,
  }) {
    final count = _searchResults.length;
    final isDone = _searchDone;
    return Positioned(
      top: mediaQuery.padding.top + 56,
      left: 8,
      right: 8,
      child: Material(
        elevation: 8,
        borderRadius: BorderRadius.circular(12),
        color: theme.background,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: searchController,
                      focusNode: searchFocusNode,
                      style: TextStyle(color: theme.text, fontSize: 15),
                      decoration: InputDecoration(
                        hintText: 'Search book…',
                        hintStyle: TextStyle(color: theme.muted),
                        border: InputBorder.none,
                        prefixIcon:
                            Icon(Icons.search, color: theme.muted, size: 20),
                        suffixIcon: searchController.text.isNotEmpty
                            ? IconButton(
                                icon:
                                    Icon(Icons.clear, color: theme.muted, size: 20),
                                onPressed: () {
                                  searchController.clear();
                                  onSearchTextChanged();
                                },
                              )
                            : null,
                      ),
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => submitSearch(),
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close, color: theme.muted, size: 20),
                    onPressed: () => toggleSearch(
                      paginators: const [],
                      flatIndexForChapter: (_) => 0,
                      pageController: null,
                    ),
                  ),
                ],
              ),
            ),
            if (count > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
                child: Row(
                  children: [
                    Text(
                      isDone
                          ? '$count match${count == 1 ? '' : 'es'}'
                          : 'Searching… ($count found)',
                      style: TextStyle(color: theme.muted, fontSize: 12),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: Icon(Icons.keyboard_arrow_up, color: theme.text, size: 22),
                      onPressed: () => prevResult(
                        paginators: const [],
                        flatIndexForChapter: (_) => 0,
                        pageController: null,
                      ),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    ),
                    IconButton(
                      icon: Icon(Icons.keyboard_arrow_down, color: theme.text, size: 22),
                      onPressed: () => nextResult(
                        paginators: const [],
                        flatIndexForChapter: (_) => 0,
                        pageController: null,
                      ),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    ),
                  ],
                ),
              ),
            if (count > 0)
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: mediaQuery.size.height * 0.3,
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: count,
                  itemBuilder: (context, i) {
                    final r = _searchResults[i];
                    final isCurrent = i == _currentResultIndex;
                    final label = isPdf
                        ? 'Page ${r.chapter}'
                        : (chapters != null && r.chapter < chapters.length)
                            ? chapters[r.chapter].title.isEmpty
                                ? 'Chapter ${r.chapter + 1}'
                                : chapters[r.chapter].title
                            : 'Chapter ${r.chapter + 1}';
                    return InkWell(
                      onTap: () => jumpToResult(
                        i,
                        paginators: const [],
                        flatIndexForChapter: (_) => 0,
                        pageController: null,
                      ),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                        color: isCurrent
                            ? theme.accent.withValues(alpha: 0.15)
                            : null,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              label,
                              style: TextStyle(
                                color: theme.muted,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              r.snippet,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: theme.text,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            if (count == 0 && isDone)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'No matches found',
                  style: TextStyle(color: theme.muted, fontSize: 13),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    searchController.dispose();
    searchFocusNode.dispose();
    _search?.dispose();
    _pdfSearcher?.resetTextSearch();
    super.dispose();
  }
}
