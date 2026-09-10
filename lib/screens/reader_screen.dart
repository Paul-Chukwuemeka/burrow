import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:share_plus/share_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../controllers/reading_session.dart';
import '../db/database.dart' as db;
import '../services/brightness_controller.dart';
import '../models/book.dart';
import '../models/reader_settings.dart';
import '../models/style_run.dart';
import '../services/book_search.dart';
import '../services/comic_page_provider.dart';
import '../services/document_parser.dart';
import '../services/epub_css_parser.dart';
import '../services/dictionary_service.dart';
import '../services/library_service.dart';
import '../services/paginator.dart';
import '../utils/page_spans.dart';
import '../widgets/book_cover.dart';
import '../widgets/dictionary_sheet.dart';
import '../screens/settings_screen.dart';
import '../widgets/settings_sheet.dart';
import '../widgets/toc_sheet.dart';

class ReaderScreen extends StatefulWidget {
  const ReaderScreen({
    super.key,
    required this.book,
    required this.library,
    this.heroTag,
  });

  final Book book;
  final LibraryService library;

  /// Hero tag matching the library cover that launched this screen; drives
  /// the shared-element cover morph. Null when opened without one (e.g. from
  /// the book-actions sheet).
  final String? heroTag;

  @override
  State<ReaderScreen> createState() => ReaderScreenState();
}

/// State for [ReaderScreen]. Public so tests can reach the settings-change
/// seam without going through the bottom sheet.
class ReaderScreenState extends State<ReaderScreen> with WidgetsBindingObserver {
  ReaderSettings get _settings => widget.library.settings;
  Book get _book => widget.book;

  // Reflowable state.
  ParsedDocument? _doc;
  String? _error;
  String? _layoutSignature; // viewport+style fingerprint of current paginators.

  /// The viewport the reflowable [LayoutBuilder] last laid out with. Settings
  /// changes reuse it so they can never disagree with the layout that produced
  /// the current paginators.
  Size? _lastViewport;
  final List<Paginator> _paginators = [];
  final List<int> _charsBefore = [];
  int _totalChars = 0;
  PageController? _pageController;
  int _flatPage = 0;

  /// The [TextStyle] each `_paginators[i]` was laid out with. Rendering always
  /// uses the chapter's own style, never a freshly-read settings style: during
  /// a lazy repagination the reader's chapter is re-laid out first while the
  /// rest keeps its old layout, so each chapter must render with the style
  /// that produced its page boundaries. Only the color is refreshed (theme
  /// changes re-color instantly and never affect layout).
  List<TextStyle> _chapterStyles = const [];

  // Full-book pagination state.
  bool _paginationRunning = false;
  int _paginationChapter = 0;

  /// Bumped whenever a pagination pass is superseded, so the in-flight chunk
  /// loop of the previous pass exits instead of interleaving with the new one.
  int _paginationGeneration = 0;

  /// `(chapter, offsetInChapter)` to land on when the running pass finishes.
  /// Null means "use the book's saved position".
  (int, int)? _pendingRestore;

  // Lazy pagination: cache + background drivers.
  final Map<String, List<Paginator>> _paginationCache = {};
  final Map<int, ChapterPaginationDriver> _bgDrivers = {};
  int _bgChapter = 0;
  int _bgGeneration = 0;
  bool _lazyRunning = false;

  /// Temporary buffer for paginators being built in the background.
  /// Not swapped into [_paginators] until the entire pass finishes,
  /// so the live PageView always sees a consistent set.
  List<Paginator>? _bgPaginators;

  /// The layout signature an in-flight background pass is building. While set,
  /// the live paginators still describe the old signature, so rebuilds that
  /// see this exact signature must not start another pass.
  String? _bgTargetSignature;

  bool _chromeVisible = false;
  Timer? _saveDebounce;

  // Comic preview slider.
  bool _comicPreviewVisible = false;
  final ScrollController _comicPreviewScrollController = ScrollController();

  // Reading session state.
  late final ReadingSessionManager _sessionCtrl;

  // Bookmark state.
  List<db.Bookmark> _bookmarks = [];
  bool _isCurrentPageBookmarked = false;

  // Search state.
  BookSearch? _search;
  PdfTextSearcher? _pdfSearcher;
  bool _searchOpen = false;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  List<SearchResult> _searchResults = [];
  int _currentResultIndex = -1;
  bool _searchDone = false;

  // PDF state.
  final PdfViewerController _pdfController = PdfViewerController();
  int _pdfPage = 1;
  int _pdfPageCount = 0;
  List<PdfOutlineNode> _pdfOutline = [];
  bool _pdfLoading = true;
  late final bool _pdfFileExists = File(_book.path).existsSync();

  // Comic state.
  List<Uint8List> _comicPages = [];
  int _comicPage = 0;
  bool _comicLoading = true;
  ScrollController? _comicVerticalScrollController;
  bool _comicVerticalListenerAttached = false;

  // Lazy comic loading (CBZ only).
  ComicPageProvider? _comicPageProvider;
  final Set<int> _comicPagesLoading = {};
  bool get _comicLazy => _comicPageProvider != null;
  int get _comicPageCount =>
      _comicLazy ? _comicPageProvider!.pageCount : _comicPages.length;

  // Dictionary state.
  OverlayEntry? _dictionaryButtonEntry;
  ({int start, int end})? _selectedWordRange;

  bool get _isPdf => _book.format == BookFormat.pdf;
  bool get _isComic => _book.format == BookFormat.cbz || _book.format == BookFormat.cbr;
  bool get _showSearch => !_isComic;
  bool get _showToc => !_isComic;
  bool get _showBookmark => !_isComic;

  BoxFit get _comicBoxFit => switch (_settings.comicFitMode) {
        ComicFitMode.fitWidth => BoxFit.fitWidth,
        ComicFitMode.fitHeight => BoxFit.fitHeight,
        ComicFitMode.contain => BoxFit.contain,
      };

  @override
  void initState() {
    super.initState();
    _sessionCtrl = ReadingSessionManager(
      library: widget.library,
      book: _book,
    );
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    if (_settings.keepScreenOn) WakelockPlus.enable();
    BrightnessController.instance.apply(_settings.brightness);
    _loadBookmarks();
    _sessionCtrl.startSession();
    if (_isPdf) {
      _pdfController.addListener(_onPdfViewChanged);
    } else if (!_isComic) {
      _loadDocument();
    }
    if (_isComic) {
      _loadComicPages();
    }
    _searchController.addListener(_onSearchTextChanged);
  }

  Future<void> _loadBookmarks() async {
    final bms = await widget.library.getBookmarks(_book.id);
    if (!mounted) return;
    setState(() => _bookmarks = bms);
    _checkBookmarkState();
  }

  void _checkBookmarkState() {
    if (_isPdf) {
      // For PDF, check if any bookmark matches the current page number.
      final currentPdfPage = _pdfPage;
      final found = _bookmarks.any((bm) => bm.chapter == currentPdfPage);
      if (mounted) setState(() => _isCurrentPageBookmarked = found);
      return;
    }
    final ref = _refAt(_flatPage);
    if (ref == null || _doc == null) return;
    final offset = _paginators[ref.$1].pages[ref.$2].start;
    final capturedPage = _flatPage;
    widget.library
        .isBookmarked(
          bookId: _book.id,
          chapter: ref.$1,
          offset: offset,
        )
        .then((v) {
      if (mounted && _flatPage == capturedPage) {
        setState(() => _isCurrentPageBookmarked = v);
      }
    });
  }

  Future<void> _toggleBookmark() async {
    if (_isPdf) {
      // For PDF, store the page number in the chapter field.
      final page = _pdfPage;
      if (_isCurrentPageBookmarked) {
        for (final bm in _bookmarks) {
          if (bm.chapter == page) {
            await widget.library.deleteBookmark(bm.id);
            break;
          }
        }
      } else {
        await widget.library.addBookmark(
          bookId: _book.id,
          chapter: page,
          offset: 0,
          snippet: 'Page $page',
        );
      }
      await _loadBookmarks();
      return;
    }
    final ref = _refAt(_flatPage);
    if (ref == null || _doc == null) return;
    final chapter = ref.$1;
    final offset = _paginators[chapter].pages[ref.$2].start;
    final pageText = _doc!.chapters[chapter].body;
    final end = (offset + 60).clamp(0, pageText.length);
    final snippet = pageText.substring(offset, end).trim();

    if (_isCurrentPageBookmarked) {
      // Find and delete the bookmark at this position using the in-memory list.
      for (final bm in _bookmarks) {
        if (bm.chapter == chapter && bm.offset == offset) {
          await widget.library.deleteBookmark(bm.id);
          break;
        }
      }
    } else {
      await widget.library.addBookmark(
        bookId: _book.id,
        chapter: chapter,
        offset: offset,
        snippet: snippet,
      );
    }
    await _loadBookmarks();
  }

