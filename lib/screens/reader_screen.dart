import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../controllers/bookmark_helper.dart';
import '../controllers/comic_controller.dart';
import '../controllers/selection_toolbar.dart';
import '../controllers/pdf_controller.dart';
import '../controllers/reading_session.dart';
import '../controllers/search_controller.dart';
import '../services/brightness_controller.dart';
import '../services/comic_decode_ahead.dart';
import '../models/book.dart';
import '../models/reader_settings.dart';
import '../models/style_run.dart';
import '../services/book_search.dart';
import '../services/comic_page_provider.dart';
import '../models/document.dart';
import '../services/epub/epub_engine_factory.dart';
import '../services/epub_css_parser.dart';
import '../services/library_service.dart';
import '../services/paginator.dart';
import '../utils/open_trace.dart';
import '../utils/page_spans.dart';
import '../widgets/book_cover.dart';
import '../widgets/comic_image.dart';
import '../widgets/settings_sheet.dart';
import '../widgets/toc_sheet.dart';

/// Order in which the background pass should lay out chapters: the reader's
/// chapter first, then forward to the end, then backward to the start.
///
/// Opening mid-book used to fill from chapter 0, so forward paging reached
/// unlaid chapters long before the pass did.
@visibleForTesting
List<int> fillOrderFor(int count, int anchor) {
  final a = anchor.clamp(0, count - 1);
  return [
    for (var c = a; c < count; c++) c,
    for (var c = a - 1; c >= 0; c--) c,
  ];
}

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
class ReaderScreenState extends State<ReaderScreen>
    with WidgetsBindingObserver {
  ReaderSettings get _settings => widget.library.settings;
  Book get _book {
    // Resolve via library so a relink (new path) is picked up without
    // reopening the reader. Falls back to the opening snapshot.
    for (final b in widget.library.books) {
      if (b.id == widget.book.id) return b;
    }
    return widget.book;
  }

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

  /// Prefix sums over `_paginators`: `_flatStart[c]` is the flat page index at
  /// which chapter `c` begins, and `_flatTotal` is the number of pages in the
  /// book. Rebuilt whenever the paginator set changes so flat<->chapter mapping
  /// stays O(log chapters) instead of rescanning every chapter per frame.
  List<int> _flatStart = const [];
  int _flatTotal = 0;

  void _recomputeFlatIndexes() {
    final starts = List<int>.filled(_paginators.length, 0);
    var acc = 0;
    for (var i = 0; i < _paginators.length; i++) {
      starts[i] = acc;
      acc += _paginators[i].pages.length;
    }
    _flatStart = starts;
    _flatTotal = acc;
  }

  /// True once every chapter has a real paginator. The live set is complete at
  /// rest, so this is true whenever a pass is not mid-flight.
  bool get _allPaginatorsReady =>
      _paginationReady.isNotEmpty &&
      _paginationReady.length >= _paginators.length &&
      _paginationReady.every((ready) => ready);

  /// True when no layout pass is running and none is queued.
  bool get _passSettled => !_paginationRunning && !_reflowActive;

  /// Flat page index holding `(chapter, offset)` in the current paginator set.
  int _flatIndexForPosition(int chapter, int offset) {
    if (chapter < 0 || chapter >= _paginators.length) return 0;
    final pageIdx = offset > 0 ? _paginators[chapter].pageIndexFor(offset) : 0;
    return _flatStart[chapter] + pageIdx;
  }

  PageController? _pageController;
  int _flatPage = 0;

  /// The [TextStyle] each `_paginators[i]` was laid out with. Rendering always
  /// uses the chapter's own style, never a freshly-read settings style: during
  /// a lazy repagination the reader's chapter is re-laid out first while the
  /// rest keeps its old layout, so each chapter must render with the style
  /// that produced its page boundaries. Only the color is refreshed (theme
  /// changes re-color instantly and never affect layout).
  List<TextStyle> _chapterStyles = const [];

  // Pagination state.
  bool _paginationRunning = false;

  /// Whether `_paginators[i]` is a real layout. The live set is always
  /// complete (the initial pass and every reflow install a full set), so at
  /// rest every entry is true.
  List<bool> _paginationReady = const [];

  /// Anchor `(chapter, offsetInChapter)` of the visible page.
  int _anchorChapter = 0;
  int _anchorOffset = 0;

  /// Flat page a programmatic jump is heading to. The resulting
  /// `onPageChanged` must not overwrite the reading anchor, or repeated
  /// re-layouts would drift the position backwards.
  int? _programmaticTarget;

  /// Full-book layouts cached by signature, swapped in on a settings toggle
  /// back to a previously-used layout. Capped at [_maxCacheSize] entries with
  /// LRU eviction (oldest = first insertion-order key in the map).
  static const _maxCacheSize = 5;
  final Map<String, List<Paginator>> _paginationCache = {};

  void _cacheLayout(String sig, List<Paginator> pages) {
    // Remove first to reset insertion-order position (LRU bump).
    _paginationCache.remove(sig);
    // Evict oldest entry that isn't the currently active layout.
    if (_paginationCache.length >= _maxCacheSize) {
      final oldest = _paginationCache.keys.firstWhere(
        (k) => k != _layoutSignature,
        orElse: () => _paginationCache.keys.first,
      );
      _paginationCache.remove(oldest);
    }
    _paginationCache[sig] = List.unmodifiable(pages);
  }

  /// Drivers for chapters being laid out incrementally.
  final Map<int, ChapterPaginationDriver> _paginationDrivers = {};

  // Atomic reflow for layout-setting changes. The live paginator set stays
  // complete (old layout) while a fully-new set is built in this buffer and
  // swapped in at the end, so the page count and scrubber never break.
  List<Paginator>? _reflowPages;
  List<TextStyle>? _reflowStyles;
  List<bool> _reflowReady = const [];
  int _reflowNext = 0;
  int _reflowGeneration = 0;
  /// Chapters in the order the background pass should lay them out (outward
  /// from the anchor), indexed by [_reflowNext].
  List<int> _reflowOrder = const [];
  String? _reflowSignature;
  final Map<int, ChapterPaginationDriver> _reflowDrivers = {};

  bool get _reflowActive => _reflowPages != null;

  /// Per-frame time budget for background pagination.
  static const Duration _paginationFrameBudget = Duration(milliseconds: 8);

  bool _chromeVisible = false;
  Timer? _saveDebounce;

  // Zoom state (PDF + comic).
  bool _zoomMode = false;
  double _zoomLevel = 1.0;
  static const double _zoomStep = 0.15;
  static const double _zoomMin = 0.5;
  static const double _zoomMax = 4.0;
  TransformationController? _comicTransformationController;

  /// True while the zoomed comic page sits past fit scale (see
  /// [_anyComicTransformZoomed]). While true, the outer pager/list gives up
  /// its drag gestures so the [InteractiveViewer] can pan the zoomed page.
  bool _comicZoomed = false;

  /// Transformation controllers already wired to [_onComicTransformChanged].
  final Set<TransformationController> _comicTransformListeners = {};

  // Guards the async brightness seed: a stale `current()` future must not
  // overwrite a mode toggle made while it was in flight.
  int _brightnessSeedGen = 0;

  // Reading session state.
  late final ReadingSessionManager _sessionCtrl;

  // Bookmark state.
  late final BookmarkHelper _bookmarkCtrl;

  // Search state.
  late final ReaderSearchController _searchCtrl;

  // PDF state.
  late final PdfReaderController _pdfCtrl;

  // Comic state.
  late final ComicReaderController _comicCtrl;

  // Selection toolbar state.
  SelectionToolbarOverlay? _selectionToolbar;
  ({int start, int end})? _selectedWordRange;

  bool get _isPdf => _book.format == BookFormat.pdf;
  bool get _isComic =>
      _book.format == BookFormat.cbz || _book.format == BookFormat.cbr;
  bool get _showSearch => !_isComic;
  bool get _showToc => !_isComic;
  bool get _showBookmark => !_isComic;

  @override
  void initState() {
    super.initState();
    _sessionCtrl = ReadingSessionManager(library: widget.library, book: _book);
    _bookmarkCtrl = BookmarkHelper(
      library: widget.library,
      book: _book,
      isPdf: _isPdf,
      getCurrentPosition: () {
        if (_isPdf) {
          return (
            chapter: _pdfCtrl.pdfPage,
            offset: 0,
            snippet: 'Page ${_pdfCtrl.pdfPage}',
          );
        }
        final ref = _refAt(_flatPage);
        if (ref == null || _doc == null) return null;
        final offset = _paginators[ref.$1].pages[ref.$2].start;
        final pageText = _doc!.chapters[ref.$1].body;
        final end = (offset + 60).clamp(0, pageText.length);
        final snippet = pageText.substring(offset, end).trim();
        return (chapter: ref.$1, offset: offset, snippet: snippet);
      },
    );
    _pdfCtrl = PdfReaderController(book: _book, settings: _settings);
    _pdfCtrl.addListener(() {
      if (mounted) setState(() {});
    });
    _comicCtrl = ComicReaderController(
      book: _book,
      settings: _settings,
      library: widget.library,
      onPageFlipped: _sessionCtrl.onPageFlipped,
    );
    _comicCtrl.addListener(() {
      if (mounted) setState(() {});
    });
    _searchCtrl = ReaderSearchController(book: _book);
    _searchCtrl.addListener(() {
      if (mounted) setState(() {});
    });
    _bookmarkCtrl.addListener(() {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    if (_settings.keepScreenOn) WakelockPlus.enable();
    BrightnessController.instance.apply(_settings.brightness);
    _bookmarkCtrl.loadBookmarks();
    _sessionCtrl.startSession();
    if (_isPdf) {
      _pdfCtrl.pdfController.addListener(_pdfCtrl.onPdfViewChanged);
    } else if (!_isComic) {
      _loadDocument();
    }
    if (_isComic) {
      _comicDecodeAhead = _createComicDecodeAhead();
      _loadComicPages();
    }
    _searchCtrl.searchController.addListener(_searchCtrl.onSearchTextChanged);
  }

  Future<void> _loadPdfOutline(PdfDocument document) =>
      _pdfCtrl.loadPdfOutline(document);

  void _jumpToPdfPage(int pageNumber) {
    _pdfCtrl.jumpToPdfPage(pageNumber);
    if (!_chromeVisible) {
      setState(() => _chromeVisible = true);
    }
  }

  Future<void> _loadDocument() async {
    try {
      final sw = Stopwatch()..start();
      final engine = createEpubEngine(widget.library.epubEngine);
      var doc = await engine.parse(_book.path);
      OpenTrace.span('parse', sw.elapsed);
      // Engines that defer font bytes across the parse boundary (Rust defers
      // them across the FFI, D15) materialise them here before
      // `loadEmbeddedFonts`, or embedded fonts silently never load. Engines
      // that embed font bytes at parse time return the document unchanged.
      doc = await engine.hydrateFonts(doc, _book.path);
      // Load embedded fonts (e.g. from @font-face rules in EPUB stylesheets).
      if (doc.fontFaces.isNotEmpty) {
        sw.reset();
        await EpubCssParser.loadEmbeddedFonts(doc.fontFaces);
        OpenTrace.span('fonts', sw.elapsed);
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
      // The cache-hit path defers inline-image bytes; hydrate them after the
      // first paint so the open never waits on them. Only swap if the reader
      // is still showing this same document. Hydration goes through the
      // active engine (D15): Rust reads through its own handle so a Rust open
      // never pays a second full-archive Dart inflate; Dart re-reads the
      // archive in an isolate.
      unawaited(
        engine.hydrateImages(doc, _book.path).then((hydrated) {
          if (mounted && identical(_doc, doc)) setState(() => _doc = hydrated);
        }),
      );
    } on FileSystemException {
      if (!mounted) return;
      setState(() => _error = 'File not found — it was moved or deleted.');
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
    _bookmarkCtrl.dispose();
    _saveDebounce?.cancel();
    _flushSave();
    _flushComicPosition();
    _settingsSaveDebounce?.cancel();
    widget.library.saveSettings();
    _pageController?.dispose();
    _disposeDrivers();
    _cancelReflow();
    _paginationCache.clear();
    _pdfCtrl.dispose();
    _comicCtrl.dispose();
    _searchCtrl.searchController.removeListener(
      _searchCtrl.onSearchTextChanged,
    );
    _searchCtrl.dispose();
    _selectionToolbar?.dismiss();
    _comicDecodeAhead?.dispose();
    for (final tc in _comicTransformListeners) {
      tc.removeListener(_onComicTransformChanged);
    }
    _comicTransformListeners.clear();
    _comicTransformationController?.dispose();
    _doc = null;
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
  // Zoom (PDF + comic)
  // ---------------------------------------------------------------------------

  bool get _supportsZoom => _isPdf || _isComic;

  void _toggleZoomMode() {
    if (!_supportsZoom) return;
    setState(() {
      _zoomMode = !_zoomMode;
      if (_zoomMode) {
        // Enter zoom: restore last level or default to 1.1x
        final saved = _settings.lastZoomLevel;
        _zoomLevel = saved > 1.0 ? saved : 1.1;
      } else {
        // Exit zoom: reset to 1x
        _zoomLevel = 1.0;
      }
    });
    if (_isComic && !_zoomMode) {
      // Reset every comic page back to fit scale; the per-page vertical
      // transformers become uncontrolled when zoom mode leaves and keeping
      // their matrices would strand those pages zoomed in.
      _resetComicTransforms();
    }
    _applyZoom();
  }

  void _zoomIn() {
    if (!_supportsZoom || !_zoomMode) return;
    setState(() {
      _zoomLevel = (_zoomLevel + _zoomStep).clamp(_zoomMin, _zoomMax);
      _settings.lastZoomLevel = _zoomLevel;
    });
    _applyZoom();
  }

  void _zoomOut() {
    if (!_supportsZoom || !_zoomMode) return;
    setState(() {
      _zoomLevel = (_zoomLevel - _zoomStep).clamp(_zoomMin, _zoomMax);
      _settings.lastZoomLevel = _zoomLevel;
    });
    _applyZoom();
  }

  void _applyZoom() {
    if (_isPdf) {
      _applyPdfZoom();
    } else if (_isComic) {
      _applyComicZoom();
    }
  }

  void _applyPdfZoom() {
    if (!_pdfCtrl.pdfController.isReady) return;
    final controller = _pdfCtrl.pdfController;
    if (_zoomLevel <= 1.0) {
      // Reset to fit: go to current page with center anchor
      controller.goToPage(
        pageNumber: _pdfCtrl.pdfPage,
        anchor: PdfPageAnchor.center,
      );
    } else {
      // Set zoom by going to current position with custom zoom
      final currentZoom = controller.currentZoom;
      if ((currentZoom - _zoomLevel).abs() > 0.01) {
        controller.goToPosition(
          documentOffset: controller.visibleRect.topLeft,
          zoom: _zoomLevel,
          duration: const Duration(milliseconds: 200),
        );
      }
    }
  }

  void _applyComicZoom() {
    final tc = _isComic
        ? _comicCtrl.verticalTransformer(_comicCtrl.comicPage)
        : null;
    final controller =
        _zoomMode && _settings.comicReadingMode == ComicReadingMode.vertical
        ? tc
        : _comicTransformationController;
    if (controller == null) return;
    final currentScale = controller.value.getMaxScaleOnAxis();
    if ((currentScale - _zoomLevel).abs() <= 0.01) return;
    final size = MediaQuery.sizeOf(context);
    final center = Offset(size.width / 2, size.height / 2);
    controller.value = Matrix4.identity()
      ..translateByDouble(center.dx, center.dy, 0, 1)
      ..scaleByDouble(_zoomLevel, _zoomLevel, 1, 1)
      ..translateByDouble(-center.dx, -center.dy, 0, 1);
  }

  // ---------------------------------------------------------------------------
  // Comic zoom gesture arbitration
  // ---------------------------------------------------------------------------

  /// A page is effectively zoomed when its transform scale sits above fit.
  /// The 1% hysteresis keeps single-pixel rounding from toggling page swipes.
  static bool _comicTransformZoomed(TransformationController? tc) =>
      (tc?.value.getMaxScaleOnAxis() ?? 1.0) > 1.01;

  /// True when any comic transform is zoomed past fit scale. The outer
  /// pager/list takes its drag gestures away while this is true, so drags
  /// and pinches on the page are owned by the [InteractiveViewer] instead
  /// of turning pages underneath it.
  bool _anyComicTransformZoomed() {
    if (_comicTransformZoomed(_comicTransformationController)) return true;
    for (final tc in _comicCtrl.verticalTransformers) {
      if (_comicTransformZoomed(tc)) return true;
    }
    return false;
  }

  /// Idempotently wires [tc] to the zoomed-state listener.
  void _listenComicTransform(TransformationController tc) {
    if (_comicTransformListeners.add(tc)) {
      tc.addListener(_onComicTransformChanged);
    }
  }

  /// Rebuilds when the effective zoom state crosses in or out, which flips
  /// the outer scroller between "turn pages" and "pan the zoomed page".
  void _onComicTransformChanged() {
    if (!mounted) return;
    final zoomed = _anyComicTransformZoomed();
    if (zoomed != _comicZoomed) {
      setState(() => _comicZoomed = zoomed);
    }
  }

  /// Resets every comic transform to fit scale — used when leaving zoom
  /// mode. Per-page vertical transformers must all be reset because their
  /// InteractiveViewers become uncontrolled ([_zoomMode == false], null
  /// controller) and would otherwise stay stuck zoomed with no gesture to
  /// undo it.
  void _resetComicTransforms() {
    _comicTransformationController?.value = Matrix4.identity();
    for (final tc in _comicCtrl.verticalTransformers.toList()) {
      tc.value = Matrix4.identity();
    }
  }

  // ---------------------------------------------------------------------------
  // Position persistence
  // ---------------------------------------------------------------------------

  void _onPositionChanged(int chapter, int offsetInChapter) {
    _sessionCtrl.onPageFlipped();
    _anchorChapter = chapter;
    _anchorOffset = offsetInChapter;
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 600), () {
      _saveCurrentPosition();
    });
  }

  void _saveComicPosition(int page, int offset, double progress) {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 300), () {
      widget.library.savePosition(
        id: _book.id,
        chapter: page,
        offset: offset,
        progress: progress,
      );
    });
  }

  void _flushComicPosition() {
    _saveDebounce?.cancel();
    if (!_isComic) return;
    final count = _comicCtrl.comicPageCount;
    if (count == 0) return;
    final vertical =
        _settings.comicReadingMode == ComicReadingMode.vertical;
    final scroll = _comicCtrl.comicVerticalScrollController;
    final offset = vertical && scroll != null && scroll.hasClients
        ? scroll.offset.toInt()
        : 0;
    widget.library.savePosition(
      id: _book.id,
      chapter: _comicCtrl.comicPage,
      offset: offset,
      progress: (_comicCtrl.comicPage + 1) / count,
    );
  }

  void _flushSave() {
    if (_isPdf) {
      if (_pdfCtrl.pdfPageCount > 0) {
        widget.library.savePosition(
          id: _book.id,
          chapter: _pdfCtrl.pdfPage - 1,
          offset: 0,
          progress: _pdfCtrl.pdfPage / _pdfCtrl.pdfPageCount,
        );
      }
      return;
    }
    if (_doc == null) return;
    // The anchor is captured whenever the page changes and survives
    // background pagination, so it is always real text even while some
    // chapters are still placeholder layouts.
    if (_pageController != null) {
      _savePositionFor(_anchorChapter, _anchorOffset);
      return;
    }
    final ref = _refAt(_flatPage);
    if (ref == null) return;
    _savePositionFor(ref.$1, _paginators[ref.$1].pages[ref.$2].start);
  }

  void _savePositionFor(int chapter, int offset) {
    var progress = _totalChars == 0
        ? 0.0
        : (_charsBefore[chapter] + offset) / _totalChars;
    if (_flatTotal > 0 && _flatPage >= _flatTotal - 1) progress = 1.0;
    widget.library.savePosition(
      id: _book.id,
      chapter: chapter,
      offset: offset,
      progress: progress,
    );
  }

  void _saveCurrentPosition() {
    _savePositionFor(_anchorChapter, _anchorOffset);
  }

  // ---------------------------------------------------------------------------
  // Reflowable pagination
  // ---------------------------------------------------------------------------

  String _signatureFor(Size viewport, TextStyle style, TextScaler scaler) =>
      '${viewport.width}x${viewport.height}|${style.fontSize}|'
      '${style.height}|${style.fontFamily}|${scaler.scale(10)}|'
      '${_settings.textJustification.name}|${_settings.horizontalMargin}|'
      '${_settings.respectCssStyles}|${_settings.overrideCssFontSize}|'
      '${_settings.overrideCssFontFamily}|${_settings.overrideCssColor}';

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
    if (flatIndex < 0 || flatIndex >= _flatTotal) return null;
    // Largest chapter whose start is <= flatIndex.
    var lo = 0, hi = _flatStart.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_flatStart[mid] <= flatIndex) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    // A chapter with zero pages shares its start with the next one; skip
    // forward until we land on the chapter that actually holds this page.
    var chapter = lo;
    var pageIndex = flatIndex - _flatStart[chapter];
    while (pageIndex >= _paginators[chapter].pages.length) {
      chapter++;
      if (chapter >= _paginators.length) return null;
      pageIndex = flatIndex - _flatStart[chapter];
    }
    return (chapter, pageIndex);
  }

  int get _flatPageCount => _flatTotal;

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
    const scaler = TextScaler.noScaling;
    final sig = _signatureFor(viewport, style, scaler);

    final anchor = _currentAnchor();

    // Cache hit: swap the full previous layout in instantly.
    final cached = _paginationCache.remove(sig);
    if (cached != null) _paginationCache[sig] = cached;
    if (cached != null && cached.length >= _doc!.chapters.length) {
      _applyFullLayout(cached, style, sig, anchor);
      return;
    }

    _startReflow(viewport, style, scaler, sig, anchor);
  }

  /// The `(chapter, offset)` the reader is currently on. Prefers the live page
  /// when it points at a real paginator, falling back to the stored anchor
  /// while a pass is mid-flight.
  (int, int) _currentAnchor() {
    // Mid-pass the live page is from a partially-changed layout; the first
    // change's target is kept for the whole pass instead.
    if (!_passSettled) return (_anchorChapter, _anchorOffset);
    // If the stored anchor is still on the page the reader is looking at,
    // keep its exact offset. Re-deriving the page start here would lose
    // intra-page position and drift backwards on every re-layout.
    final c = _anchorChapter;
    if (c >= 0 && c < _paginators.length) {
      final pages = _paginators[c].pages;
      final idx = _flatPage - _flatStart[c];
      if (idx >= 0 &&
          idx < pages.length &&
          pages[idx].start <= _anchorOffset &&
          _anchorOffset < pages[idx].end) {
        return (c, _anchorOffset);
      }
    }
    final ref = _refAt(_flatPage);
    if (ref == null) return (_anchorChapter, _anchorOffset);
    final rc = ref.$1;
    if (rc < 0 || rc >= _paginators.length) {
      return (_anchorChapter, _anchorOffset);
    }
    return (rc, _paginators[rc].pages[ref.$2].start);
  }

  /// Paginate every chapter into a buffer behind the progress view and swap
  /// in atomically once done.  The reader opens fully laid out — no
  /// placeholders, no `…` page counts, no re-anchor jumps.
  void _startInitialFullPass(
  Size viewport,
  TextStyle style,
  TextScaler scaler,
  (int, int) anchor,
  String signature,
) {
  final n = _doc!.chapters.length;
  _disposeDrivers();
  _cancelReflow();

  _chapterStyles = List.filled(n, style);
  _paginators
    ..clear()
    ..addAll(List.generate(n, (_) => _emptyPaginator()));
  _paginationReady = List.filled(n, false);
  _layoutSignature = signature;
  _anchorChapter = anchor.$1.clamp(0, n - 1);
  _anchorOffset = anchor.$2;
  _recomputeFlatIndexes();

  final old = _pageController;
  _pageController = null;
  if (old != null) {
    WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
  }

  // Delay the first paint until the WHOLE book is paginated (deliberate
  // product choice). The controller is left null so the "Laying out pages…"
  // view stays up while the full pass below runs; when it completes,
  // _applyReflow swaps the complete layout in atomically and only then is the
  // controller created. There is no anchor-chapter early paint.
  OpenTrace.dump();
  _paginationRunning = true;

  // Build every chapter into the reflow buffer and swap when done. The buffer
  // starts entirely empty (no anchor pre-layout) so nothing paints until the
  // whole book is ready.
  _reflowPages = List.of(_paginators);
  _reflowStyles = List.of(_chapterStyles);
  _reflowReady = List.filled(n, false);
  _reflowNext = 0;
  _reflowOrder = fillOrderFor(n, _anchorChapter);
  _reflowSignature = signature;
  _reflowGeneration++;
  final generation = _reflowGeneration;
  if (mounted) setState(() {});
  _reflowNextBatch(viewport, style, scaler, generation);
}

  /// Adopt a fully-built layout (cache hit or completed pass) and land on
  /// [anchor] without further work.
  void _applyFullLayout(
    List<Paginator> pages,
    TextStyle style,
    String? signature,
    (int, int) anchor,
  ) {
    _disposeDrivers();
    _cancelReflow();
    _paginators
      ..clear()
      ..addAll(pages);
    _chapterStyles = List.filled(_paginators.length, style);
    _paginationReady = List.filled(_paginators.length, true);
    if (signature != null) _layoutSignature = signature;
    _recomputeFlatIndexes();
    _anchorChapter = anchor.$1.clamp(0, _paginators.length - 1);
    _anchorOffset = anchor.$2;
    _paginationRunning = false;
    _setControllerToAnchor(recreate: true);
  }

  /// Begin an atomic reflow for a new layout. The current and next chapters are
  /// re-laid out in the live set immediately (so the new style is visible on
  /// screen and when paging forward); the rest are built into a buffer and
  /// swapped in when the whole pass finishes. The live set stays complete
  /// throughout, so the page count and scrubber never break.
  void _startReflow(
    Size viewport,
    TextStyle style,
    TextScaler scaler,
    String signature,
    (int, int) anchor,
  ) {
    // If the live set is not complete (a layout change arrived while the
    // initial full pass was still building), do a full pass instead of a
    // reflow so the reader opens fully laid out.
    if (!_allPaginatorsReady) {
      _startInitialFullPass(viewport, style, scaler, anchor, signature);
      return;
    }
    final n = _doc!.chapters.length;
    // Supersede any in-flight initial pass or reflow.
    _disposeDrivers();
    _cancelReflow();
    _paginationRunning = false;

    // Normalize the live set to the full chapter count.
    while (_paginators.length < n) {
      _paginators.add(_emptyPaginator());
    }
    if (_paginationReady.length < n) {
      _paginationReady = List.filled(n, false);
    }
    if (_chapterStyles.length < n) {
      _chapterStyles = List.filled(n, style);
    }

    _anchorChapter = anchor.$1.clamp(0, n - 1);
    _anchorOffset = anchor.$2;

    // Re-layout the visible chapter now so the new style shows immediately;
    // navigation lays out further chapters on demand.
    _paginateChapterSync(_anchorChapter, viewport, style, scaler);
    _recomputeFlatIndexes();
    _setControllerToAnchor(recreate: true);

    // Build the rest into a buffer seeded from the live (mixed) set.
    _reflowPages = List.of(_paginators);
    _reflowStyles = List.of(_chapterStyles);
    _reflowReady = List.filled(n, false);
    _reflowReady[_anchorChapter] = true;
    _reflowNext = 0;
    _reflowOrder = fillOrderFor(n, _anchorChapter);
    _reflowSignature = signature;
    _reflowGeneration++;
    final generation = _reflowGeneration;
    if (mounted) setState(() {});
    _reflowNextBatch(viewport, style, scaler, generation);
  }

  /// Advance the reflow pass within the frame budget, then yield.
  void _reflowNextBatch(
    Size viewport,
    TextStyle style,
    TextScaler scaler,
    int generation,
  ) {
    if (!mounted || _doc == null) return;
    if (debugSuspendBackgroundFill) return;
    if (generation != _reflowGeneration) return;
    final pages = _reflowPages;
    final styles = _reflowStyles;
    if (pages == null || styles == null) return;
    final stopwatch = Stopwatch()..start();
    final order = _reflowOrder;

    while (_reflowNext < order.length) {
      final c = order[_reflowNext];
      if (_reflowReady[c]) {
        _reflowNext++;
        continue;
      }
      var driver = _reflowDrivers[c];
      driver ??= _makeDriver(c, viewport, style, scaler);
      _reflowDrivers[c] = driver;

      driver.nextChunkUntil(minPages: 1, budget: _paginationFrameBudget);

      if (driver.isDone) {
        pages[c] = driver.toPaginator();
        styles[c] = style;
        _reflowReady[c] = true;
        driver.dispose();
        _reflowDrivers.remove(c);
        _reflowNext++;
      }

      if (stopwatch.elapsedMilliseconds > 12) {
        if (mounted) setState(() {});
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _reflowNextBatch(viewport, style, scaler, generation);
        });
        return;
      }
    }

    _applyReflow(style, _reflowSignature, generation);
  }

  /// Swap the completed reflow buffer in atomically.
  void _applyReflow(TextStyle style, String? signature, int generation) {
    // Don't cancel a page turn the reader is making; swap once it settles.
    _whenPageIdle(() {
      if (!mounted) return;
      if (generation != _reflowGeneration) return;
      final pages = _reflowPages;
      if (pages == null) return;
      _paginationRunning = false;
      _paginators
        ..clear()
        ..addAll(pages);
      _chapterStyles = List.filled(pages.length, style);
      _paginationReady = List.filled(pages.length, true);
      if (signature != null) _layoutSignature = signature;
      _recomputeFlatIndexes();
      _cancelReflow();
      _setControllerToAnchor(recreate: true);
      if (_allPaginatorsReady && _layoutSignature != null) {
        _cacheLayout(_layoutSignature!, _paginators);
      }
      if (mounted) setState(() {});
    });
  }

  void _cancelReflow() {
    _reflowGeneration++;
    for (final d in _reflowDrivers.values) {
      d.dispose();
    }
    _reflowDrivers.clear();
    _reflowPages = null;
    _reflowStyles = null;
    _reflowReady = const [];
    _reflowNext = 0;
    _reflowOrder = const [];
    _reflowSignature = null;
  }

  /// Lay out [chapter] synchronously and mark it ready. Used for the anchor
  /// chapter at open time and for on-demand jumps (TOC, search, bookmarks).
  void _paginateChapterSync(
    int chapter,
    Size viewport,
    TextStyle style,
    TextScaler scaler,
  ) {
    debugSyncLayouts++;
    _paginators[chapter] = Paginator.paginate(
      text: _doc!.chapters[chapter].body,
      style: style,
      maxWidth: viewport.width,
      maxHeight: viewport.height,
      direction: TextDirection.ltr,
      firstPageInset: _titleInset(chapter, viewport, style, scaler),
      textScaler: scaler,
      runs: _doc!.chapters[chapter].runs,
      images: _doc!.chapters[chapter].images,
      settings: _settings,
      theme: _settings.colors,
    );
    _chapterStyles[chapter] = style;
    _paginationReady[chapter] = true;
  }

  /// True when `_paginators[chapter]` is a real layout, not a placeholder.
  bool _isChapterReady(int chapter) =>
      chapter >= 0 &&
      chapter < _paginationReady.length &&
      _paginationReady[chapter];

  /// Lays out [chapter] on demand when a jump lands ahead of the background
  /// pass, so navigation never shows a blank page. Only the requested chapter
  /// is laid out — the pass fills forward from the anchor on its own — and an
  /// already-laid-out chapter is left alone. Mirrors the result into the
  /// in-flight reflow buffer when one exists so the atomic swap can't regress
  /// it back to a placeholder.
  void _ensureChapterReady(int chapter) {
    final viewport = _lastViewport;
    if (_doc == null || viewport == null) return;
    if (chapter < 0 || chapter >= _paginators.length) return;
    if (_isChapterReady(chapter)) return;
    final style = _settings.textStyle(context);
    const scaler = TextScaler.noScaling;
    _paginateChapterSync(chapter, viewport, style, scaler);
    _recomputeFlatIndexes();
    if (_reflowActive && chapter < _reflowPages!.length) {
      _reflowPages![chapter] = _paginators[chapter];
      _reflowStyles![chapter] = _chapterStyles[chapter];
      _reflowReady[chapter] = true;
    }
    if (mounted) setState(() {});
  }

  ChapterPaginationDriver _makeDriver(
    int chapter,
    Size viewport,
    TextStyle style,
    TextScaler scaler,
  ) {
    return ChapterPaginationDriver(
      text: _doc!.chapters[chapter].body,
      style: style,
      maxWidth: viewport.width,
      maxHeight: viewport.height,
      direction: TextDirection.ltr,
      firstPageInset: _titleInset(chapter, viewport, style, scaler),
      textScaler: scaler,
      runs: _doc!.chapters[chapter].runs,
      images: _doc!.chapters[chapter].images,
      settings: _settings,
      theme: _settings.colors,
    );
  }

  /// Runs [action] once the page view is not mid-drag or mid-animation, so a
  /// background pass can never cancel a page turn the reader is making.
  void _whenPageIdle(VoidCallback action) {
    final controller = _pageController;
    if (controller != null &&
        controller.hasClients &&
        controller.position.isScrollingNotifier.value) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _whenPageIdle(action);
      });
      return;
    }
    action();
  }

  void _setControllerToAnchor({required bool recreate}) {
    final flat = _flatIndexForPosition(_anchorChapter, _anchorOffset);
    _programmaticTarget = flat;
    if (recreate) {
      final old = _pageController;
      _pageController = null;
      if (old != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
      }
      setState(() {
        _pageController = PageController(initialPage: flat, keepPage: false);
        _flatPage = flat;
      });
      final controller = _pageController;
      // Scroll-offset retention can restore the previous controller's page
      // instead of [initialPage]; jump explicitly after the first frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _pageController != controller) return;
        if (controller!.hasClients) controller.jumpToPage(flat);
      });
      return;
    }
    setState(() => _flatPage = flat);
    final controller = _pageController;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _pageController != controller) return;
      if (controller!.hasClients) controller.jumpToPage(flat);
    });
  }

  void _disposeDrivers() {
    for (final d in _paginationDrivers.values) {
      d.dispose();
    }
    _paginationDrivers.clear();
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
  bool get debugLazyRunning => _paginationRunning || _reflowActive;

  @visibleForTesting
  int get debugChapterCount => _doc?.chapters.length ?? -1;
  @visibleForTesting
  int get debugPaginatorCount => _paginators.length;
  @visibleForTesting
  int get debugFlatPageCount => _flatPageCount;
  @visibleForTesting
  bool get debugAllReady => _allPaginatorsReady;
  @visibleForTesting
  int get debugReadyCount => _paginationReady.where((r) => r).length;

  /// Test-only: suspends the background layout pass so a test can observe the
  /// first-paint state deterministically instead of racing the frame budget.
  @visibleForTesting
  static bool debugSuspendBackgroundFill = false;

  /// Test-only: how many synchronous chapter layouts have been performed.
  @visibleForTesting
  int debugSyncLayouts = 0;
  @visibleForTesting
  bool get debugHasController => _pageController != null;

  @visibleForTesting
  int get debugComicPage => _comicCtrl.comicPage;

  @visibleForTesting
  bool get debugComicZoomed => _comicZoomed;

  @visibleForTesting
  TransformationController? get debugComicTransform =>
      _comicTransformationController;

  @visibleForTesting
  TransformationController debugVerticalTransformerFor(int index) =>
      _comicCtrl.verticalTransformer(index);

  @visibleForTesting
  Iterable<TransformationController> get debugAllVerticalTransformers =>
      _comicCtrl.verticalTransformers;

  @visibleForTesting
  double get debugComicPreviewOffset =>
      _comicCtrl.comicPreviewScrollController.hasClients
      ? _comicCtrl.comicPreviewScrollController.offset
      : 0;

  /// Coalesces settings persistence: a slider drag commits once, but the
  /// debounce net or a quick run of discrete tweaks shouldn't hit disk each
  /// time.
  Timer? _settingsSaveDebounce;

  void _onSettingsChanged() {
    _settingsSaveDebounce?.cancel();
    _settingsSaveDebounce = Timer(const Duration(milliseconds: 600), () {
      widget.library.saveSettings();
    });
    // Recreate the selection toolbar with fresh theme on next use.
    _selectionToolbar?.dismiss();
    _selectionToolbar = null;
    _selectedWordRange = null;
    // Update wakelock.
    if (_settings.keepScreenOn) {
      WakelockPlus.enable();
    } else {
      WakelockPlus.disable();
    }
    // Apply hardware brightness.
    BrightnessController.instance.apply(_settings.brightness);
    // Relayout PDF when scroll direction changes.
    if (_isPdf && _pdfCtrl.pdfController.isReady) {
      _pdfCtrl.pdfController.invalidate();
    }
    // Repaginate only when the layout-affecting signature changed.
    final viewport = _lastViewport;
    if (!_isPdf && _doc != null && viewport != null) {
      final style = _settings.textStyle(context);
      const scaler = TextScaler.noScaling;
      final sig = _signatureFor(viewport, style, scaler);
      // Repaginate when the requested style differs from the live layout, or
      // when a reflow is still building a different one (e.g. the user changed
      // a setting and changed it straight back).
      final needsRepaginate = _reflowActive
          ? sig != _reflowSignature
          : sig != _layoutSignature;
      if (needsRepaginate) {
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
      _searchCtrl.initPdfSearch(_pdfCtrl.pdfController);
      return;
    }
    if (_doc == null) return;
    _searchCtrl.setChapters(_doc!.chapters);
  }

  void _onSearchTextChanged() => _searchCtrl.onSearchTextChanged();

  void _submitSearch() => _searchCtrl.submitSearch();

  void _toggleSearch() {
    _searchCtrl.toggleSearch();
    if (_searchCtrl.searchOpen) {
      _initSearch();
    }
  }

  void _jumpToResult(int index) {
    if (index < 0 || index >= _searchCtrl.searchResults.length) return;
    _searchCtrl.jumpToResult(index);
    if (!_isPdf) {
      final result = _searchCtrl.searchResults[index];
      if (result.chapter < 0 || result.chapter >= _paginators.length) return;
      _ensureChapterReady(result.chapter);
      final pag = _paginators[result.chapter];
      final pageIndex = result.offset > 0 ? pag.pageIndexFor(result.offset) : 0;
      final flat = _flatIndexForChapter(result.chapter) + pageIndex;
      _anchorChapter = result.chapter;
      _anchorOffset = result.offset;
      _programmaticTarget = flat;
      _pageController?.jumpToPage(flat);
      setState(() => _flatPage = flat);
    }
    if (!_chromeVisible) {
      setState(() => _chromeVisible = true);
    }
  }

  void _prevResult() {
    if (_searchCtrl.searchResults.isEmpty) return;
    if (_isPdf) {
      _searchCtrl.pdfSearcher?.goToPrevMatch();
      return;
    }
    _searchCtrl.prevResult();
  }

  void _nextResult() {
    if (_searchCtrl.searchResults.isEmpty) return;
    if (_isPdf) {
      _searchCtrl.pdfSearcher?.goToNextMatch();
      return;
    }
    _searchCtrl.nextResult();
  }

  Widget _buildSearchOverlay(ReaderTheme theme) {
    final count = _searchCtrl.searchResults.length;
    final isDone = _searchCtrl.searchDone;
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
                      controller: _searchCtrl.searchController,
                      focusNode: _searchCtrl.searchFocusNode,
                      style: TextStyle(color: theme.text, fontSize: 15),
                      decoration: InputDecoration(
                        hintText: 'Search book…',
                        hintStyle: TextStyle(color: theme.muted),
                        border: InputBorder.none,
                        prefixIcon: Icon(
                          Icons.search,
                          color: theme.muted,
                          size: 20,
                        ),
                        suffixIcon: _searchCtrl.searchController.text.isNotEmpty
                            ? IconButton(
                                icon: Icon(
                                  Icons.clear,
                                  color: theme.muted,
                                  size: 20,
                                ),
                                onPressed: () {
                                  _searchCtrl.searchController.clear();
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
                      icon: Icon(
                        Icons.keyboard_arrow_up,
                        color: theme.text,
                        size: 22,
                      ),
                      onPressed: _prevResult,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 32,
                      ),
                    ),
                    IconButton(
                      icon: Icon(
                        Icons.keyboard_arrow_down,
                        color: theme.text,
                        size: 22,
                      ),
                      onPressed: _nextResult,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 32,
                      ),
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
                    final r = _searchCtrl.searchResults[i];
                    final isCurrent = i == _searchCtrl.currentResultIndex;
                    final label = _isPdf
                        ? 'Page ${r.chapter}'
                        : (_doc?.chapters[r.chapter].title ?? '').isEmpty
                        ? 'Chapter ${r.chapter + 1}'
                        : _doc!.chapters[r.chapter].title;
                    return InkWell(
                      onTap: () => _jumpToResult(i),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
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
                              style: TextStyle(color: theme.text, fontSize: 13),
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

  void _showSelectionToolbar(
    Offset globalPosition, {
    required bool singleWord,
    required String word,
    required String text,
  }) {
    _selectionToolbar ??= SelectionToolbarOverlay(
      context: context,
      theme: _settings.colors,
      library: widget.library,
      onDismiss: () {
        _selectedWordRange = null;
        if (context.mounted) setState(() {});
      },
    );
    _selectionToolbar!.show(
      globalPosition,
      singleWord: singleWord,
      word: word,
      text: text,
    );
    setState(() {});
  }

  void _dismissSelectionToolbar() {
    _selectionToolbar?.dismiss();
    _selectedWordRange = null;
    if (mounted) setState(() {});
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = _settings.colors;
    Widget body;
    if (_error != null) {
      body = _ErrorView(
        message: _error!,
        book: _book,
        library: widget.library,
        onRelinked: _retryAfterRelink,
      );
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
    if (_pdfCtrl.pdfFileExists == false) {
      return _ErrorView(
        message: 'File not found',
        book: _book,
        library: widget.library,
        onRelinked: _retryAfterRelink,
      );
    }
    final viewer = PdfViewer.file(
      _book.path,
      key: ValueKey(_book.path),
      initialPageNumber: _book.lastChapter + 1 < 1 ? 1 : _book.lastChapter + 1,
      controller: _pdfCtrl.pdfController,
      params: PdfViewerParams(
        backgroundColor: theme.background,
        textSelectionParams: PdfTextSelectionParams(
          enabled: true,
          onTextSelectionChange: (selection) async {
            if (!selection.hasSelectedText) {
              _dismissSelectionToolbar();
              return;
            }
            final selectedText = await selection.getSelectedText();
            if (!mounted) return;
            final trimmed = selectedText.trim();
            if (trimmed.isNotEmpty && trimmed.length < 50) {
              final words = trimmed.split(RegExp(r'\s+'));
              final word = words.first.replaceAll(
                RegExp(r'[^a-zA-Z\u00C0-\u024F]'),
                '',
              );
              if (word.length >= 2) {
                final size = MediaQuery.sizeOf(context);
                _showSelectionToolbar(
                  Offset(size.width / 2, size.height / 2),
                  singleWord: true,
                  word: word,
                  text: word,
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
                final height =
                    pages.fold(
                      0.0,
                      (prev, page) => math.max(prev, page.height),
                    ) +
                    margin * 2;
                final pageLayouts = <Rect>[];
                double x = margin;
                final rtl =
                    _settings.pdfLayoutDirection ==
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
          setState(() => _pdfCtrl.pdfLoading = false);
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
              onDoubleTapDown: (_) => _toggleZoomMode(),
            ),
          ),
        ],
        pagePaintCallbacks: [
          if (_searchCtrl.pdfSearcher != null)
            _searchCtrl.pdfSearcher!.pageTextMatchPaintCallback,
        ],
      ),
    );

    return Stack(
      children: [
        Positioned.fill(child: viewer),
        if (_pdfCtrl.pdfLoading)
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
            centerLabel: _pdfCtrl.pdfPageCount == 0
                ? '-/-'
                : 'Page ${_pdfCtrl.pdfPage} of ${_pdfCtrl.pdfPageCount}',
            sliderMax: _pdfCtrl.pdfPageCount > 1 ? _pdfCtrl.pdfPageCount : 1,
            sliderValue: _pdfCtrl.pdfPage.clamp(
              1,
              _pdfCtrl.pdfPageCount > 0 ? _pdfCtrl.pdfPageCount : 1,
            ),
            sliderLabel: _pdfCtrl.pdfPageCount == 0
                ? '-/-'
                : '${((_pdfCtrl.pdfPage / _pdfCtrl.pdfPageCount) * 100).round()}%',
            onSliderChanged: (v) {
              if (_pdfCtrl.pdfController.isReady) {
                _pdfCtrl.pdfController.goToPage(pageNumber: v);
              }
            },
          ),
        ),
      ],
    );
  }

  // ---------------------------- Comic ----------------------------------------

  Future<void> _loadComicPages() async {
    await _comicCtrl.loadComicPages(
      onLoaded: () {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _prefetchComicPages(_comicCtrl.comicPage);
          _comicDecodeAhead?.advance(_comicCtrl.comicPage);
          _comicCtrl.restoreComicPosition();
        });
      },
    );
    if (!mounted) return;
  }

  /// Reloads the current document after a successful Locate (relink).
  /// Covers reflowable, comic and PDF paths. PDF re-checks file existence
  /// (cached [PdfReaderController.pdfFileExists]) and resets loading state
  /// so the viewer rebuilds with the new [_book.path] instead of
  /// re-rendering the same _ErrorView.
  Future<void> _retryAfterRelink() async {
    if (!mounted) return;
    setState(() {
      _error = null;
      _doc = null;
    });
    if (_isComic) {
      await _loadComicPages();
    } else if (_isPdf) {
      _pdfCtrl.pdfLoading = true;
      await _pdfCtrl.recheckExists(_book.path);
      if (!mounted) return;
      setState(() {});
    } else {
      await _loadDocument();
    }
  }

  Widget _buildComic(ReaderTheme theme) {
    if (_comicCtrl.comicLoading) {
      return Center(child: CircularProgressIndicator(color: theme.accent));
    }
    if (_comicCtrl.comicError != null) {
      return _ErrorView(
        message: _comicCtrl.comicError!,
        book: _book,
        library: widget.library,
        onRelinked: _retryAfterRelink,
      );
    }
    if (_comicCtrl.comicPages.isEmpty) {
      return _ErrorView(
        message: 'No pages found in comic',
        book: _book,
        library: widget.library,
        onRelinked: _retryAfterRelink,
      );
    }
    if (_settings.comicReadingMode == ComicReadingMode.vertical) {
      return _buildComicVertical(theme);
    }
    return _buildComicPaginated(theme);
  }

  Widget _buildComicPaginated(ReaderTheme theme) {
    final rtl = _settings.comicReadingDirection == ComicReadingDirection.rtl;
    _comicTransformationController ??= TransformationController();
    _listenComicTransform(_comicTransformationController!);
    // While the page is zoomed in, the pager must not compete for the drag:
    // one-finger drags pan the zoomed page and two-finger pinches reach the
    // InteractiveViewer instead of flipping to the next page.
    final zoomed = _anyComicTransformZoomed();
    return Stack(
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) {
            if (_zoomMode) return; // let InteractiveViewer handle taps
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
          onDoubleTapDown: (_) => _toggleZoomMode(),
          child: PageView.builder(
            reverse: rtl,
            controller: _comicCtrl.comicPageController!,
            physics: zoomed ? const NeverScrollableScrollPhysics() : null,
            // Warm the adjacent pages during flips: combined with the
            // decode-ahead window they render without a decode stall.
            allowImplicitScrolling: true,
            itemCount: _comicCtrl.comicPageCount,
            onPageChanged: (i) {
              _comicCtrl.notePageChanged(i);
              widget.library.savePosition(
                id: _book.id,
                chapter: i,
                offset: 0,
                progress: _comicCtrl.comicPageCount == 0
                    ? 0
                    : (i + 1) / _comicCtrl.comicPageCount,
              );
                      if (_comicCtrl.isLazy) _prefetchComicPages(i);
              _comicDecodeAhead?.advance(i);
              if (_comicCtrl.comicPreviewVisible) _scrollToPreviewPage(i);
            },
            itemBuilder: (context, i) {
              final meta = _comicCtrl.pageMetaAt(i);
              final bounds = meta == null
                  ? null
                  : comicPageDecodeBounds(
                      fit: _comicCtrl.boxFit,
                      viewport: MediaQuery.sizeOf(context),
                      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
                      intrinsic: (
                        meta.intrinsicWidth,
                        meta.intrinsicHeight,
                      ),
                    );
              final page = _comicCtrl.isLazy
                  ? _LazyComicPageWidget(
                      provider: _comicCtrl.comicPageProvider!,
                      pageIndex: i,
                      fit: _comicCtrl.boxFit,
                      bounds: bounds,
                    )
                  : ComicImage(
                      bytes: _comicCtrl.comicPages[i],
                      fit: _comicCtrl.boxFit,
                      provider: bounds == null
                          ? null
                          : comicPageImageProvider(
                              _comicCtrl.comicPages[i],
                              bounds,
                            ),
                    );
              if (_zoomMode) {
                return InteractiveViewer(
                  transformationController: _comicTransformationController,
                  minScale: 1.0,
                  maxScale: _zoomMax,
                  child: Center(child: page),
                );
              }
              return Center(child: page);
            },
          ),
        ),
        IgnorePointer(
          ignoring: !_chromeVisible,
          child: _chrome(
            centerLabel:
                'Page ${_comicCtrl.comicPage + 1} of ${_comicCtrl.comicPageCount}',
            sliderMax: _comicCtrl.comicPageCount > 1
                ? _comicCtrl.comicPageCount
                : 1,
            sliderValue: (_comicCtrl.comicPage + 1).clamp(
              1,
              _comicCtrl.comicPageCount > 0 ? _comicCtrl.comicPageCount : 1,
            ),
            sliderLabel: _comicCtrl.comicPageCount == 0
                ? '-/-'
                : '${(((_comicCtrl.comicPage + 1) / _comicCtrl.comicPageCount) * 100).round()}%',
            onSliderChanged: (v) {
              _comicCtrl.jumpToPage(v - 1);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildComicVertical(ReaderTheme theme) {
    _comicCtrl.comicVerticalScrollController ??= ScrollController();
    final controller = _comicCtrl.comicVerticalScrollController!;
    if (!_comicCtrl.comicVerticalListenerAttached) {
      _comicCtrl.comicVerticalListenerAttached = true;
      controller.addListener(() {
        if (!mounted) return;
        final count = _comicCtrl.comicPageCount;
        if (count == 0) return;
        final newIndex = _comicCtrl.nearestPageIndex(
          MediaQuery.paddingOf(context).top,
        );
        if (newIndex != _comicCtrl.comicPage) {
          _comicCtrl.notePageChanged(newIndex);
          _saveComicPosition(
            newIndex,
            controller.offset.toInt(),
            (newIndex + 1) / count,
          );
          if (_comicCtrl.isLazy) _prefetchComicPages(newIndex);
          if (_comicCtrl.comicPreviewVisible) _scrollToPreviewPage(newIndex);
        }
      });
    }
    return Stack(
      children: [
        GestureDetector(
          behavior: HitTestBehavior.translucent,
          onDoubleTapDown: (_) => _toggleZoomMode(),
          child: ListView.builder(
            controller: controller,
            padding: EdgeInsets.zero,
            itemCount: _comicCtrl.comicPageCount,
            // While a page is zoomed in, the list must not compete for the
            // drag: drags pan the zoomed page instead of scrolling pages.
            physics: _anyComicTransformZoomed()
                ? const NeverScrollableScrollPhysics()
                : null,
            itemBuilder: (context, i) {
              final transform = _comicCtrl.verticalTransformer(i);
              _listenComicTransform(transform);
              return InteractiveViewer(
                key: _comicCtrl.verticalPageKey(i),
                transformationController: _zoomMode ? transform : null,
                minScale: 1.0,
                maxScale: _zoomMode ? _zoomMax : 1.0,
                scaleEnabled: _zoomMode,
                child: Center(
                  child: _comicCtrl.isLazy
                      ? _LazyComicPageWidget(
                          provider: _comicCtrl.comicPageProvider!,
                          pageIndex: i,
                          fit: _comicCtrl.boxFit,
                        )
                      : ComicImage(
                          bytes: _comicCtrl.comicPages[i],
                          fit: _comicCtrl.boxFit,
                        ),
                ),
              );
            },
          ),
        ),
        IgnorePointer(
          ignoring: !_chromeVisible,
          child: _chrome(
            centerLabel:
                'Page ${_comicCtrl.comicPage + 1} of ${_comicCtrl.comicPageCount}',
            sliderMax: _comicCtrl.comicPageCount > 1
                ? _comicCtrl.comicPageCount
                : 1,
            sliderValue: (_comicCtrl.comicPage + 1).clamp(
              1,
              _comicCtrl.comicPageCount > 0 ? _comicCtrl.comicPageCount : 1,
            ),
            sliderLabel: _comicCtrl.comicPageCount == 0
                ? '-/-'
                : '${(((_comicCtrl.comicPage + 1) / _comicCtrl.comicPageCount) * 100).round()}%',
            onSliderChanged: (v) {
              _comicCtrl.jumpToPage(v - 1);
            },
          ),
        ),
      ],
    );
  }

  /// Warmup pass for horizontal comic reading: decodes the ±3-page window
  /// around the reader position into the image cache so flips paint without
  /// a decode stall (vertical mode keeps widget-built lazy loads).
  ComicDecodeAhead? _comicDecodeAhead;

  @visibleForTesting
  ComicDecodeAhead? get debugComicDecodeAhead => _comicDecodeAhead;

  /// Prefetch pages within ±3 of [center] and evict those further out.
  void _prefetchComicPages(int center) =>
      unawaited(_comicCtrl.prefetchComicPages(center));

  /// Wires the decode-ahead pass to the live comic state. Closures run on
  /// later frames, so reading [context]/[MediaQuery] here is safe even
  /// though this is built during [initState].
  ComicDecodeAhead _createComicDecodeAhead() => ComicDecodeAhead(
        loadBytes: (index) async {
          final ctrl = _comicCtrl;
          if (index < 0 || index >= ctrl.comicPageCount) return null;
          final provider = ctrl.comicPageProvider;
          if (provider != null) return provider.loadPage(index);
          return index < ctrl.comicPages.length
              ? ctrl.comicPages[index]
              : null;
        },
        resolveBounds: (index) {
          final meta = _comicCtrl.pageMetaAt(index);
          if (meta == null) return null;
          return comicPageDecodeBounds(
            fit: _comicCtrl.boxFit,
            viewport: MediaQuery.sizeOf(context),
            devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
            intrinsic: (meta.intrinsicWidth, meta.intrinsicHeight),
          );
        },
        warmup: (provider) {
          if (!mounted) return;
          unawaited(
            precacheImage(provider, context).catchError((Object e) {
              debugPrint('comic decode-ahead dropped a page: $e');
            }),
          );
        },
        onSkip: (index, reason) =>
            debugPrint('comic decode-ahead skipped page $index: $reason'),
      );

  void _scrollToPreviewPage(int page) => _comicCtrl.scrollToPreviewPage(page);

  // ---------------------------- Reflowable -----------------------------------

  /// Fraction of chapters laid out in the pass currently running.
  double get _paginationProgress {
    final n = _doc?.chapters.length ?? 0;
    if (n == 0) return 0;
    final ready = _reflowActive ? _reflowReady : _paginationReady;
    if (ready.isEmpty) return 0;
    return ready.where((r) => r).length / n;
  }

  /// Progress view shown while the whole book is being laid out on first open.
  Widget _buildLayingOutView(ReaderTheme theme) {
    final progress = _paginationProgress;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LinearProgressIndicator(
              value: progress > 0 ? progress : null,
              backgroundColor: theme.muted.withValues(alpha: 0.2),
              valueColor: AlwaysStoppedAnimation(theme.accent),
            ),
            const SizedBox(height: 16),
            Text(
              'Laying out pages…',
              style: TextStyle(fontSize: 14, color: theme.muted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReflowable(BuildContext context, ReaderTheme theme) {
    if (_doc == null) {
      // Parsing phase, distinct from the pagination phase below: the spinner
      // is labeled so the two waits read differently on screen.
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: theme.accent),
            const SizedBox(height: 16),
            Text(
              'Opening book…',
              style: TextStyle(fontSize: 14, color: theme.muted),
            ),
          ],
        ),
      );
    }

    if (_paginationRunning && _pageController == null) {
      return _buildLayingOutView(theme);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = _contentViewport(constraints.biggest);
        final style = _settings.textStyle(context);
        const scaler = TextScaler.noScaling;
        final signature = _signatureFor(viewport, style, scaler);
        // Cache so settings changes measure against the layout that actually
        // produced the current paginators.
        _lastViewport = viewport;

        if (_layoutSignature != signature && _reflowSignature != signature) {
          final needsFirstLayout = _paginators.isEmpty;
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
          // First layout is starting; show the same view so there is no flash.
          return _buildLayingOutView(theme);
        }

        final itemCount = _flatPageCount;
        return Stack(
          children: [
            PageView.builder(
              controller: controller,
              itemCount: itemCount,
              onPageChanged: (i) {
                final programmatic = _programmaticTarget == i;
                _programmaticTarget = null;
                setState(() => _flatPage = i);
                final ref = _refAt(i);
                // Record user-driven page changes even while a background pass
                // is running, or the pass would re-anchor back to the page the
                // reader was on before they navigated.
                if (!programmatic && ref != null) {
                  final c = ref.$1;
                  // A swipe can land on a chapter the background pass has not
                  // laid out yet; lay it out so the page shows text, not a
                  // placeholder.
                  _ensureChapterReady(c);
                  _onPositionChanged(c, _paginators[c].pages[ref.$2].start);
                }
                _bookmarkCtrl.checkBookmarkState();
              },
              itemBuilder: (context, i) {
                final ref = _refAt(i);
                if (ref == null) return const SizedBox.shrink();
                final chapter = ref.$1;
                final page = _paginators[chapter].pages[ref.$2];
                // Compute highlights for this page.
                List<SearchResult>? highlights;
                if (_searchCtrl.searchOpen &&
                    _searchCtrl.bookSearch != null &&
                    _searchCtrl.searchResults.isNotEmpty) {
                  highlights = _searchCtrl.bookSearch!.matchesForPage(
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
                final chapterStyle = chapter < _chapterStyles.length
                    ? _chapterStyles[chapter]
                    : style;
                final renderStyle = chapterStyle.copyWith(
                  color: _settings.colors.text,
                );
                return _PageContent(
                  chapterTitle: _doc!.chapters[chapter].title,
                  text: _doc!.chapters[chapter].body,
                  runs: _doc!.chapters[chapter].runs,
                  images: _doc!.chapters[chapter].images,
                  links: _doc!.chapters[chapter].links,
                  onTapLink: (target) {
                    _dismissSelectionToolbar();
                    _jumpToChapter(target);
                  },
                  page: page,
                  style: renderStyle,
                  theme: theme,
                  settings: _settings,
                  onTapPrev: () {
                    _dismissSelectionToolbar();
                    _flip(-1);
                  },
                  onTapNext: () {
                    _dismissSelectionToolbar();
                    _flip(1);
                  },
                  onTapCenter: () {
                    _dismissSelectionToolbar();
                    setState(() => _chromeVisible = !_chromeVisible);
                  },
                  highlightMatches: highlights,
                  currentMatch:
                      _searchCtrl.currentResultIndex >= 0 &&
                          _searchCtrl.currentResultIndex <
                              _searchCtrl.searchResults.length
                      ? _searchCtrl.searchResults[_searchCtrl
                            .currentResultIndex]
                      : null,
                  pageMaxHeight: _lastViewport?.height ?? double.infinity,
                  onLongPressWord: (word, globalPosition, bodyStart, bodyEnd) {
                    _selectedWordRange = (start: bodyStart, end: bodyEnd);
                    _showSelectionToolbar(
                      globalPosition,
                      singleWord: true,
                      word: word,
                      text: word,
                    );
                  },
                  selectedWordRange: _selectedWordRange,
                  textAlign:
                      _settings.textJustification == TextJustification.justify
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
                  if (v == _flatPage) return;
                  var target = v;
                  final ref = _refAt(v);
                  if (ref != null && !_isChapterReady(ref.$1)) {
                    _ensureChapterReady(ref.$1);
                    // The placeholder page is gone; land on the chapter start.
                    target = _flatStart[ref.$1];
                  }
                  controller.jumpToPage(target);
                },
              ),
            ),
            if (_searchCtrl.searchOpen) _buildSearchOverlay(theme),
          ],
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Initial pagination
  // ---------------------------------------------------------------------------

  /// Open the book at the saved position, laying out only the anchor chapter
  /// up front. The remaining chapters are scheduled in the background.
  void _restartPagination(Size viewport, TextStyle style, TextScaler scaler) {
    final n = _doc!.chapters.length;
    final target = _book.lastChapter.clamp(0, n - 1);
    final offset = _book.lastOffset;
    final sig = _signatureFor(viewport, style, scaler);

    final cached = _paginationCache.remove(sig);
    if (cached != null) _paginationCache[sig] = cached;
    if (cached != null && cached.length >= n) {
      _applyFullLayout(cached, style, sig, (target, offset));
      return;
    }

    _startInitialFullPass(viewport, style, scaler, (target, offset), sig);
  }

  void _flip(int direction) {
    if (_isPdf) {
      if (!_pdfCtrl.pdfController.isReady) return;
      final target = _pdfCtrl.pdfPage + direction;
      if (target < 1 || target > _pdfCtrl.pdfPageCount) return;
      _pdfCtrl.pdfController.goToPage(pageNumber: target);
      return;
    }
    if (_isComic) {
      // Delegates to the controller, which branches vertical mode through
      // the vertical scroll controller (no PageView clients there).
      _comicCtrl.flip(
        direction,
        verticalViewportHeight: MediaQuery.sizeOf(context).height,
      );
      return;
    }
    final controller = _pageController;
    if (controller == null) return;
    var target = _flatPage + direction;
    if (target < 0 || target >= _flatPageCount) return;
    final ref = _refAt(target);
    if (ref != null && !_isChapterReady(ref.$1)) {
      _ensureChapterReady(ref.$1);
      // The target chapter was a one-page placeholder. Now that it is laid
      // out, pick the end the turn belongs to: the last page for a backward
      // turn, the first for a forward one.
      target = direction < 0
          ? _flatStart[ref.$1] + _paginators[ref.$1].pages.length - 1
          : _flatStart[ref.$1];
    }
    if (target < 0 || target >= _flatPageCount) return;
    controller.animateToPage(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  /// Flat page index where [chapter] begins.
  int _flatIndexForChapter(int chapter) {
    if (chapter <= 0) return 0;
    if (chapter >= _flatStart.length) return _flatTotal;
    return _flatStart[chapter];
  }

  /// Jump directly to the start of [chapterIndex].
  void _jumpToChapter(int chapterIndex) {
    if (_doc == null || _pageController == null) return;
    _ensureChapterReady(chapterIndex);
    final flat = _flatIndexForChapter(chapterIndex);
    _anchorChapter = chapterIndex;
    _anchorOffset = 0;
    _programmaticTarget = flat;
    _pageController!.jumpToPage(flat);
    setState(() => _flatPage = flat);
  }

  void _showTocSheet() {
    if (_isPdf) {
      // PDF: show outline if available.
      if (_pdfCtrl.pdfOutline.isEmpty) return;
      TocSheet.showPdf(
        context,
        settings: _settings,
        outline: _pdfCtrl.pdfOutline,
        currentPage: _pdfCtrl.pdfPage,
        onJump: _jumpToPdfPage,
        bookmarks: _bookmarkCtrl.bookmarks,
        onDeleteBookmark: (bm) async {
          await widget.library.deleteBookmark(bm.id);
          await _bookmarkCtrl.loadBookmarks();
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
      readiness: _paginationReady,
      currentIndex: currentChapter,
      onJump: _jumpToChapter,
      bookmarks: _bookmarkCtrl.bookmarks,
      onDeleteBookmark: (bm) async {
        await widget.library.deleteBookmark(bm.id);
        await _bookmarkCtrl.loadBookmarks();
      },
    );
  }

  String _pageLabel() {
    final ref = _refAt(_flatPage);
    if (ref == null || _doc == null) return '';
    return _doc!.chapters[ref.$1].title;
  }

  String _progressPercent() {
    if (_flatPageCount == 0) return '';
    return '${_flatPage + 1} / $_flatPageCount';
  }

  void _showGoToPageDialog() {
    final theme = _settings.colors;
    final controller = TextEditingController();
    final maxPage = _isPdf
        ? _pdfCtrl.pdfPageCount
        : (_isComic ? _comicCtrl.comicPageCount : _flatPageCount);
    void goToPage(BuildContext dialogContext) {
      final page = int.tryParse(controller.text);
      if (page != null && page >= 1 && page <= maxPage) {
        Navigator.of(dialogContext).pop();
        if (_isPdf) {
          _jumpToPdfPage(page);
        } else if (_isComic) {
          _comicCtrl.jumpToPage(
            page - 1,
            verticalViewportHeight: MediaQuery.sizeOf(context).height,
          );
        } else {
          _pageController?.jumpToPage(page - 1);
        }
      }
    }

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
          onSubmitted: (_) => goToPage(ctx),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('Cancel', style: TextStyle(color: theme.muted)),
          ),
          TextButton(
            onPressed: () => goToPage(ctx),
            child: Text('Go', style: TextStyle(color: theme.accent)),
          ),
        ],
      ),
    ).then((_) => controller.dispose());
  }

  // ------------------------------ Chrome -------------------------------------

  GestureTapUpCallback _handleTapZones({required VoidCallback onCenter}) {
    return (details) {
      _dismissSelectionToolbar();
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

  /// Toggles follow-system brightness. Shared by the chrome brightness icon
  /// and the Auto/percentage label so both switch modes.
  void _toggleBrightnessMode() {
    if (_settings.brightness == null) {
      final gen = ++_brightnessSeedGen;
      BrightnessController.instance.current().then((v) {
        if (!mounted || gen != _brightnessSeedGen) return;
        // Clamp the raw plugin seed: values below the slider minimum (or
        // non-finite) would trip the Slider assertion on the next build.
        final lv = v.isFinite
            ? v.clamp(kMinBrightness, 1.0).toDouble()
            : 1.0;
        setState(() => _settings.brightness = lv);
        BrightnessController.instance.apply(lv);
        _onSettingsChanged();
      });
    } else {
      // Invalidate any in-flight seed so it can't resurrect manual mode.
      _brightnessSeedGen++;
      setState(() => _settings.brightness = null);
      BrightnessController.instance.apply(null);
      _onSettingsChanged();
    }
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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
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
                          _bookmarkCtrl.isCurrentPageBookmarked
                              ? Icons.bookmark
                              : Icons.bookmark_border,
                          color: _bookmarkCtrl.isCurrentPageBookmarked
                              ? theme.accent
                              : theme.text,
                        ),
                        onPressed: _bookmarkCtrl.toggleBookmark,
                      ),
                    if (_isComic)
                      IconButton(
                        icon: Icon(
                          _comicCtrl.comicPreviewVisible
                              ? Icons.view_carousel
                              : Icons.view_carousel_outlined,
                          color: _comicCtrl.comicPreviewVisible
                              ? theme.accent
                              : theme.text,
                        ),
                        onPressed: () {
                          setState(
                            () => _comicCtrl.comicPreviewVisible =
                                !_comicCtrl.comicPreviewVisible,
                          );
                          if (_comicCtrl.comicPreviewVisible) {
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (mounted) {
                                _scrollToPreviewPage(_comicCtrl.comicPage);
                              }
                            });
                          }
                        },
                      ),
                    if (_supportsZoom) ...[
                      if (_zoomMode)
                        IconButton(
                          icon: Icon(Icons.zoom_out, color: theme.text),
                          tooltip: 'Zoom out',
                          onPressed: _zoomLevel > _zoomMin ? _zoomOut : null,
                        ),
                      IconButton(
                        icon: Icon(
                          _zoomMode ? Icons.zoom_in : Icons.search,
                          color: _zoomMode ? theme.accent : theme.text,
                        ),
                        tooltip: _zoomMode ? 'Zoom in' : 'Enter zoom',
                        onPressed: _zoomMode ? _zoomIn : _toggleZoomMode,
                      ),
                    ],
                    IconButton(
                      icon: Icon(Icons.tune, color: theme.text),
                      tooltip: 'Display settings',
                      onPressed: () => SettingsSheet.show(
                        context,
                        settings: _settings,
                        onChanged: _onSettingsChanged,
                        format: _book.format,
                        onPdfFitWidth: _isPdf
                            ? () => _pdfCtrl.pdfController.goToPage(
                                pageNumber: _pdfCtrl.pdfPage,
                                anchor: PdfPageAnchor.left,
                              )
                            : null,
                        onPdfFitPage: _isPdf
                            ? () => _pdfCtrl.pdfController.goToPage(
                                pageNumber: _pdfCtrl.pdfPage,
                                anchor: PdfPageAnchor.center,
                              )
                            : null,
                      ),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: Row(
                    children: [
                      GestureDetector(
                        onTap: _toggleBrightnessMode,
                        child: Icon(
                          _settings.brightness == null
                              ? Icons.brightness_auto
                              : Icons.brightness_low,
                          color: theme.muted,
                          size: 20,
                        ),
                      ),
                      Expanded(
                        child: SliderTheme(
                          data: SliderThemeData(
                            activeTrackColor: theme.accent,
                            thumbColor: theme.accent,
                            inactiveTrackColor: theme.muted.withValues(alpha: 0.3),
                          ),
                          child: Slider(
                            value: (_settings.brightness ?? 1.0).clamp(
                              kMinBrightness,
                              1.0,
                            ),
                            min: kMinBrightness,
                            max: 1.0,
                            divisions: 19,
                            onChanged: _settings.brightness == null
                                ? null
                                : (v) => setState(() {
                                    _settings.brightness = v;
                                    BrightnessController.instance.apply(v);
                                  }),
                            onChangeEnd: (_) => _onSettingsChanged(),
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 44,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _toggleBrightnessMode,
                          child: Text(
                            _settings.brightness == null
                                ? 'Auto'
                                : '${((_settings.brightness ?? 1.0) * 100).round()}%',
                            style: TextStyle(
                              fontSize: 12,
                              color: theme.muted,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    ],
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
                if (_isComic && _comicCtrl.comicPreviewVisible) ...[
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
    final count = _comicCtrl.comicPageCount;
    if (count == 0) return const SizedBox.shrink();
    return SizedBox(
      height: 80,
      child: ListView.builder(
        controller: _comicCtrl.comicPreviewScrollController,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        itemCount: count,
        itemBuilder: (context, i) {
          final isCurrent = i == _comicCtrl.comicPage;
          return GestureDetector(
            onTap: () {
              // jumpToPage branches vertical mode (no PageView clients)
              // through the vertical scroll controller internally.
              _comicCtrl.jumpToPage(
                i,
                verticalViewportHeight: MediaQuery.sizeOf(context).height,
              );
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
                      child: _comicCtrl.isLazy
                          ? _LazyComicPageWidget(
                              provider: _comicCtrl.comicPageProvider!,
                              pageIndex: i,
                              fit: BoxFit.cover,
                              cacheWidth: 104,
                            )
                          : (i < _comicCtrl.comicPages.length
                                ? ComicImage(
                                    bytes: _comicCtrl.comicPages[i],
                                    fit: BoxFit.cover,
                                    cacheWidth: 104,
                                  )
                                : Container(
                                    color: theme.muted.withValues(alpha: 0.2),
                                  )),
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

/// Displays a single comic page from a [ComicPageSource], loading the
/// image bytes on demand and showing a sized placeholder while loading.
class _LazyComicPageWidget extends StatefulWidget {
  const _LazyComicPageWidget({
    required this.provider,
    required this.pageIndex,
    required this.fit,
    this.bounds,
    this.cacheWidth,
  });

  final ComicPageSource provider;
  final int pageIndex;
  final BoxFit fit;

  /// Decode bounds shared with the decode-ahead pass; when set, the rendered
  /// provider matches the warmed cache key exactly.
  final (int, int)? bounds;
  final int? cacheWidth;

  @override
  State<_LazyComicPageWidget> createState() => _LazyComicPageWidgetState();
}

class _LazyComicPageWidgetState extends State<_LazyComicPageWidget> {
  Uint8List? _bytes;
  bool _loading = false;
  Object? _error;

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
      _error = null;
      if (_bytes == null && !_loading) _load();
    }
  }

  Future<void> _load() async {
    if (_loading) return;
    _loading = true;
    try {
      final bytes = await widget.provider.loadPage(widget.pageIndex);
      if (!mounted) return;
      setState(() {
        _bytes = bytes;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      debugPrint('Failed to load comic page ${widget.pageIndex}: $e');
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_bytes != null) {
      // With decode bounds the provider matches the decode-ahead warmup key
      // exactly, so the pre-decoded frame paints with zero stall.
      final bounds = widget.bounds;
      return ComicImage(
        bytes: _bytes!,
        fit: widget.fit,
        provider: bounds == null
            ? null
            : comicPageImageProvider(_bytes!, bounds),
        cacheWidth: widget.cacheWidth,
      );
    }
    if (_error != null) {
      return const _ComicPageError();
    }
    final meta = widget.provider.pages[widget.pageIndex];
    final screenW = MediaQuery.sizeOf(context).width;
    final aspect = meta.intrinsicHeight > 0
        ? meta.intrinsicWidth / meta.intrinsicHeight
        : 0.67;
    final h = screenW / aspect;
    return Container(width: screenW, height: h, color: const Color(0xFF1A1A2E));
  }
}

/// Graceful fallback for a comic page whose bytes could not be loaded,
/// matching the key and copy used by [ComicImage]'s decode-error tile.
class _ComicPageError extends StatelessWidget {
  const _ComicPageError();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('comic-image-error'),
      alignment: Alignment.center,
      color: scheme.surfaceContainerHighest,
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.broken_image_outlined, color: scheme.onSurfaceVariant),
          const SizedBox(height: 8),
          Text(
            'Page could not be displayed',
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
          ),
        ],
      ),
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
    this.links = const [],
    this.onTapLink,
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
  final List<ChapterLink> links;
  final void Function(int target)? onTapLink;
  final List<SearchResult>? highlightMatches;
  final SearchResult? currentMatch;
  final double pageMaxHeight;
  final void Function(
    String word,
    Offset globalPosition,
    int bodyStart,
    int bodyEnd,
  )?
  onLongPressWord;
  final ({int start, int end})? selectedWordRange;
  final TextAlign textAlign;
  final double horizontalMargin;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (details) {
        // A tap on link text jumps to the link's target chapter instead of
        // flipping: the check runs before the tap zones so a link living in
        // the 30% prev/next bands is still tappable. Hit-testing maps the tap
        // onto the body's own rendered text (the same mechanism the
        // long-press word lookup uses), so it follows the real layout rather
        // than a reconstructed TextPainter.
        if (onTapLink != null && links.isNotEmpty) {
          final bodyOffset = _bodyTextOffsetAt(
            context,
            details.globalPosition,
          );
          if (bodyOffset != null) {
            for (final link in links) {
              if (bodyOffset >= link.start && bodyOffset < link.end) {
                onTapLink!(link.target);
                return;
              }
            }
          }
        }
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
      // Reading text is independent of the app-wide "Text size" scale: the
      // paginator measures at no scaling, so the page content must render at
      // no scaling too (the body RichText already ignores MediaQuery).
      child: MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.noScaling),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: horizontalMargin,
            vertical: 28,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (page.start == 0 && chapterTitle.trim().isNotEmpty) ...[
                Text(
                  chapterTitle,
                  style: style.copyWith(
                    fontSize: (style.fontSize ?? 18) + 4,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 16),
              ],
              Expanded(
                child: Builder(
                  builder: (context) => RichText(
                    textAlign: textAlign,
                    text: TextSpan(
                      style: style,
                      children: _buildPageText(
                        context,
                        MediaQuery.sizeOf(context).width - horizontalMargin * 2,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Maps a global tap point to a body offset, or `null` when the tap misses
  /// the rendered text (or hits the chapter title).
  int? _bodyTextOffsetAt(BuildContext context, Offset global) {
    RenderObject? root = context.findRenderObject();
    RenderParagraph? hit;
    void visit(RenderObject obj) {
      if (hit != null) return;
      if (obj is RenderParagraph) {
        final local = obj.globalToLocal(global);
        if (obj.size.contains(local)) {
          hit = obj;
          return;
        }
      }
      obj.visitChildren(visit);
    }

    root?.visitChildren(visit);
    if (hit == null) return null;
    return page.start + hit!.getPositionForOffset(hit!.globalToLocal(global)).offset;
  }

  void _handleLongPress(BuildContext context, LongPressStartDetails details) {    if (onLongPressWord == null) return;

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
    return ch.runes.any((r) => r > 127) ||
        RegExp(r'[a-zA-Z\u00C0-\u024F]').hasMatch(ch);
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
      links: links,
      renderWidth: renderWidth,
      maxHeight: pageMaxHeight,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
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
  const _ErrorView({
    required this.message,
    required this.book,
    required this.library,
    this.onRelinked,
  });

  final String message;
  final Book book;
  final LibraryService library;
  final Future<void> Function()? onRelinked;

  Future<void> _locate(BuildContext context) async {
    // file_picker v12 returns List<PlatformFile> (empty on cancel), same
    // pattern as library_screen _locateBook.
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['epub', 'txt', 'pdf', 'cbz', 'cbr'],
    );
    if (files.isEmpty) return;
    final path = files.map((f) => f.path).whereType<String>().firstOrNull;
    if (path == null) return;
    final relinked = await library.relinkToPath(book.id, path);
    if (!context.mounted) return;
    if (relinked != null) {
      await onRelinked?.call();
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('File re-linked')));
      }
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not link that file')));
    }
  }

  Future<void> _remove(BuildContext context) async {
    await library.deleteBookWithFile(book.id);
    if (context.mounted) Navigator.of(context).pop();
  }

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
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => _locate(context),
            child: const Text('Locate file'),
          ),
          TextButton(
            onPressed: () => _remove(context),
            child: const Text('Remove'),
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
  late final AnimationController _controller =
      AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 750),
        )
        ..addStatusListener(_onStatus)
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