  /// The controller is a `ValueListenable<Matrix4>`; poll page state on change.
  void _onPdfViewChanged() {
    if (!_pdfController.isReady) return;
    final count = _pdfController.pageCount;
    final page = _pdfController.pageNumber ?? 1;
    if (count == 0) return;
    if (page != _pdfPage || count != _pdfPageCount) {
      setState(() {
        _pdfPage = page;
        _pdfPageCount = count;
      });
      _onPositionChanged(page - 1, 0);
      _checkBookmarkState();
    }
  }

  Future<void> _loadPdfOutline(PdfDocument document) async {
    try {
      final outline = await document.loadOutline();
      if (!mounted) return;
      setState(() => _pdfOutline = outline);
    } catch (e) {
      // Outline not available for this PDF.
      debugPrint('Failed to load PDF outline: $e');
    }
  }

  void _jumpToPdfPage(int pageNumber) {
    if (!_pdfController.isReady) return;
    _pdfController.goToPage(pageNumber: pageNumber);
    if (!_chromeVisible) {
      setState(() => _chromeVisible = true);
    }
  }

  Future<void> _loadDocument() async {
    try {
      final doc = await DocumentParser.parse(_book.path, _book.format);
      // Load embedded fonts (e.g. from @font-face rules in EPUB stylesheets).
      if (doc.fontFaces.isNotEmpty) {
        await EpubCssParser.loadEmbeddedFonts(doc.fontFaces);
      }
      var cumulative = 0;
      _charsBefore.clear();
      for (final c in doc.chapters) {
        _charsBefore.add(cumulative);
        cumulative += c.body.length;
      }
      _totalChars = cumulative;
      if (!mounted) return;
      // Pagination is kicked off by the reflowable LayoutBuilder, which owns
      // the viewport. Deriving it from a second place risks a signature that
      // disagrees with the layout and repaginating forever.
      setState(() => _doc = doc);
    } on FormatException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (e) {
      if (!mounted) return;
      debugPrint('Failed to open document: $e');
      setState(() => _error = 'Could not open this document');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sessionCtrl.dispose();
    _saveDebounce?.cancel();
    _flushSave();
    _settingsSaveDebounce?.cancel();
    widget.library.saveSettings();
    _pageController?.dispose();
    for (final d in _paginationDrivers.values) {
      d.dispose();
    }
    _paginationDrivers.clear();
    for (final d in _bgDrivers.values) {
      d.dispose();
    }
    _bgDrivers.clear();
    _paginationCache.clear();
    if (_isPdf) _pdfController.removeListener(_onPdfViewChanged);
    _search?.dispose();
    _pdfSearcher?.resetTextSearch();
    _pdfSearcher = null;
    _searchController.dispose();
    _searchFocusNode.dispose();
    _dictionaryButtonEntry?.remove();
    _dictionaryButtonEntry = null;
    _selectedWordRange = null;
    _comicPageController?.dispose();
    _comicVerticalScrollController?.dispose();
    _comicVerticalListenerAttached = false;
    _comicPageProvider?.dispose();
    _comicPageProvider = null;
    _comicPreviewScrollController.dispose();
    WakelockPlus.disable();
    BrightnessController.instance.reset();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([]);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _sessionCtrl.onLifecycleChanged(state);
    if (state == AppLifecycleState.resumed) {
      BrightnessController.instance.apply(_settings.brightness);
    }
  }

  // ---------------------------------------------------------------------------
  // Position persistence
  // ---------------------------------------------------------------------------

  void _onPositionChanged(int chapter, int offsetInChapter) {
    _sessionCtrl.onPageFlipped();
    final progress = _totalChars == 0
        ? 0.0
        : (_charsBefore[chapter] + offsetInChapter) / _totalChars;
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 600), () {
      widget.library.savePosition(
        id: _book.id,
        chapter: chapter,
        offset: offsetInChapter,
        progress: progress,
      );
    });
  }

  void _flushSave() {
    if (_isPdf) {
      if (_pdfPageCount > 0) {
        widget.library.savePosition(
          id: _book.id,
          chapter: _pdfPage - 1,
          offset: 0,
          progress: _pdfPage / _pdfPageCount,
        );
      }
      return;
    }
    if (_doc == null) return;
    // Mid-repagination _paginators mixes old and new layouts, so _flatPage no
    // longer resolves to real text. The pass already captured where we were.
    final pending = _pendingRestore;
    if (pending != null) {
      _savePositionFor(pending.$1, pending.$2);
      return;
    }
    final ref = _refAt(_flatPage);
    if (ref == null) return;
    _savePositionFor(ref.$1, _paginators[ref.$1].pages[ref.$2].start);
  }

  void _savePositionFor(int chapter, int offset) {
    widget.library.savePosition(
      id: _book.id,
      chapter: chapter,
      offset: offset,
      progress: _totalChars == 0
          ? 0
          : (_charsBefore[chapter] + offset) / _totalChars,
    );
  }

  // ---------------------------------------------------------------------------
  // Reflowable pagination
  // ---------------------------------------------------------------------------

  String _signatureFor(Size viewport, TextStyle style, TextScaler scaler) =>
      '${viewport.width}x${viewport.height}|${style.fontSize}|'
      '${style.height}|${style.fontFamily}|${scaler.scale(10)}|'
      '${_settings.textJustification.name}|${_settings.horizontalMargin}';

  Paginator _emptyPaginator() => Paginator.paginate(
        text: '',
        style: const TextStyle(),
        maxWidth: 100,
        maxHeight: 100,
        direction: TextDirection.ltr,
      );

  /// Maps a flat page index to `(chapter, pageIndex)`, or null when out of
  /// range.
  (int, int)? _refAt(int flatIndex) {
    var remaining = flatIndex;
    for (var c = 0; c < _paginators.length; c++) {
      final count = _paginators[c].pages.length;
      if (remaining < count) return (c, remaining);
      remaining -= count;
    }
    return null;
  }

  int get _flatPageCount =>
      _paginators.fold(0, (sum, p) => sum + p.pages.length);

  Size _contentViewport(Size screen) =>
      Size(screen.width - _settings.horizontalMargin * 2, screen.height - 56);

  /// Height of the chapter-title heading rendered on a chapter's first page
  /// (title + spacing), which pagination must reserve there.
  double _titleInset(
    int chapter,
    Size viewport,
    TextStyle style,
    TextScaler scaler,
  ) {
    final title = _doc!.chapters[chapter].title;
    if (title.isEmpty) return 0;
    final titleStyle = style.copyWith(
      fontSize: (style.fontSize ?? 18) + 4,
      fontWeight: FontWeight.w700,
    );
    final tp = TextPainter(
      text: TextSpan(text: title, style: titleStyle),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout(maxWidth: viewport.width);
    final inset = tp.height + 16;
    tp.dispose();
    return inset;
  }

  // ---------------------------------------------------------------------------
  // Repagination (settings change or rotation), keeping position stable
  // ---------------------------------------------------------------------------

  /// Re-lay out the whole book for a new viewport or text style, landing back
  /// on the text the reader was on.
  ///
  /// Uses a cache keyed by layout signature: if we've paginated at this
  /// exact (viewport, font, lineHeight, fontFamily, textScaler) before,
  /// the swap is instant. Otherwise the chapter the reader is on is re-laid
  /// out synchronously so the new style is visible immediately, and every
  /// other chapter is paginated into a background buffer and swapped in
  /// atomically when the pass finishes. No progress indicator; the reader
  /// stays interactive throughout.
  void _repaginateKeepingPosition() {
    if (_doc == null || !mounted) return;
    final viewport = _lastViewport;
    if (viewport == null) return;
    final style = _settings.textStyle(context);
    final scaler = MediaQuery.textScalerOf(context);

    // Capture the position only if a pass isn't already running: mid-pass
    // _paginators mixes layouts, so re-reading _flatPage would resolve the
    // wrong text. The first change's target is kept for the whole pass.
    {
      final ref = _refAt(_flatPage);
      _pendingRestore ??= switch (ref) {
        (final c, final p)
            when c >= 0 &&
                c < _paginators.length &&
                p >= 0 &&
                p < _paginators[c].pages.length =>
          (c, _paginators[c].pages[p].start),
        _ => (0, 0),
      };
    }

    final sig = _signatureFor(viewport, style, scaler);

    // --- Cache hit: swap paginators instantly, no repagination needed. ---
    final cached = _paginationCache[sig];
    if (cached != null && cached.length >= _doc!.chapters.length) {
      _cancelBackground();
      _applyPaginators(cached, style, sig);
      final pending = _pendingRestore;
      _pendingRestore = null;
      if (pending != null) _jumpToPosition(pending);
      setState(() {});
      return;
    }

    // --- Cache miss: re-paginate the visible chapter now, the rest later. ---
    // The chapter the reader is on (and the next one) are laid out
    // synchronously so swiping forward feels instant; the remaining chapters
    // paginate in the background and swap in atomically.
    _cancelBackground();
    _lazyRunning = true;
    _bgTargetSignature = sig;

    final pending = _pendingRestore!;
    final currentChapter = pending.$1;
    _paginateChapterNow(currentChapter, viewport, style, scaler);

    final nextChapter = currentChapter + 1;
    final skip = {currentChapter};
    if (nextChapter < _doc!.chapters.length) {
      _paginateChapterNow(nextChapter, viewport, style, scaler);
      skip.add(nextChapter);
    }

    _jumpToPosition(pending);

    _bgPaginators = List.generate(
      _doc!.chapters.length,
      (i) => _paginators.length > i ? _paginators[i] : _emptyPaginator(),
    );

    _bgChapter = 0;
    _bgGeneration++;
    final bgGen = _bgGeneration;
    _bgNextBatch(viewport, style, scaler, bgGen, skipChapters: skip);
  }

  /// Replace one chapter's paginator in place with a fresh layout at [style].
  /// The anchor chapter is the only one the reader is looking at, so this
  /// stays on the UI thread; the rest of the book is paginated lazily.
  void _paginateChapterNow(
    int chapter,
    Size viewport,
    TextStyle style,
    TextScaler scaler,
  ) {
    final paginator = Paginator.paginate(
      text: _doc!.chapters[chapter].body,
      style: style,
      maxWidth: viewport.width,
      maxHeight: viewport.height,
      direction: TextDirection.ltr,
      firstPageInset: _titleInset(chapter, viewport, style, scaler),
      textScaler: scaler,
      runs: _doc!.chapters[chapter].runs,
    );
    while (_paginators.length <= chapter) {
      _paginators.add(_emptyPaginator());
    }
    _paginators[chapter] = paginator;
    if (_chapterStyles.length <= chapter) {
      _chapterStyles = List.filled(chapter + 1, style);
    }
    _chapterStyles[chapter] = style;
  }

  void _cancelBackground() {
    _bgGeneration++;
    for (final d in _bgDrivers.values) {
      d.dispose();
    }
    _bgDrivers.clear();
    _lazyRunning = false;
    _bgPaginators = null;
    _bgTargetSignature = null;
  }

  void _bgNextBatch(
    Size viewport,
    TextStyle style,
    TextScaler scaler,
    int generation, {
    required Set<int> skipChapters,
  }) {
    if (!mounted || _doc == null) return;
    if (generation != _bgGeneration) return;
    final bg = _bgPaginators;
    if (bg == null) return;
    final stopwatch = Stopwatch()..start();

    while (_bgChapter < _doc!.chapters.length) {
      final c = _bgChapter;
      if (skipChapters.contains(c)) {
        _bgChapter++;
        continue;
      }

      var driver = _bgDrivers[c];
      if (driver == null) {
        driver = ChapterPaginationDriver(
          text: _doc!.chapters[c].body,
          style: style,
          maxWidth: viewport.width,
          maxHeight: viewport.height,
          direction: TextDirection.ltr,
          firstPageInset: _titleInset(c, viewport, style, scaler),
          textScaler: scaler,
          runs: _doc!.chapters[c].runs,
          images: _doc!.chapters[c].images,
        );
        _bgDrivers[c] = driver;
      }

      driver.nextChunk(5);

      if (driver.isDone) {
        bg[c] = driver.toPaginator();
        driver.dispose();
        _bgDrivers.remove(c);
        _bgChapter++;
      }

      if (stopwatch.elapsedMilliseconds > 10) {
        if (mounted) setState(() {});
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _bgGeneration == generation) {
            _bgNextBatch(viewport, style, scaler, generation,
                skipChapters: skipChapters);
          }
        });
        return;
      }
    }

    // All background chapters done — swap the buffer into live paginators.
    final pending = _pendingRestore;
    _pendingRestore = null;
    _bgPaginators = null;
    _lazyRunning = false;

    final doneSig = _bgTargetSignature;
    _bgTargetSignature = null;
    _applyPaginators(bg, style, doneSig);
    if (doneSig != null) {
      _paginationCache[doneSig] = List.unmodifiable(_paginators);
    }

    if (pending != null) _jumpToPosition(pending);
    if (mounted) setState(() {});
  }

  /// Swap a full paginator set in as the live layout and record its style.
  void _applyPaginators(List<Paginator> pages, TextStyle style, String? sig) {
    _paginators
      ..clear()
      ..addAll(pages);
    _chapterStyles = List.filled(_paginators.length, style);
    if (sig != null) _layoutSignature = sig;
  }

  /// Jump the (persistent) controller to the page holding [position] —
  /// `(chapter, offsetInChapter)`. The jump is deferred to a post-frame
  /// callback because the controller's max extent only updates once the next
  /// layout sees the changed page count, and `jumpTo` clamps to it.
  void _jumpToPosition((int, int) position) {
    final controller = _pageController;
    if (controller == null || _doc == null) return;
    final chapter = position.$1.clamp(0, _doc!.chapters.length - 1);
    final offset = position.$2;
    final flat = _flatIndexForChapter(chapter);
    final pageIdx = math.max(
      0,
      offset > 0 ? _paginators[chapter].pageIndexFor(offset) : 0,
    );
    setState(() => _flatPage = flat + pageIdx);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _pageController != controller) return;
      controller.jumpToPage(flat + pageIdx);
    });
  }

  /// Test-only: runs the same path [SettingsSheet]'s `onChanged` callback does
  /// after the caller has mutated `library.settings`.
  @visibleForTesting
  void debugApplySettingsChange() => _onSettingsChanged();

  /// Test-only: whether the document has finished parsing.
  @visibleForTesting
  bool get debugHasDocument => _doc != null;

  /// Test-only: whether a chunked pagination pass is in flight.
  @visibleForTesting
  bool get debugPaginationRunning => _paginationRunning;

  @visibleForTesting
  bool get debugLazyRunning => _lazyRunning;

  @visibleForTesting
  int get debugChapterCount => _doc?.chapters.length ?? -1;
  @visibleForTesting
  int get debugPaginatorCount => _paginators.length;
  @visibleForTesting
  int get debugFlatPageCount => _flatPageCount;
  @visibleForTesting
  bool get debugHasController => _pageController != null;

  /// Coalesces settings persistence: a slider drag commits once, but the
  /// debounce net or a quick run of discrete tweaks shouldn't hit disk each
  /// time.
  Timer? _settingsSaveDebounce;

  void _onSettingsChanged() {
    _settingsSaveDebounce?.cancel();
    _settingsSaveDebounce = Timer(const Duration(milliseconds: 600), () {
      widget.library.saveSettings();
    });
    // Update wakelock.
    if (_settings.keepScreenOn) {
      WakelockPlus.enable();
    } else {
      WakelockPlus.disable();
    }
    // Apply hardware brightness.
    BrightnessController.instance.apply(_settings.brightness);
    // Relayout PDF when scroll direction changes.
    if (_isPdf && _pdfController.isReady) {
      _pdfController.invalidate();
    }
    // Repaginate only when the layout-affecting signature changed.
    final viewport = _lastViewport;
    if (!_isPdf && _doc != null && viewport != null) {
      final style = _settings.textStyle(context);
      final scaler = MediaQuery.textScalerOf(context);
      final sig = _signatureFor(viewport, style, scaler);
      // Skip when the live layout already matches, or a background pass for
      // exactly this signature is already in flight.
      if (sig != _layoutSignature && sig != _bgTargetSignature) {
        _repaginateKeepingPosition();
      }
    }
    setState(() {});
  }

  // USB HID Consumer usage codes for volume keys.
  static const _volumeUpHid = 0x000C00E9;
  static const _volumeDownHid = 0x000C00EA;

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (!_settings.volumeKeyTurns) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final usage = event.physicalKey.usbHidUsage;
    if (usage == _volumeUpHid) {
      _flip(-1);
      return KeyEventResult.handled;
    } else if (usage == _volumeDownHid) {
      _flip(1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ---------------------------------------------------------------------------
  // Search
  // ---------------------------------------------------------------------------

  void _initSearch() {
    if (_isPdf) {
      if (_pdfSearcher != null) return;
      _pdfSearcher = PdfTextSearcher(_pdfController);
      _pdfSearcher!.addListener(_onPdfSearchChanged);
      return;
    }
    if (_doc == null || _search != null) return;
    _search = BookSearch(
      chapters: _doc!.chapters,
      onResults: (results) {
        if (!mounted) return;
        setState(() {
          _searchResults = results;
          if (_currentResultIndex == -1 && results.isNotEmpty) {
            _currentResultIndex = 0;
          }
        });
      },
      onDone: () {
        if (!mounted) return;
        setState(() => _searchDone = true);
      },
    );
  }

  void _onPdfSearchChanged() {
    if (!mounted || _pdfSearcher == null) return;
    final matches = _pdfSearcher!.matches;
    setState(() {
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
    });
  }

  void _onSearchTextChanged() {
    final q = _searchController.text;
    if (q.isEmpty) {
      _pdfSearcher?.resetTextSearch();
      setState(() {
        _searchResults = [];
        _currentResultIndex = -1;
        _searchDone = false;
      });
      return;
    }
    _initSearch();
    _searchDone = false;
    if (_isPdf) {
      _pdfSearcher!.startTextSearch(q);
    } else {
      _search?.search(q);
    }
    setState(() => _currentResultIndex = -1);
  }

  void _submitSearch() {
    final q = _searchController.text;
    _initSearch();
    _searchDone = false;
    if (_isPdf) {
      _pdfSearcher!.startTextSearch(q, searchImmediately: true);
    } else {
      _search?.searchImmediate(q);
    }
  }

  void _toggleSearch() {
    setState(() {
      _searchOpen = !_searchOpen;
      if (_searchOpen) {
        _searchFocusNode.requestFocus();
      } else {
        _searchController.clear();
        _searchResults = [];
        _currentResultIndex = -1;
        _searchDone = false;
        _search?.dispose();
        _search = null;
        _pdfSearcher?.resetTextSearch();
        _pdfSearcher = null;
      }
    });
  }

  void _jumpToResult(int index) {
    if (index < 0 || index >= _searchResults.length) return;
    setState(() => _currentResultIndex = index);
    if (_isPdf) {
      _pdfSearcher?.goToMatchOfIndex(index);
    } else {
      final result = _searchResults[index];
      final pag = _paginators[result.chapter];
      final pageIndex = pag.pageIndexFor(result.offset);
      final flat = _flatIndexForChapter(result.chapter) + pageIndex;
      _pageController?.jumpToPage(flat);
    }
    if (!_chromeVisible) {
      setState(() => _chromeVisible = true);
    }
  }

  void _prevResult() {
    if (_searchResults.isEmpty) return;
    if (_isPdf) {
      _pdfSearcher?.goToPrevMatch();
      return;
    }
    final idx = _currentResultIndex <= 0
        ? _searchResults.length - 1
        : _currentResultIndex - 1;
    _jumpToResult(idx);
  }

  void _nextResult() {
    if (_searchResults.isEmpty) return;
    if (_isPdf) {
      _pdfSearcher?.goToNextMatch();
      return;
    }
    final idx = _currentResultIndex >= _searchResults.length - 1
        ? 0
        : _currentResultIndex + 1;
    _jumpToResult(idx);
  }

  Widget _buildSearchOverlay(ReaderTheme theme) {
    final count = _searchResults.length;
    final isDone = _searchDone;
    return Positioned(
      top: MediaQuery.paddingOf(context).top + 56,
      left: 8,
      right: 8,
      child: Material(
        elevation: 8,
        borderRadius: BorderRadius.circular(12),
        color: theme.background,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Search input row.
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      focusNode: _searchFocusNode,
                      style: TextStyle(color: theme.text, fontSize: 15),
                      decoration: InputDecoration(
                        hintText: 'Search book…',
                        hintStyle: TextStyle(color: theme.muted),
                        border: InputBorder.none,
                        prefixIcon:
                            Icon(Icons.search, color: theme.muted, size: 20),
                        suffixIcon: _searchController.text.isNotEmpty
                            ? IconButton(
                                icon:
                                    Icon(Icons.clear, color: theme.muted, size: 20),
                                onPressed: () {
                                  _searchController.clear();
                                  _onSearchTextChanged();
                                },
                              )
                            : null,
                      ),
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => _submitSearch(),
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close, color: theme.muted, size: 20),
                    onPressed: _toggleSearch,
                  ),
                ],
              ),
            ),
            // Result count + prev/next.
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
                      onPressed: _prevResult,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    ),
                    IconButton(
                      icon: Icon(Icons.keyboard_arrow_down, color: theme.text, size: 22),
                      onPressed: _nextResult,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    ),
                  ],
                ),
              ),
            if (count > 0)
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.3,
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: count,
                  itemBuilder: (context, i) {
                    final r = _searchResults[i];
                    final isCurrent = i == _currentResultIndex;
                    final label = _isPdf
                        ? 'Page ${r.chapter}'
                        : (_doc?.chapters[r.chapter].title ?? '').isEmpty
                            ? 'Chapter ${r.chapter + 1}'
                            : _doc!.chapters[r.chapter].title;
                    return InkWell(
                      onTap: () => _jumpToResult(i),
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

  // ---------------------------------------------------------------------------
  // Word selection toolbar
  // ---------------------------------------------------------------------------

  void _showWordToolbar(Offset globalPosition, String word, int bodyStart, int bodyEnd) {
    _dismissDictionaryButton();
    setState(() => _selectedWordRange = (start: bodyStart, end: bodyEnd));

    _dictionaryButtonEntry = OverlayEntry(
      builder: (context) {
        final theme = _settings.colors;
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _dismissDictionaryButton,
              ),
            ),
            Positioned(
              left: (globalPosition.dx - 140).clamp(8.0, MediaQuery.sizeOf(context).width - 296.0),
              top: (globalPosition.dy - 56).clamp(0.0, MediaQuery.sizeOf(context).height - 60),
              child: Material(
                color: Colors.transparent,
                child: Container(
                  decoration: BoxDecoration(
                    color: theme.background,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.2),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _toolbarButton(
                        label: 'Define',
                        onTap: () {
                          _dismissDictionaryButton();
                          _openDictionarySheet(word);
                        },
                        theme: theme,
                      ),
                      _toolbarDivider(theme: theme),
                      _toolbarButton(
                        label: 'Copy',
                        onTap: () {
                          _dismissDictionaryButton();
                          Clipboard.setData(ClipboardData(text: word));
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Copied "$word"'),
                              duration: const Duration(seconds: 1),
                            ),
                          );
                        },
                        theme: theme,
                      ),
                      _toolbarDivider(theme: theme),
                      _toolbarButton(
                        label: 'Share',
                        onTap: () {
                          _dismissDictionaryButton();
                          SharePlus.instance.share(ShareParams(text: word));
                        },
                        theme: theme,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );

    Overlay.of(context).insert(_dictionaryButtonEntry!);
  }

  Widget _toolbarButton({
    required String label,
    required VoidCallback onTap,
    required ReaderTheme theme,
  }) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: theme.text,
          ),
        ),
      ),
    );
  }

  Widget _toolbarDivider({required ReaderTheme theme}) {
    return Container(
      width: 1,
      height: 20,
      color: theme.muted.withValues(alpha: 0.3),
    );
  }

  void _dismissDictionaryButton() {
    _dictionaryButtonEntry?.remove();
    _dictionaryButtonEntry = null;
    if (_selectedWordRange != null) {
      setState(() => _selectedWordRange = null);
    }
  }

  void _openDictionarySheet(String word) {
    if (DictionaryService.instance.isDownloaded) {
      DictionarySheet.show(
        context,
        word: word.toLowerCase(),
        theme: _settings.colors,
      );
    } else {
      _showDownloadDialog(word);
    }
  }

  void _showDownloadDialog(String word) {
    final theme = _settings.colors;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: theme.background,
        title: Text(
          'Download dictionary?',
          style: TextStyle(color: theme.text),
        ),
        content: Text(
          'The offline dictionary (~40 MB) is needed to look up word definitions.\n\nDownload now?',
          style: TextStyle(color: theme.muted, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('Cancel', style: TextStyle(color: theme.muted)),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              SettingsScreen.show(
                context,
                library: widget.library,
                autoDownloadDictionary: true,
              );
            },
            child: Text('Download', style: TextStyle(color: theme.accent)),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = _settings.colors;
    Widget body;
    if (_error != null) {
      body = _ErrorView(message: _error!);
    } else if (_isPdf) {
      body = _buildPdf(theme);
    } else if (_isComic) {
      body = _buildComic(theme);
    } else {
      body = _buildReflowable(context, theme);
    }
    return Scaffold(
      backgroundColor: theme.background,
      body: Focus(
        autofocus: true,
        onKeyEvent: _handleKeyEvent,
        child: Stack(
          children: [
            body,
            if (widget.heroTag != null)
              Hero(
                tag: widget.heroTag!,
                child: _CoverIntroOverlay(book: _book),
              ),
          ],
        ),
      ),
    );
  }

  // ------------------------------- PDF ---------------------------------------

  Widget _buildPdf(ReaderTheme theme) {
    if (!_pdfFileExists) {
      return const _ErrorView(message: 'File not found');
    }
    final viewer = PdfViewer.file(
      _book.path,
      initialPageNumber:
          _book.lastChapter + 1 < 1 ? 1 : _book.lastChapter + 1,
      controller: _pdfController,
        params: PdfViewerParams(
          backgroundColor: theme.background,
          textSelectionParams: PdfTextSelectionParams(
            enabled: true,
            onTextSelectionChange: (selection) async {
              if (!selection.hasSelectedText) {
                _dismissDictionaryButton();
                return;
              }
              final selectedText = await selection.getSelectedText();
              if (!mounted) return;
              final trimmed = selectedText.trim();
              if (trimmed.isNotEmpty && trimmed.length < 50) {
                final words = trimmed.split(RegExp(r'\s+'));
                final word = words.first.replaceAll(RegExp(r'[^a-zA-Z\u00C0-\u024F]'), '');
                if (word.length >= 2) {
                  final size = MediaQuery.sizeOf(context);
                  _showWordToolbar(
                    Offset(size.width / 2, size.height / 2),
                    word,
                    0,
                    0,
                  );
                }
              }
            },
          ),
          scrollPhysics: _settings.pdfContinuousScroll
              ? null
              : const NeverScrollableScrollPhysics(),
          layoutPages: _settings.pdfLayoutDirection == PdfLayoutDirection.vertical
              ? null
              : (pages, params) {
                  final margin = params.margin;
                  final height = pages.fold(
                          0.0,
                          (prev, page) => math.max(prev, page.height)) +
                      margin * 2;
                  final pageLayouts = <Rect>[];
                  double x = margin;
                  final rtl = _settings.pdfLayoutDirection ==
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
          setState(() => _pdfLoading = false);
          _loadPdfOutline(document);
        },
        viewerOverlayBuilder: (context, size, handleLinkTap) => [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTapUp: _handleTapZones(
                onCenter: () =>
                    setState(() => _chromeVisible = !_chromeVisible),
              ),
            ),
          ),
        ],
        pagePaintCallbacks: [
          if (_pdfSearcher != null)
            _pdfSearcher!.pageTextMatchPaintCallback,
        ],
      ),
    );

    return Stack(
      children: [
        Positioned.fill(child: viewer),
        if (_pdfLoading)
          Positioned.fill(
            child: Container(
              color: theme.background,
              child: Center(
                child: CircularProgressIndicator(color: theme.accent),
              ),
            ),
          ),
        IgnorePointer(
          ignoring: !_chromeVisible,
          child: _chrome(
            centerLabel:
                _pdfPageCount == 0 ? '-/-' : 'Page $_pdfPage of $_pdfPageCount',
            sliderMax: _pdfPageCount > 1 ? _pdfPageCount : 1,
            sliderValue: _pdfPage.clamp(1, _pdfPageCount > 0 ? _pdfPageCount : 1),
            sliderLabel: _pdfPageCount == 0
                ? '-/-'
                : '${((_pdfPage / _pdfPageCount) * 100).round()}%',
            onSliderChanged: (v) {
              if (_pdfController.isReady) _pdfController.goToPage(pageNumber: v);
            },
          ),
        ),
      ],
    );
  }

  // ---------------------------- Comic ----------------------------------------

  Future<void> _loadComicPages() async {
    try {
      // CBZ: lazy load via provider (fast open, pages on demand).
      if (_book.format == BookFormat.cbz) {
        final provider = await ComicPageProvider.open(_book.path);
        if (!mounted) return;
        _comicPageProvider = provider;
        _comicPage = _book.lastChapter.clamp(0, provider.pageCount - 1);
        // Load the current page synchronously so the reader is never blank.
        final firstBytes = await provider.loadPage(_comicPage);
        if (!mounted) return;
        setState(() {
          _comicPages = [firstBytes];
          _comicLoading = false;
        });
        _comicPageController = PageController(
          initialPage: _comicPage.clamp(0, math.max(0, _comicPageCount - 1)),
        );
        // Prefetch surrounding pages after the first frame.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _prefetchComicPages(_comicPage);
          _restoreComicPosition();
        });
        return;
      }

      // CBR / fallback: load all pages up front (existing behaviour).
      final doc = await DocumentParser.parse(_book.path, _book.format);
      final pages = <Uint8List>[];
      for (final chapter in doc.chapters) {
        for (final img in chapter.images) {
          pages.add(img.bytes);
        }
      }
      if (!mounted) return;
      setState(() {
        _comicPages = pages;
        _comicPage = _book.lastChapter.clamp(0, pages.length - 1);
        _comicLoading = false;
      });
      _comicPageController = PageController(
        initialPage: _comicPage.clamp(0, math.max(0, _comicPages.length - 1)),
      );
      _restoreComicPosition();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Failed to load comic: $e';
        _comicLoading = false;
      });
    }
  }

  void _restoreComicPosition() {
    if (_settings.comicReadingMode == ComicReadingMode.vertical) {
      _comicVerticalScrollController ??= ScrollController();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _comicVerticalScrollController == null) return;
        final offset = _book.lastOffset;
        if (offset > 0) {
          _comicVerticalScrollController!.jumpTo(offset.toDouble());
        }
      });
    }
  }

  Widget _buildComic(ReaderTheme theme) {
    if (_comicLoading) {
      return Center(child: CircularProgressIndicator(color: theme.accent));
    }
    if (_comicPages.isEmpty) {
      return const _ErrorView(message: 'No pages found in comic');
    }
    if (_settings.comicReadingMode == ComicReadingMode.vertical) {
      return _buildComicVertical(theme);
    }
    return _buildComicPaginated(theme);
  }

  Widget _buildComicPaginated(ReaderTheme theme) {
    final rtl = _settings.comicReadingDirection == ComicReadingDirection.rtl;
    return Stack(
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) {
            final w = context.size?.width ?? MediaQuery.sizeOf(context).width;
            final dx = details.localPosition.dx;
            if (dx < w * 0.3) {
              _flip(-1);
            } else if (dx > w * 0.7) {
              _flip(1);
            } else {
              setState(() => _chromeVisible = !_chromeVisible);
            }
          },
          child: PageView.builder(
            reverse: rtl,
            controller: _comicPageController!,
            itemCount: _comicPageCount,
            onPageChanged: (i) {
              setState(() => _comicPage = i);
              widget.library.savePosition(
                id: _book.id,
                chapter: i,
                offset: 0,
                progress: _comicPageCount == 0 ? 0 : i / _comicPageCount,
              );
              if (_comicLazy) _prefetchComicPages(i);
              if (_comicPreviewVisible) _scrollToPreviewPage(i);
            },
            itemBuilder: (context, i) => Center(
              child: _comicLazy
                  ? _LazyComicPageWidget(
                      provider: _comicPageProvider!,
                      pageIndex: i,
                      fit: _comicBoxFit,
                    )
                  : Image.memory(
                      _comicPages[i],
                      fit: _comicBoxFit,
                    ),
            ),
          ),
        ),
        IgnorePointer(
          ignoring: !_chromeVisible,
          child: _chrome(
            centerLabel:
                'Page ${_comicPage + 1} of $_comicPageCount',
            sliderMax: _comicPageCount > 1 ? _comicPageCount : 1,
            sliderValue: (_comicPage + 1).clamp(
              1,
              _comicPageCount > 0 ? _comicPageCount : 1,
            ),
            sliderLabel: _comicPageCount == 0
                ? '-/-'
                : '${(((_comicPage + 1) / _comicPageCount) * 100).round()}%',
            onSliderChanged: (v) {
              _comicPageController?.jumpToPage(v - 1);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildComicVertical(ReaderTheme theme) {
    _comicVerticalScrollController ??= ScrollController();
    final controller = _comicVerticalScrollController!;
    if (!_comicVerticalListenerAttached) {
      _comicVerticalListenerAttached = true;
      controller.addListener(() {
        if (!mounted) return;
        final count = _comicPageCount;
        if (count == 0) return;
        final viewportHeight = MediaQuery.sizeOf(context).height;
        if (viewportHeight <= 0) return;
        final newIndex =
            (controller.offset / viewportHeight).round().clamp(0, count - 1);
        if (newIndex != _comicPage) {
          setState(() => _comicPage = newIndex);
          widget.library.savePosition(
            id: _book.id,
            chapter: newIndex,
            offset: controller.offset.toInt(),
            progress: newIndex / count,
          );
          if (_comicLazy) _prefetchComicPages(newIndex);
          if (_comicPreviewVisible) _scrollToPreviewPage(newIndex);
        }
      });
    }
    return Stack(
      children: [
        ListView.builder(
          controller: controller,
          padding: EdgeInsets.zero,
          itemCount: _comicPageCount,
          itemBuilder: (context, i) => InteractiveViewer(
            minScale: 1.0,
            maxScale: 4.0,
            child: Center(
              child: _comicLazy
                  ? _LazyComicPageWidget(
                      provider: _comicPageProvider!,
                      pageIndex: i,
                      fit: _comicBoxFit,
                    )
                  : Image.memory(
                      _comicPages[i],
                      fit: _comicBoxFit,
                    ),
            ),
          ),
        ),
        IgnorePointer(
          ignoring: !_chromeVisible,
          child: _chrome(
            centerLabel:
                'Page ${_comicPage + 1} of $_comicPageCount',
            sliderMax: _comicPageCount > 1 ? _comicPageCount : 1,
            sliderValue: (_comicPage + 1).clamp(
              1,
              _comicPageCount > 0 ? _comicPageCount : 1,
            ),
            sliderLabel: _comicPageCount == 0
                ? '-/-'
                : '${(((_comicPage + 1) / _comicPageCount) * 100).round()}%',
            onSliderChanged: (v) {
              final viewportHeight = MediaQuery.sizeOf(context).height;
              final targetOffset = (v - 1) * viewportHeight;
              controller.animateTo(
                targetOffset,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOutCubic,
              );
            },
          ),
        ),
      ],
    );
  }

  /// Prefetch pages within ±5 of [center] and evict those further out.
  void _prefetchComicPages(int center) {
    final provider = _comicPageProvider;
    if (provider == null) return;
    const buffer = 5;
    for (var i = center - buffer; i <= center + buffer; i++) {
      if (i < 0 || i >= provider.pageCount) continue;
      if (provider.isCached(i) || _comicPagesLoading.contains(i)) continue;
      _comicPagesLoading.add(i);
      provider.loadPage(i).then((_) {
        _comicPagesLoading.remove(i);
        if (mounted) setState(() {});
      });
    }
    provider.evictOutside(center, margin: 10);
  }

  void _scrollToPreviewPage(int page) {
    if (!_comicPreviewScrollController.hasClients) return;
    // Each thumbnail is 52 + 4 margin = 56 logical pixels.
    final target = (page * 56.0) - 80.0;
    _comicPreviewScrollController.jumpTo(
      target.clamp(
        0.0,
        _comicPreviewScrollController.position.maxScrollExtent,
      ),
    );
  }

  /// Initialized on first access by [_flip] or [_buildComic].
  /// Invariant: [_comicPages] must be loaded before first access (via
  /// [_loadComicPages] in [initState]) so that the clamp uses the correct
  /// page count. For lazy CBZ, [_comicPages] always has at least one entry
  /// from the provider. Initialized in [_loadComicPages].
  PageController? _comicPageController;

  // ---------------------------- Reflowable -----------------------------------

  Widget _buildReflowable(BuildContext context, ReaderTheme theme) {
    if (_doc == null) {
      return Center(child: CircularProgressIndicator(color: theme.accent));
    }

    if (_paginationRunning) {
      final progress = _doc!.chapters.isEmpty
          ? 0.0
          : _paginationChapter / _doc!.chapters.length;
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 48),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(
                value: progress,
                backgroundColor: theme.muted.withValues(alpha: 0.2),
                valueColor: AlwaysStoppedAnimation(theme.accent),
              ),
              const SizedBox(height: 16),
              Text(
                'Laying out pages… ${(progress * 100).round()}%',
                style: TextStyle(fontSize: 14, color: theme.muted),
              ),
            ],
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = _contentViewport(constraints.biggest);
        final style = _settings.textStyle(context);
        final scaler = MediaQuery.textScalerOf(context);
        final signature = _signatureFor(viewport, style, scaler);
        // Cache so settings changes measure against the layout that actually
        // produced the current paginators.
        _lastViewport = viewport;

        if (_layoutSignature != signature && _bgTargetSignature != signature) {
          final needsFirstLayout = _paginators.length < _doc!.chapters.length;
          if (needsFirstLayout) {
            // Initial layout: nothing live yet, so this signature is the
            // layout being built. Record it so later frames don't re-schedule.
            _layoutSignature = signature;
          }
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || _doc == null) return;
            if (needsFirstLayout) {
              // No layout exists yet: this is the initial pass after load.
              _restartPagination(viewport, style, scaler);
            } else {
              // Viewport or style changed mid-read.
              _repaginateKeepingPosition();
            }
          });
        }

        final controller = _pageController;
        if (controller == null) {
          return Center(
            child: CircularProgressIndicator(color: theme.accent),
          );
        }

        final itemCount = _flatPageCount;
        return Stack(
          children: [
            PageView.builder(
              controller: controller,
              itemCount: itemCount,
              onPageChanged: (i) {
                setState(() => _flatPage = i);
                final ref = _refAt(i);
                if (ref != null) {
                  _onPositionChanged(
                      ref.$1, _paginators[ref.$1].pages[ref.$2].start);
                }
                _checkBookmarkState();
              },
              itemBuilder: (context, i) {
                final ref = _refAt(i);
                if (ref == null) return const SizedBox.shrink();
                final chapter = ref.$1;
                final page = _paginators[chapter].pages[ref.$2];
                // Compute highlights for this page.
                List<SearchResult>? highlights;
                if (_searchOpen && _search != null && _searchResults.isNotEmpty) {
                  highlights = _search!.matchesForPage(
                    chapter,
                    page.start,
                    page.end,
                  );
                }
                // Render with the style this chapter's paginator was laid out
                // at, so page boundaries always match their text: during lazy
                // repagination the reader's chapter is new while the rest is
                // still old. Refresh only the color, which never affects
                // layout but must re-apply instantly on a theme change.
                final chapterStyle =
                    chapter < _chapterStyles.length ? _chapterStyles[chapter] : style;
                final renderStyle =
                    chapterStyle.copyWith(color: _settings.colors.text);
                return _PageContent(
                  chapterTitle: _doc!.chapters[chapter].title,
                  text: _doc!.chapters[chapter].body,
                  runs: _doc!.chapters[chapter].runs,
                  images: _doc!.chapters[chapter].images,
                  page: page,
                  style: renderStyle,
                  theme: theme,
                  settings: _settings,
                  onTapPrev: () {
                    _dismissDictionaryButton();
                    _flip(-1);
                  },
                  onTapNext: () {
                    _dismissDictionaryButton();
                    _flip(1);
                  },
                  onTapCenter: () {
                    _dismissDictionaryButton();
                    setState(() => _chromeVisible = !_chromeVisible);
                  },
                  highlightMatches: highlights,
                  currentMatch: _currentResultIndex >= 0 &&
                          _currentResultIndex < _searchResults.length
                      ? _searchResults[_currentResultIndex]
                      : null,
                  pageMaxHeight: _lastViewport?.height ?? double.infinity,
                  onLongPressWord: (word, globalPosition, bodyStart, bodyEnd) {
                    _showWordToolbar(globalPosition, word, bodyStart, bodyEnd);
                  },
                  selectedWordRange: _selectedWordRange,
                  textAlign: _settings.textJustification == TextJustification.justify
                      ? TextAlign.justify
                      : TextAlign.left,
                  horizontalMargin: _settings.horizontalMargin,
                );
              },
            ),
            IgnorePointer(
              ignoring: !_chromeVisible,
              child: _chrome(
                centerLabel: _pageLabel(),
                sliderMax: (itemCount - 1).clamp(0, 1 << 30),
                sliderValue: _flatPage.clamp(0, itemCount - 1),
                sliderLabel: _progressPercent(),
                onSliderChanged: (v) {
                  if (v != _flatPage) controller.jumpToPage(v);
                },
              ),
            ),
            if (_searchOpen) _buildSearchOverlay(theme),
          ],
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Full-book chunked pagination
  // ---------------------------------------------------------------------------

  final Map<int, ChapterPaginationDriver> _paginationDrivers = {};

  /// Begin (or restart) a chunked full-book pagination pass.
  ///
  /// Any pass already in flight is orphaned via [_paginationGeneration] rather
  /// than left to interleave with this one and write chapters at two different
  /// styles into [_paginators].
  void _restartPagination(Size viewport, TextStyle style, TextScaler scaler) {
    _paginationGeneration++;
    _chapterStyles = List.filled(_doc!.chapters.length, style);
    for (final d in _paginationDrivers.values) {
      d.dispose();
    }
    _paginationDrivers.clear();

    while (_paginators.length < _doc!.chapters.length) {
      _paginators.add(_emptyPaginator());
    }

    // Detach before destroying. Dropping the reference now means the frame
    // that swaps in the progress view unmounts the PageView, so disposing
    // afterwards can't leave it holding a dead controller mid-gesture.
    final old = _pageController;
    _pageController = null;
    if (old != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }

    _paginationChapter = 0;
    _paginationRunning = true;
    if (mounted) setState(() {});
    _paginateNextBatch(viewport, style, scaler, _paginationGeneration);
  }

  void _paginateNextBatch(
    Size viewport,
    TextStyle style,
    TextScaler scaler,
    int generation,
  ) {
    if (!mounted || _doc == null) return;
    if (generation != _paginationGeneration) return; // superseded
    final stopwatch = Stopwatch()..start();

    while (_paginationChapter < _doc!.chapters.length) {
      final c = _paginationChapter;
      var driver = _paginationDrivers[c];
      if (driver == null) {
        driver = ChapterPaginationDriver(
          text: _doc!.chapters[c].body,
          style: style,
          maxWidth: viewport.width,
          maxHeight: viewport.height,
          direction: TextDirection.ltr,
          firstPageInset: _titleInset(c, viewport, style, scaler),
          textScaler: scaler,
          runs: _doc!.chapters[c].runs,
          images: _doc!.chapters[c].images,
        );
        _paginationDrivers[c] = driver;
      }

      driver.nextChunk(5);

      if (driver.isDone) {
        _paginators[c] = driver.toPaginator();
        driver.dispose();
        _paginationDrivers.remove(c);
        _paginationChapter++;
      }

      if (stopwatch.elapsedMilliseconds > 10) {
        setState(() {});
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _paginateNextBatch(viewport, style, scaler, generation);
        });
        return;
      }
    }

    // All chapters paginated — restore position and show reader.
    _paginationRunning = false;
    _restorePosition();
    setState(() {});
  }

  /// Create the initial [PageController] at the book's saved position. Called
  /// once when the initial full-book pass finishes; re-layouts keep this
  /// controller and jump the existing scroll position instead.
  void _restorePosition() {
    if (!mounted || _doc == null || _pageController != null) return;
    if (_paginators.length < _doc!.chapters.length) return;
    final pending = _pendingRestore;
    _pendingRestore = null;
    final targetChapter =
        (pending?.$1 ?? _book.lastChapter).clamp(0, _doc!.chapters.length - 1);
    final targetOffset = pending?.$2 ?? _book.lastOffset;
    final flat = _flatIndexForChapter(targetChapter);
    final pageIdx = targetOffset > 0
        ? _paginators[targetChapter].pageIndexFor(targetOffset)
        : 0;
    setState(() {
      _pageController = PageController(initialPage: flat + pageIdx);
      _flatPage = flat + pageIdx;
    });
  }

  void _flip(int direction) {
    if (_isPdf) {
      if (!_pdfController.isReady) return;
      final target = _pdfPage + direction;
      if (target < 1 || target > _pdfPageCount) return;
      _pdfController.goToPage(pageNumber: target);
      return;
    }
    if (_isComic) {
      if (_comicPageCount == 0) return;
      // In RTL mode the PageView is reversed, so negate the direction.
      final rtl =
          _settings.comicReadingDirection == ComicReadingDirection.rtl;
      final target = _comicPage + (rtl ? -direction : direction);
      if (target < 0 || target >= _comicPageCount) return;
      _comicPageController?.animateToPage(
        target,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
      return;
    }
    final controller = _pageController;
    if (controller == null) return;
    final target = _flatPage + direction;
    if (target < 0 || target >= _flatPageCount) return;
    controller.animateToPage(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  /// Flat page index where [chapter] begins.
  int _flatIndexForChapter(int chapter) {
    var flat = 0;
    for (var c = 0; c < chapter; c++) {
      flat += _paginators[c].pages.length;
    }
    return flat;
  }

  /// Jump directly to the start of [chapterIndex].
  void _jumpToChapter(int chapterIndex) {
    if (_doc == null || _pageController == null) return;
    final flat = _flatIndexForChapter(chapterIndex);
    _pageController!.jumpToPage(flat);
    setState(() => _flatPage = flat);
  }

  void _showTocSheet() {
    if (_isPdf) {
      // PDF: show outline if available.
      if (_pdfOutline.isEmpty) return;
      TocSheet.showPdf(
        context,
        settings: _settings,
        outline: _pdfOutline,
        currentPage: _pdfPage,
        onJump: _jumpToPdfPage,
        bookmarks: _bookmarks,
        onDeleteBookmark: (bm) async {
          await widget.library.deleteBookmark(bm.id);
          await _loadBookmarks();
        },
      );
      return;
    }
    if (_doc == null) return;
    final currentChapter = _refAt(_flatPage)?.$1 ?? 0;
    TocSheet.show(
      context,
      settings: _settings,
      chapters: _doc!.chapters,
      paginators: _paginators,
      currentIndex: currentChapter,
      onJump: _jumpToChapter,
      bookmarks: _bookmarks,
      onDeleteBookmark: (bm) async {
        await widget.library.deleteBookmark(bm.id);
        await _loadBookmarks();
      },
    );
  }

  String _pageLabel() {
    final ref = _refAt(_flatPage);
    if (ref == null || _doc == null) return '';
    return _doc!.chapters[ref.$1].title;
  }

  String _progressPercent() {
    if (_lazyRunning) return '-/-';
    if (_flatPageCount == 0) return '';
    return '${_flatPage + 1} / $_flatPageCount';
  }

  void _showGoToPageDialog() {
    final theme = _settings.colors;
    final controller = TextEditingController();
    final maxPage = _isPdf ? _pdfPageCount : (_isComic ? _comicPageCount : _flatPageCount);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: theme.background,
        title: Text('Go to page', style: TextStyle(color: theme.text)),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          style: TextStyle(color: theme.text),
          decoration: InputDecoration(
            hintText: '1–$maxPage',
            hintStyle: TextStyle(color: theme.muted),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: theme.muted),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: theme.accent),
            ),
          ),
          onSubmitted: (_) {
            final page = int.tryParse(controller.text);
            if (page != null && page >= 1 && page <= maxPage) {
              Navigator.of(ctx).pop();
              if (_isPdf) {
                _jumpToPdfPage(page);
              } else if (_isComic) {
                _comicPageController?.animateToPage(
                  page - 1,
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                );
              } else {
                _pageController?.jumpToPage(page - 1);
              }
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('Cancel', style: TextStyle(color: theme.muted)),
          ),
          TextButton(
            onPressed: () {
              final page = int.tryParse(controller.text);
              if (page != null && page >= 1 && page <= maxPage) {
                Navigator.of(ctx).pop();
                if (_isPdf) {
                  _jumpToPdfPage(page);
                } else if (_isComic) {
      _comicPageController?.animateToPage(
                    page - 1,
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                  );
                } else {
                  _pageController?.jumpToPage(page - 1);
                }
              }
            },
            child: Text('Go', style: TextStyle(color: theme.accent)),
          ),
        ],
      ),
    );
  }

  // ------------------------------ Chrome -------------------------------------

  GestureTapUpCallback _handleTapZones({required VoidCallback onCenter}) {
    return (details) {
      _dismissDictionaryButton();
      final w = MediaQuery.sizeOf(context).width;
      final dx = details.localPosition.dx;
      if (dx < w * 0.3) {
        _flip(-1);
      } else if (dx > w * 0.7) {
        _flip(1);
      } else {
        onCenter();
      }
    };
  }

  Widget _chrome({
    required String centerLabel,
    required int sliderMax,
    required int sliderValue,
    required String sliderLabel,
    required ValueChanged<int> onSliderChanged,
  }) {
    final theme = _settings.colors;
    return AnimatedOpacity(
      opacity: _chromeVisible ? 1 : 0,
      duration: const Duration(milliseconds: 180),
      child: Column(
        children: [
          Container(
            color: theme.background.withValues(alpha: 0.97),
            padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
            child: Row(
              children: [
                IconButton(
                  icon: Icon(Icons.arrow_back, color: theme.text),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                Expanded(
                  child: Text(
                    _book.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: theme.text),
                  ),
                ),
                if (_showToc)
                  IconButton(
                    icon: Icon(Icons.toc, color: theme.text),
                    onPressed: _showTocSheet,
                  ),
                if (_showSearch)
                  IconButton(
                    icon: Icon(Icons.search, color: theme.text),
                    onPressed: _toggleSearch,
                  ),
                if (_showBookmark)
                  IconButton(
                    icon: Icon(
                      _isCurrentPageBookmarked
                          ? Icons.bookmark
                          : Icons.bookmark_border,
                      color: _isCurrentPageBookmarked
                          ? theme.accent
                          : theme.text,
                    ),
                    onPressed: _toggleBookmark,
                  ),
                if (_isComic)
                  IconButton(
                    icon: Icon(
                      _comicPreviewVisible
                          ? Icons.view_carousel
                          : Icons.view_carousel_outlined,
                      color: _comicPreviewVisible ? theme.accent : theme.text,
                    ),
                    onPressed: () =>
                        setState(() => _comicPreviewVisible = !_comicPreviewVisible),
                  ),
                IconButton(
                  icon: Icon(Icons.text_fields, color: theme.text),
                  onPressed: () => SettingsSheet.show(
                    context,
                    settings: _settings,
                    onChanged: _onSettingsChanged,
                    format: _book.format,
                    onPdfFitWidth: _isPdf
                        ? () => _pdfController.goToPage(
                              pageNumber: _pdfPage,
                              anchor: PdfPageAnchor.left,
                            )
                        : null,
                    onPdfFitPage: _isPdf
                        ? () => _pdfController.goToPage(
                              pageNumber: _pdfPage,
                              anchor: PdfPageAnchor.center,
                            )
                        : null,
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          Container(
            color: theme.background.withValues(alpha: 0.97),
            padding: EdgeInsets.fromLTRB(
              16,
              8,
              16,
              MediaQuery.paddingOf(context).bottom + 8,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_isComic && _comicPreviewVisible) ...[
                  _buildComicPreviewStrip(theme),
                  const SizedBox(height: 8),
                ],
                GestureDetector(
                  onTap: _showGoToPageDialog,
                  child: Text(
                    centerLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: theme.text,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  sliderLabel,
                  style: TextStyle(fontSize: 12, color: theme.muted),
                ),
                const SizedBox(height: 2),
                SliderTheme(
                  data: SliderThemeData(
                    activeTrackColor: theme.accent,
                    thumbColor: theme.accent,
                    inactiveTrackColor: theme.muted.withValues(alpha: 0.3),
                  ),
                  child: Slider(
                    value: sliderValue.toDouble(),
                    max: sliderMax.toDouble(),
                    onChanged: (v) => onSliderChanged(v.round()),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildComicPreviewStrip(ReaderTheme theme) {
    final count = _comicPageCount;
    if (count == 0) return const SizedBox.shrink();
    // Scroll to center the current page when the strip first appears.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToPreviewPage(_comicPage);
    });
    return SizedBox(
      height: 80,
      child: ListView.builder(
        controller: _comicPreviewScrollController,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        itemCount: count,
        itemBuilder: (context, i) {
          final isCurrent = i == _comicPage;
          return GestureDetector(
            onTap: () {
              if (_comicLazy) {
                _comicPageController?.jumpToPage(i);
              } else if (_settings.comicReadingMode == ComicReadingMode.vertical) {
                final vh = MediaQuery.sizeOf(context).height;
                _comicVerticalScrollController?.animateTo(
                  i * vh,
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOutCubic,
                );
              } else {
                _comicPageController?.jumpToPage(i);
              }
            },
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
                      child: _comicLazy
                          ? _LazyComicPageWidget(
                              provider: _comicPageProvider!,
                              pageIndex: i,
                              fit: BoxFit.cover,
                            )
                          : (i < _comicPages.length
                              ? Image.memory(_comicPages[i], fit: BoxFit.cover)
                              : Container(color: theme.muted.withValues(alpha: 0.2))),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${i + 1}',
                    style: TextStyle(
                      fontSize: 9,
                      color: isCurrent ? theme.accent : theme.muted,
                      fontWeight:
                          isCurrent ? FontWeight.w600 : FontWeight.normal,
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

/// Displays a single comic page from a [ComicPageProvider], loading the
/// image bytes on demand and showing a sized placeholder while loading.
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

/// One rendered page of a reflowable document with tap zones.
class _PageContent extends StatelessWidget {
  const _PageContent({
    required this.chapterTitle,
    required this.text,
    required this.page,
    required this.style,
    required this.theme,
    required this.settings,
    required this.onTapPrev,
    required this.onTapNext,
    required this.onTapCenter,
    this.runs = const [],
    this.images = const [],
    this.highlightMatches,
    this.currentMatch,
    this.pageMaxHeight = double.infinity,
    this.onLongPressWord,
    this.selectedWordRange,
    this.textAlign = TextAlign.justify,
    this.horizontalMargin = 20,
  });

  final String chapterTitle;
  final String text;
  final TextPage page;
  final TextStyle style;
  final ReaderTheme theme;
  final ReaderSettings settings;
  final VoidCallback onTapPrev;
  final VoidCallback onTapNext;
  final VoidCallback onTapCenter;

  final List<StyleRun> runs;
  final List<ImageRun> images;
  final List<SearchResult>? highlightMatches;
  final SearchResult? currentMatch;
  final double pageMaxHeight;
  final void Function(String word, Offset globalPosition, int bodyStart, int bodyEnd)? onLongPressWord;
  final ({int start, int end})? selectedWordRange;
  final TextAlign textAlign;
  final double horizontalMargin;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (details) {
        final w = context.size?.width ?? MediaQuery.sizeOf(context).width;
        final dx = details.localPosition.dx;
        if (dx < w * 0.3) {
          onTapPrev();
        } else if (dx > w * 0.7) {
          onTapNext();
        } else {
          onTapCenter();
        }
      },
      onLongPressStart: onLongPressWord != null
          ? (details) => _handleLongPress(context, details)
          : null,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: horizontalMargin, vertical: 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Builder(
                builder: (context) => RichText(
                  textAlign: textAlign,
                  text: TextSpan(
                    style: style,
                    children: _buildPageText(context, MediaQuery.sizeOf(context).width - horizontalMargin * 2),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _handleLongPress(BuildContext context, LongPressStartDetails details) {
    if (onLongPressWord == null) return;

    final renderWidth = MediaQuery.sizeOf(context).width - horizontalMargin * 2;
    final spans = _buildPageText(context, renderWidth);

    final painter = TextPainter(
      text: TextSpan(style: style, children: spans),
      textDirection: TextDirection.ltr,
      maxLines: null,
    )..layout(maxWidth: renderWidth);

    final adjusted = Offset(
      details.localPosition.dx - 20,
      details.localPosition.dy - 28,
    );
    final textOffset = painter.getPositionForOffset(adjusted).offset;
    painter.dispose();
    final bodyOffset = page.start + textOffset;

    if (bodyOffset < 0 || bodyOffset >= text.length) return;

    int start = bodyOffset;
    int end = bodyOffset;
    while (start > 0 && _isWordChar(text[start - 1])) {
      start--;
    }
    while (end < text.length && _isWordChar(text[end])) {
      end++;
    }

    if (start == end) return;
    var word = text.substring(start, end).trim();
    word = word.replaceAll(RegExp(r"^[^a-zA-Z']+|[^a-zA-Z']+$"), '');
    if (word.length < 2) return;

    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final globalPos = box.localToGlobal(
      Offset(details.localPosition.dx, details.localPosition.dy - 20),
    );

    onLongPressWord!(word, globalPos, start, end);
  }

  static bool _isWordChar(String ch) {
    return ch.runes.any((r) => r > 127) || RegExp(r'[a-zA-Z\u00C0-\u024F]').hasMatch(ch);
  }

  /// Builds the page's TextSpan, merging style runs (emphasis, quotes) with
  /// search-match highlights and inline images.
  List<InlineSpan> _buildPageText(BuildContext context, double renderWidth) {
    final tappedImages = images.map((img) {
      if (img.onTap != null) return img;
      return ImageRun(
        offset: img.offset,
        bytes: img.bytes,
        intrinsicWidth: img.intrinsicWidth,
        intrinsicHeight: img.intrinsicHeight,
        alt: img.alt,
        fullWidth: img.fullWidth,
        onTap: () => _showImagePopup(context, img.bytes),
      );
    }).toList();
    return buildPageSpans(
      text: text,
      start: page.start,
      end: page.end,
      base: style,
      theme: theme,
      settings: settings,
      runs: runs,
      images: tappedImages,
      renderWidth: renderWidth,
      maxHeight: pageMaxHeight,
      matches: highlightMatches ?? const [],
      currentMatch: currentMatch,
      selectedRange: selectedWordRange,
    );
  }

  void _showImagePopup(BuildContext context, Uint8List bytes) {
    showDialog(
      context: context,
      barrierColor: Colors.black87,
      builder: (ctx) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          leading: IconButton(
            icon: const Icon(Icons.close, color: Colors.white),
            onPressed: () => Navigator.of(ctx).pop(),
          ),
        ),
        body: GestureDetector(
          onTap: () => Navigator.of(ctx).pop(),
          child: Center(
            child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 4.0,
              child: Image.memory(bytes, fit: BoxFit.contain),
            ),
          ),
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, size: 48),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(message, textAlign: TextAlign.center),
          ),
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Go back'),
          ),
        ],
      ),
    );
  }
}

/// Landing pad for the shared-element cover morph: the cover arrives via the
/// Hero flight, holds while the reader text settles in behind it, then
/// dissolves away and unmounts.
class _CoverIntroOverlay extends StatefulWidget {
  const _CoverIntroOverlay({required this.book});

  final Book book;

  @override
  State<_CoverIntroOverlay> createState() => _CoverIntroOverlayState();
}

class _CoverIntroOverlayState extends State<_CoverIntroOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 750),
  )..addStatusListener(_onStatus)
        ..forward();

  bool _done = false;

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && mounted) {
      setState(() => _done = true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_done) return const SizedBox.shrink();
    // Hold ~40% of the timeline, then dissolve with an emphasized accelerate.
    final opacity = Tween(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.4, 1, curve: Easing.emphasizedAccelerate),
      ),
    );
    return IgnorePointer(
      child: ExcludeSemantics(
        child: FadeTransition(
          opacity: opacity,
          child: Center(
            child: FractionallySizedBox(
              widthFactor: 0.62,
              child: BookCover(book: widget.book, borderRadius: 24),
            ),
          ),
        ),
      ),
    );
  }
}
