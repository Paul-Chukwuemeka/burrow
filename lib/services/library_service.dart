import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../db/database.dart' as db;
import '../models/book.dart';
import '../models/book_stats.dart';
import 'package:drift/drift.dart' show Value;
import '../models/reader_settings.dart';
import '../services/pdf_cover.dart';
import '../models/document.dart';
import '../utils/book_title.dart';
import '../utils/comic_series.dart';
import '../utils/cover_prep.dart';
import 'epub/epub_cache.dart';
import 'epub/epub_engine_factory.dart';
import 'missing_matcher.dart';

/// Status event for metadata extraction.
class MetadataStatus {
  const MetadataStatus({
    required this.type,
    this.total = 0,
    this.completed = 0,
    this.bookTitle,
  });

  final MetadataStatusType type;
  final int total;
  final int completed;
  final String? bookTitle;
}

enum MetadataStatusType { started, progress, completed }

/// Holds the user's library and reader settings.
///
/// The book catalog is persisted to a drift/SQLite database; reader settings
/// stay in SharedPreferences (tiny, synchronously readable at startup).
/// Cover images are written to the app documents directory; their path is
/// stored in the database.
class LibraryService extends ChangeNotifier {
  static const _settingsKey = 'burrow.settings.v1';
  static const _layoutKey = 'burrow.library.layout.v1';
  static const _legacyLibraryKey = 'burrow.library.v1';
  static const _onboardingKey = 'burrow.onboarding.complete.v1';
  static const _filtersKey = 'burrow.library.filters.v1';
  static const _groupSortsKey = 'burrow.library.groupSorts.v1';
  static const _comicsOrganizedKey = 'burrow.comics.organized.v1';
  static const _seriesCleanupKey = 'burrow.comics.seriesCleanup.v1';

  /// Retired content-engine flag (retire-dart-engine Task 7): older builds
  /// persisted `dart`/`rust` here. The flag is retired — [epubEngine] always
  /// returns Rust — so a stale value is deleted at [load] instead of
  /// lingering in SharedPreferences.
  static const _legacyEpubEngineKey = 'burrow.epub.engine.v1';

  db.AppDatabase? _db;
  final List<Book> _books = [];
  List<Book>? _sortedCache;
  final Set<String> _missingIds = {};
  bool _storageUnavailable = false;

  /// Content engine id (retire-dart-engine Task 7).
  ///
  /// The Dart engine is retired: this is always the Rust engine. A stale
  /// `dart` value persisted by an older build is normalized to Rust at
  /// [load], and [createEpubEngine] rejects `dart` outright, so the reader
  /// and metadata worker can never resolve a removed engine.
  String get epubEngine => rustEpubEngineId;

  Set<String> get missingIds => Set.unmodifiable(_missingIds);
  bool get storageUnavailable => _storageUnavailable;
  bool isMissing(String id) => _missingIds.contains(id);
  final Set<String> _pendingImports = {};
  final List<db.Collection> _collections = [];
  ReaderSettings settings = ReaderSettings();
  String libraryLayout = 'grid';

  void _invalidateSortCache() => _sortedCache = null;

  // Background metadata extraction queue. [_metadataQueuedIds] mirrors the
  // queue so enqueue sites can dedupe: without it, a bulk import followed by
  // resumeMetadataExtraction queues the same id twice and two passes mutate
  // the same Book (double cover writes).
  final Queue<String> _metadataQueue = Queue<String>();
  final Set<String> _metadataQueuedIds = {};
  bool _metadataWorkerRunning = false;
  bool _disposed = false;

  // PDF cover renders are serialized separately so a batch of PDFs does not
  // spawn dozens of concurrent renders.
  final Queue<String> _pdfCoverQueue = Queue<String>();
  bool _pdfCoverWorkerRunning = false;

  /// Stream controller for metadata extraction status events.
  final _metadataStatusController =
      StreamController<MetadataStatus>.broadcast();

  /// Stream of metadata extraction status events.
  Stream<MetadataStatus> get metadataStatus => _metadataStatusController.stream;

  /// Whether the first-run onboarding flow has been completed.
  bool onboardingComplete = false;

  // ---- Background scan state (survives onboarding disposal) ---------------

  /// The currently running scan future, if any. Stored here so the scan
  /// continues after the onboarding controller is disposed.
  Future<void>? _activeScan;

  /// Whether a scan is currently in progress.
  bool get isScanning => _activeScan != null;

  /// Progress: number of files imported so far.
  int scanImported = 0;

  /// Progress: total number of files found by the scan.
  int scanTotal = 0;

  /// Starts a background scan that imports books into the library.
  /// The scan runs independently of any screen; books appear as they are
  /// found because [importFile] calls [notifyListeners].
  void startBackgroundScan(
    Future<List<String>> scanFuture, {
    Set<String> extensions = const {},
  }) {
    if (_activeScan != null) return; // already scanning
    scanImported = 0;
    scanTotal = 0;
    _activeScan = _runBackgroundScan(scanFuture, extensions);
    notifyListeners();
  }

  Future<void> _runBackgroundScan(
    Future<List<String>> scanFuture,
    Set<String> extensions,
  ) async {
    try {
      final knownPaths = books.map((b) => b.path).toSet();
      final paths = await scanFuture;
      scanTotal = paths.length;
      notifyListeners();

      var completed = 0;
      for (final path in paths) {
        if (knownPaths.contains(path)) {
          completed++;
          continue;
        }
        try {
          await importFile(path);
        } catch (e) {
          debugPrint('Failed to import $path: $e');
        }
        completed++;
        scanImported = completed;
        // notifyListeners is called by importFile for each added book.
      }
    } catch (e) {
      debugPrint('Background scan failed: $e');
    }
    _activeScan = null;
    scanImported = 0;
    scanTotal = 0;
    notifyListeners();
  }

  /// Test-only override so tests can supply an in-memory database before
  /// [load] runs instead of opening the real one.
  @visibleForTesting
  void debugAttachDatabase(db.AppDatabase database) => _db = database;

  /// Releases database resources. Call when the app is shutting down.
  @override
  void dispose() {
    _disposed = true;
    _metadataStatusController.close();
    _db?.close();
    _db = null;
    super.dispose();
  }

  /// Clears reset-scoped storage: the legacy SharedPreferences library
  /// snapshot and the covers directory.
  ///
  /// Called by the startup Reset action before the database file is deleted.
  /// Without this, [load] re-imports the legacy snapshot whenever the DB is
  /// empty, so a Reset immediately resurrects the old library. Stale covers
  /// are removed too (the DB rows referencing them are gone).
  static Future<void> clearResetState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_legacyLibraryKey);
    } catch (_) {}
    try {
      final docs = await getApplicationDocumentsDirectory();
      final covers = Directory('${docs.path}/burrow_covers');
      if (await covers.exists()) await covers.delete(recursive: true);
    } catch (_) {}
  }

  Directory? _coversDir;

  List<Book> get books => List.unmodifiable(_books);

  List<db.Collection> get collections => List.unmodifiable(_collections);

  /// Test-only: injects books without touching the database.
  @visibleForTesting
  void debugAddAll(Iterable<Book> books) {
    _books.addAll(books);
    _invalidateSortCache();
  }

  /// Books sorted for display: recently read first, then newest imports.
  List<Book> get sorted {
    if (_sortedCache != null) return _sortedCache!;
    final list = [..._books];
    list.sort((a, b) {
      if ((a.lastReadAt > 0) != (b.lastReadAt > 0)) {
        return a.lastReadAt > 0 ? -1 : 1;
      }
      return b.lastReadAt.compareTo(a.lastReadAt) != 0
          ? b.lastReadAt.compareTo(a.lastReadAt)
          : b.addedAt.compareTo(a.addedAt);
    });
    _sortedCache = list;
    return list;
  }

  Book? get mostRecent {
    for (final b in sorted) {
      if (b.isStarted && !b.isFinished) return b;
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Persistence
  // ---------------------------------------------------------------------------

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();

    _db ??= db.AppDatabase();

    // One-time migration: import legacy SharedPreferences JSON if the
    // database is empty.
    final existing = await _db!.getAllBooks();
    if (existing.isEmpty) {
      final raw = prefs.getString(_legacyLibraryKey);
      if (raw != null) {
        try {
          final list = jsonDecode(raw) as List<dynamic>;
          for (final item in list) {
            final book = Book.fromJson(item as Map<String, dynamic>);
            await _db!.insertBook(db.bookToCompanion(book));
          }
          // Legacy key kept intentionally as a backup snapshot.
        } catch (e) {
          debugPrint('Legacy library migration failed: $e');
        }
      }
    }

    // Load catalog from the database.
    _books
      ..clear()
      ..addAll(await _db!.getAllBooks());
    _invalidateSortCache();

    // Load collections.
    _collections
      ..clear()
      ..addAll(await _db!.getAllCollections());

    // Settings stay in SharedPreferences.
    final settingsRaw = prefs.getString(_settingsKey);
    if (settingsRaw != null) {
      try {
        settings = ReaderSettings.fromJson(
          jsonDecode(settingsRaw) as Map<String, dynamic>,
        );
      } catch (e) {
        debugPrint('Failed to load settings: $e');
      }
    }

    // Library layout preference.
    libraryLayout = prefs.getString(_layoutKey) ?? 'grid';

    // The engine flag is retired: the Rust engine is the only engine. A stale
    // value persisted by an older build is deleted (there is nothing to read
    // back — the getter always returns Rust).
    if (prefs.containsKey(_legacyEpubEngineKey)) {
      await prefs.remove(_legacyEpubEngineKey);
    }

    // First-run onboarding state.
    onboardingComplete = prefs.getBool(_onboardingKey) ?? false;

    // Clean up orphaned cover files (e.g. from interrupted imports).
    await _cleanupOrphanedCovers();

    notifyListeners();

    unawaited(reconcileMissingFiles());

    // Sweep stale/orphaned parsed-document cache entries (and earlier cache
    // schema versions) in the background. The sweep covers every engine
    // namespace at once — the Rust namespace plus orphaned entries from the
    // retired Dart engine — so it stays on the engine-agnostic [EpubCache]
    // util rather than the per-engine [EpubEngine] seam.
    unawaited(
      EpubCache.prune(
        [for (final b in _books) b.path],
        engineIds: const [rustEpubEngineId, legacyDartEngineId],
      ),
    );

    // One-time migration: group existing comics into the "Comics"
    // collection now that series names can be inferred from filenames.
    // Series themselves are visual groups inside the Comics screen
    // (CollectionScreen._groupedBooks) — no per-series collections.
    if (!(prefs.getBool(_comicsOrganizedKey) ?? false)) {
      unawaited(
        _autoOrganizeComics().then(
          (_) => prefs.setBool(_comicsOrganizedKey, true),
        ),
      );
    }

    // One-time cleanup: remove auto-created per-series top-level collections
    // from earlier versions, keeping only "Comics". Manual collections
    // (mixed content or extra books) are left alone.
    if (!(prefs.getBool(_seriesCleanupKey) ?? false)) {
      unawaited(
        _cleanupAutoSeriesCollections().then(
          (_) => prefs.setBool(_seriesCleanupKey, true),
        ),
      );
    }
  }

  Future<void> reconcileMissingFiles() async {
    _missingIds.clear();
    _storageUnavailable = false;
    if (_books.isEmpty) {
      notifyListeners();
      return;
    }
    var missing = 0;
    var rootMissing = 0;
    var checkedRoots = <String>{};
    for (var i = 0; i < _books.length; i++) {
      final b = _books[i];
      bool exists = false;
      try {
        // Sync: async exists() never completes inside a testWidgets
        // FakeAsync zone and would hang widget tests / onboarding scans.
        exists = File(b.path).existsSync();
      } catch (_) {
        exists = false;
      }
      if (!exists) {
        missing++;
        // Parent check: if the parent dir itself is gone, count as root-missing.
        try {
          final parent = File(b.path).parent.path;
          if (checkedRoots.add(parent)) {
            if (!Directory(parent).existsSync()) rootMissing++;
          }
        } catch (_) {}
        _missingIds.add(b.id);
      } else {
        // Path-exists wins: refresh fingerprint lazily.
        try {
          final st = FileStat.statSync(b.path);
          final size = st.size;
          final mtime = st.modified.millisecondsSinceEpoch;
          if (b.fileSize != size || b.mtimeMs != mtime) {
            b.fileSize = size;
            b.mtimeMs = mtime;
            if (_db != null) {
              await _db!.updateBook(db.bookToCompanionForUpdate(b));
            }
          }
        } catch (_) {}
      }
      if (i % 50 == 49) await Future<void>.delayed(Duration.zero);
    }
    // Mass-vanish guard: storage (SD card / USB) ejection removes whole
    // directories, so a mass disappearance counts as storage failure only
    // when at least one parent dir is itself gone AND the missing share is
    // large (ratio > 0.5) or absolute (more than 2 files).
    if (_books.isNotEmpty &&
        rootMissing > 0 &&
        (missing / _books.length > 0.5 || missing > 2)) {
      _storageUnavailable = true;
      _missingIds.clear();
    }
    notifyListeners();
  }

  Future<void> saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_settingsKey, jsonEncode(settings.toJson()));
    notifyListeners();
  }

  /// Persists the onboarding-complete flag so the flow never reappears.
  Future<void> markOnboardingComplete() async {
    onboardingComplete = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_onboardingKey, true);
    notifyListeners();
  }

  Future<void> saveLibraryLayout(String layout) async {
    libraryLayout = layout;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_layoutKey, layout);
    notifyListeners();
  }

  Future<void> saveFilters({
    required String sort,
    required String status,
    required String? genre,
    required String? series,
    required List<String> formats,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _filtersKey,
      jsonEncode({
        'sort': sort,
        'status': status,
        'genre': genre,
        'series': series,
        'formats': formats,
      }),
    );
  }

  Future<Map<String, dynamic>?> loadFilters() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_filtersKey);
    if (raw == null) return null;
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  /// Sort choices of the grouping screens (author/series/genre/smartGroup),
  /// keyed by screen scope. Each remembers its own default independently.
  Future<Map<String, String>> loadGroupSorts() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_groupSortsKey);
    if (raw == null) return const {};
    final data = jsonDecode(raw) as Map<String, dynamic>;
    return {
      for (final e in data.entries)
        if (e.value is String) e.key: e.value as String,
    };
  }

  Future<void> saveGroupSort(String scope, String sort) async {
    final sorts = Map.of(await loadGroupSorts());
    sorts[scope] = sort;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_groupSortsKey, jsonEncode(sorts));
  }

  bool containsPath(String path) => _books.any((b) => b.path == path);

  Book? bookById(String id) => _books.where((b) => b.id == id).firstOrNull;

  @visibleForTesting
  void debugMarkMissing(String id) {
    _missingIds.add(id);
    notifyListeners();
  }

  @visibleForTesting
  bool debugHasPendingImport(String path) => _pendingImports.contains(path);

  /// Registers a collection in-memory without a database (unit tests).
  @visibleForTesting
  void debugAddCollection(db.Collection collection) {
    _collections.add(collection);
    notifyListeners();
  }

  /// Imports a document: creates a book with minimal metadata (from filename)
  /// and queues metadata extraction for background processing.
  /// Returns the new book, or null if it was already in the library.
  Future<Book?> importFile(String path) async {
    return importFileFast(path);
  }

  /// Fast import: creates a book with minimal metadata (from filename only).
  /// Returns the new book, or null if it was already in the library.
  /// The book is added to the library immediately, and metadata extraction
  /// is queued for background processing.
  Future<Book?> importFileFast(String path) async {
    // Guard: reject duplicates by path or pending import status.
    if (_pendingImports.contains(path)) return null;
    _pendingImports.add(path);

    try {
      if (containsPath(path)) return null;

      final format = formatFromExtension(path);
      // Single sync probe: FileStat.statSync throws (caught below) for a
      // missing path, and async stat never completes inside a testWidgets
      // FakeAsync zone. Reuse the result for the relink probe + backfill.
      FileStat? probe;
      try {
        final st = FileStat.statSync(path);
        // statSync returns (rather than throws) notFound/directory on some
        // platforms — treat those as missing so the fingerprint stays null.
        if (st.type != FileSystemEntityType.notFound &&
            st.type != FileSystemEntityType.directory) {
          probe = st;
        }
      } catch (_) {
        probe = null;
      }
      if (probe != null) {
        // Auto re-link: unknown path may be a moved file.
        final candidates = _books
            .where((b) => _missingIds.contains(b.id))
            .toList();
        final hitId = findRelinkCandidate(
          size: probe.size,
          mtimeMs: probe.modified.millisecondsSinceEpoch,
          format: formatFromExtension(path),
          missing: candidates,
        );
        if (hitId != null) {
          // Awaited inside try/finally so _pendingImports still covers the
          // relink: a bare `return relinkToPath(...)` would run finally
          // (clearing pending) before the relink completes.
          final relinked = await relinkToPath(hitId, path);
          return relinked;
        }
      }

      final title = _titleFromFilename(path);

      final int? sz = probe?.size;
      final int? mt = probe?.modified.millisecondsSinceEpoch;

      final book = Book(
        id: _newId(),
        title: title,
        author: '', // Will be filled in Phase 2
        path: path,
        format: format,
        addedAt: DateTime.now().millisecondsSinceEpoch,
        metadataComplete: false,
        fileSize: sz,
        mtimeMs: mt,
      );

      _books.add(book);
      try {
        if (_db != null) await _db!.insertBook(db.bookToCompanion(book));
      } catch (e) {
        _books.removeWhere((b) => b.id == book.id);
        _invalidateSortCache();
        rethrow;
      }
      _invalidateSortCache();
      notifyListeners();

      // Queue metadata extraction for background processing.
      _enqueueMetadata(book.id);
      _startMetadataWorker();

      return book;
    } finally {
      _pendingImports.remove(path);
    }
  }

  /// Bulk import: creates minimal (filename-only) books for every new [paths]
  /// entry, inserting them in a single transaction and notifying once. This
  /// avoids one DB write and one UI rebuild per file during large imports.
  ///
  /// Returns the newly added books and the errors for paths that failed.
  Future<(List<Book> added, List<Object> errors)> importFilesFast(
    Iterable<String> paths, {
    void Function(int completed, int total)? onProgress,
  }) async {
    final added = <Book>[];
    final errors = <Object>[];
    final batch = <Book>[];
    final pendingPaths = <String>{};
    final seen = <String>{};

    final pathList = paths.toList();
    final total = pathList.length;
    onProgress?.call(0, total);

    try {
      for (var i = 0; i < total; i++) {
        final path = pathList[i];
        onProgress?.call(i, total);
        if (!seen.add(path)) continue;
        if (_pendingImports.contains(path) || containsPath(path)) continue;
        _pendingImports.add(path);
        pendingPaths.add(path);
        try {
          // Auto re-link: unknown path may be a moved file. Single sync
          // probe: async stat never completes inside a testWidgets
          // FakeAsync zone; statSync throws (caught below) for missing.
          String? hitId;
          int? sz;
          int? mt;
          try {
            final st = FileStat.statSync(path);
            if (st.type != FileSystemEntityType.notFound &&
                st.type != FileSystemEntityType.directory) {
              sz = st.size;
              mt = st.modified.millisecondsSinceEpoch;
              final candidates = _books
                  .where((b) => _missingIds.contains(b.id))
                  .toList();
              // Note: batch books are never missing, so only check existing.
              hitId = findRelinkCandidate(
                size: st.size,
                mtimeMs: st.modified.millisecondsSinceEpoch,
                format: formatFromExtension(path),
                missing: candidates,
              );
            }
          } catch (_) {}
          // Defer relink until after loop to avoid mutating _books mid-scan?
          // Safe to relink immediately: _books is only appended below.
          if (hitId != null) {
            await relinkToPath(hitId, path);
            continue;
          }
          batch.add(
            Book(
              id: _newId(),
              title: _titleFromFilename(path),
              author: '',
              path: path,
              format: formatFromExtension(path),
              addedAt: DateTime.now().millisecondsSinceEpoch,
              metadataComplete: false,
              fileSize: sz,
              mtimeMs: mt,
            ),
          );
        } catch (e) {
          errors.add(e);
        }
      }

      if (batch.isEmpty) return (added, errors);

      final database = _db;
      if (database != null) {
        // Insert in small chunks and yield between them. The production
        // database runs on the UI isolate, so one huge transaction would
        // freeze the interface; chunking keeps the event loop responsive.
        // Each chunk joins the in-memory library only after its transaction
        // commits, so a failed chunk never leaves ghosts that block re-import
        // via containsPath.
        const chunkSize = 100;
        for (var i = 0; i < batch.length; i += chunkSize) {
          final end = (i + chunkSize < batch.length)
              ? i + chunkSize
              : batch.length;
          final chunk = batch.sublist(i, end);
          try {
            await database.transaction(() async {
              for (final book in chunk) {
                await database.insertBook(db.bookToCompanion(book));
              }
            });
          } catch (e) {
            errors.add(e);
            return (added, errors);
          }
          _books.addAll(chunk);
          _invalidateSortCache();
          added.addAll(chunk);
          notifyListeners();
          await Future<void>.delayed(Duration.zero);
        }
      } else {
        _books.addAll(batch);
        _invalidateSortCache();
        added.addAll(batch);
      }

      for (final book in added) {
        _enqueueMetadata(book.id);
      }
      notifyListeners();
      _startMetadataWorker();
      onProgress?.call(total, total);
      return (added, errors);
    } finally {
      for (final path in pendingPaths) {
        _pendingImports.remove(path);
      }
    }
  }

  /// Number of metadata extractions to run concurrently. Each runs in its own
  /// isolate via the active content engine's [EpubEngine.extractMetadata].
  /// Capped low so background extraction never starves the UI or spikes
  /// memory during bulk imports.
  static int get _metadataConcurrency {
    final cores = Platform.numberOfProcessors;
    return cores <= 2 ? 1 : 2;
  }

  /// Enqueues [bookId] for metadata extraction unless already queued.
  void _enqueueMetadata(String bookId) {
    if (_metadataQueuedIds.add(bookId)) {
      _metadataQueue.add(bookId);
    }
  }

  /// Starts the background metadata extraction worker if not already running.
  void _startMetadataWorker() {
    if (_metadataWorkerRunning || _metadataQueue.isEmpty) return;
    _metadataWorkerRunning = true;
    _processMetadataQueue();
  }

  /// Queues every book whose metadata is still incomplete and starts the
  /// worker. Called once after [load] so an interrupted batch import resumes
  /// instead of leaving books with placeholder metadata forever.
  void resumeMetadataExtraction() {
    if (_disposed) return;
    for (final book in _books) {
      if (!book.metadataComplete) {
        _enqueueMetadata(book.id);
      }
    }
    _startMetadataWorker();
  }

  /// Drains the metadata queue in passes. Books queued while a pass is running
  /// (e.g. by an ongoing scan) are picked up by the next pass.
  Future<void> _processMetadataQueue() async {
    while (!_disposed) {
      final work = _metadataQueue.toList();
      _metadataQueue.clear();
      _metadataQueuedIds.clear();
      if (work.isEmpty) break;
      await _runMetadataPass(work);
    }
    _metadataWorkerRunning = false;
    // A queued import may have arrived after the final empty check.
    if (_metadataQueue.isNotEmpty && !_disposed) _startMetadataWorker();
  }

  Future<void> _runMetadataPass(List<String> work) async {
    // Build an id index once so membership lookups stay O(1).
    final index = {for (final b in _books) b.id: b};
    final total = work.length;
    var completed = 0;
    var next = 0;

    try {
      _metadataStatusController.add(
        MetadataStatus(
          type: MetadataStatusType.started,
          total: total,
          completed: 0,
        ),
      );
    } catch (_) {}

    final pendingWrites = <Book>[];
    var lastNotify = DateTime.now();

    Future<void> worker() async {
      while (!_disposed) {
        final i = next++;
        if (i >= total) return;
        if (_missingIds.contains(work[i])) {
          completed++;
          continue;
        }
        final book = index[work[i]];
        if (book == null || book.metadataComplete) {
          completed++;
          continue;
        }

        _emitMetadataProgress(total, completed, book.title);

        try {
          await _extractMetadataInto(book);
          pendingWrites.add(book);
        } catch (e) {
          debugPrint('Metadata queue processing failed for ${book.title}: $e');
        }

        completed++;
        if (pendingWrites.length >= 25)
          await _flushMetadataWrites(pendingWrites);

        // Throttle UI rebuilds to a few per second during batch imports.
        final now = DateTime.now();
        if (now.difference(lastNotify).inMilliseconds >= 250 ||
            completed == total) {
          lastNotify = now;
          try {
            notifyListeners();
          } catch (_) {}
        }
      }
    }

    await Future.wait(List.generate(_metadataConcurrency, (_) => worker()));
    await _flushMetadataWrites(pendingWrites);

    await _autoOrganizeComics();

    try {
      _metadataStatusController.add(
        MetadataStatus(
          type: MetadataStatusType.completed,
          total: total,
          completed: total,
        ),
      );
    } catch (_) {}
  }

  void _emitMetadataProgress(int total, int completed, String title) {
    try {
      _metadataStatusController.add(
        MetadataStatus(
          type: MetadataStatusType.progress,
          total: total,
          completed: completed,
          bookTitle: title,
        ),
      );
    } catch (_) {}
  }

  /// Extracts metadata for [book] and applies it in place.
  ///
  /// A definitive [FormatException] marks the book complete (there is nothing
  /// more to read); transient errors leave it incomplete so
  /// [resumeMetadataExtraction] retries on the next launch.
  Future<void> _extractMetadataInto(Book book) async {
    final format = book.format;

    // TXT has no embedded metadata or cover — nothing to extract.
    if (format == BookFormat.txt) {
      book.metadataComplete = true;
      return;
    }

    ParsedMetadata doc;
    try {
      // Library metadata comes from the same engine (and the same OPF
      // implementation) as the reader.
      doc = await createEpubEngine(epubEngine).extractMetadata(book.path);
    } on FormatException {
      debugPrint('Metadata parse skip (format): ${book.title}');
      book.metadataComplete = true;
      return;
    }

    book.title = doc.title.isNotEmpty ? doc.title : book.title;
    book.author = doc.author;
    book.description = doc.description;
    book.annotation = doc.annotation;
    book.genre = doc.genre;
    book.seriesName = doc.seriesName;
    book.seriesIndex = doc.seriesIndex;
    book.publisher = doc.publisher;
    book.isbn = doc.isbn;
    book.language = doc.language;
    book.publicationDate = doc.publicationDate;
    book.rights = doc.rights;
    book.type = doc.type;
    book.source = doc.source;
    book.titleSort = doc.titleSort;
    book.authorSort = doc.authorSort;
    book.metadataComplete = true;

    final coverBytes = doc.coverBytes;
    if (coverBytes != null && coverBytes.isNotEmpty) {
      book.coverPath = await _saveCover(coverBytes);
    }

    // For PDFs without covers, generate thumbnail in the background.
    if (format == BookFormat.pdf && book.coverPath == null) {
      _enqueuePdfCover(book.id);
    }
  }

  /// Persists accumulated metadata updates in a single transaction.
  Future<void> _flushMetadataWrites(List<Book> books) async {
    if (books.isEmpty) return;
    final snapshot = List<Book>.of(books);
    books.clear();
    final database = _db;
    if (database == null) return;
    try {
      await database.transaction(() async {
        for (final book in snapshot) {
          await database.updateBook(db.bookToCompanionForUpdate(book));
        }
      });
    } catch (e) {
      debugPrint('Metadata batch write failed: $e');
    }
  }

  void _enqueuePdfCover(String bookId) {
    if (_pdfCoverQueue.contains(bookId)) return;
    _pdfCoverQueue.add(bookId);
    _startPdfCoverWorker();
  }

  void _startPdfCoverWorker() {
    if (_pdfCoverWorkerRunning || _pdfCoverQueue.isEmpty) return;
    _pdfCoverWorkerRunning = true;
    _processPdfCoverQueue();
  }

  Future<void> _processPdfCoverQueue() async {
    try {
      while (_pdfCoverQueue.isNotEmpty && !_disposed) {
        final bookId = _pdfCoverQueue.removeFirst();
        final book = _books.where((b) => b.id == bookId).firstOrNull;
        if (book == null || book.coverPath != null) continue;
        await _generatePdfCoverInBackground(book);
      }
    } finally {
      _pdfCoverWorkerRunning = false;
    }
  }

  /// Extracts title from filename, cleaning up common patterns.
  static String _titleFromFilename(String path) {
    final base = path.split(Platform.pathSeparator).last;
    final dot = base.lastIndexOf('.');
    final name = dot > 0 ? base.substring(0, dot) : base;
    // Clean up common patterns like "OceanofPDF.com_Title_Author"
    return cleanBookTitle(name);
  }

  /// Automatically organizes comics into collections after metadata extraction.
  ///
  /// Creates a "Comics" collection containing all CBZ/CBR books. Series
  /// (e.g. "Batman") are visual groups inside the Comics collection screen,
  /// not separate collections.
  Future<void> _autoOrganizeComics() async {
    if (_db == null) return;

    final comics = _books.where(
      (b) => b.format == BookFormat.cbz || b.format == BookFormat.cbr,
    );
    if (comics.isEmpty) return;

    // Ensure "Comics" collection exists and add all comics to it.
    var comicsCollection = _collections
        .where((c) => c.name == 'Comics')
        .firstOrNull;
    if (comicsCollection == null) {
      final id = await createCollection('Comics');
      if (id.isEmpty) return;
      comicsCollection = _collections.where((c) => c.id == id).firstOrNull;
    }
    if (comicsCollection == null) return;
    for (final book in comics) {
      if (!await _db!.isBookInCollection(comicsCollection.id, book.id)) {
        await _db!.addBookToCollection(comicsCollection.id, book.id);
      }
    }

    notifyListeners();
  }

  /// Removes auto-created per-series top-level collections from earlier
  /// versions (one collection per series name, containing only that series'
  /// comics). Manual collections — any non-comic, mixed series, extra books,
  /// or empty — are left alone.
  Future<void> _cleanupAutoSeriesCollections() async {
    if (_db == null) return;
    for (final collection in List.of(_collections)) {
      if (collection.name == 'Comics') continue;
      final books = await getBooksForCollection(collection.id);
      if (books.isEmpty) continue;
      if (books.any(
        (b) => b.format != BookFormat.cbz && b.format != BookFormat.cbr,
      )) {
        continue;
      }
      final seriesNames = {for (final b in books) b.effectiveSeriesName};
      if (seriesNames.length == 1 && seriesNames.single == collection.name) {
        await deleteCollection(collection.id);
      }
    }
  }

  /// Renders the first page of a PDF as its library thumbnail. The book is
  /// already in [_books] with a placeholder cover; once the render finishes
  /// the cover path is written to disk, persisted to the DB, and the UI is
  /// notified.
  Future<void> _generatePdfCoverInBackground(Book book) async {
    try {
      final bytes = await renderPdfCoverThumbnail(book.path);
      if (bytes == null || bytes.isEmpty) return;
      final coverPath = await _saveCover(bytes);
      if (coverPath == null) return;
      final current = _books.where((b) => b.id == book.id).firstOrNull;
      if (current == null) return;
      current.coverPath = coverPath;
      if (_db != null) {
        await _db!.updateBook(db.bookToCompanionForUpdate(current));
      }
      notifyListeners();
    } catch (e) {
      debugPrint('PDF cover generation failed: $e');
    }
  }

  /// Deletes a book and optionally its file from disk.
  ///
  /// The database transaction commits first; user files (cover, parsed-document
  /// cache, source book) are deleted only after the commit succeeds. A
  /// kill/crash in between leaves orphan DB rows (recoverable, swept on next
  /// load) instead of a DB row pointing at a deleted file (unrecoverable data
  /// loss). If the transaction throws, no file is touched and the book stays
  /// in the library.
  Future<void> deleteBookWithFile(String id, {bool deleteFile = false}) async {
    if (await _deleteBookInternal(id, deleteFile: deleteFile)) {
      notifyListeners();
    }
  }

  /// Deletes one book without notifying. Returns true if a book was removed.
  ///
  /// Unknown ids are a silent no-op (mirrors [deleteBookWithFile]'s early
  /// return). Throws only on DB failure, in which case no file is touched.
  Future<bool> _deleteBookInternal(String id, {bool deleteFile = false}) async {
    final book = _books.where((b) => b.id == id).firstOrNull;
    if (book == null) return false;
    if (_db != null) {
      await _db!.transaction(() async {
        await _db!.customStatement('DELETE FROM bookmarks WHERE book_id = ?', [
          id,
        ]);
        await _db!.customStatement(
          'DELETE FROM reading_sessions WHERE book_id = ?',
          [id],
        );
        await _db!.customStatement(
          'DELETE FROM collection_books WHERE book_id = ?',
          [id],
        );
        await _db!.deleteBookById(id);
      });
    }
    // DB commit succeeded — now it is safe to delete user files. The parsed-
    // document cache key needs path + mtime + size, so drop it before the
    // source file itself is removed. Sync-only: batch selection deletes run
    // under testWidgets' FakeAsync zone, where async disk IO never
    // completes (see [EpubEngine.clearCacheFor]). The seam call clears every
    // engine namespace at once — the Rust namespace plus orphaned entries
    // from the retired Dart engine — so deletion never leaks the other
    // namespace's entries (any stragglers are swept by [EpubCache.prune] at
    // startup).
    createEpubEngine(epubEngine).clearCacheFor(book.path);
    final cover = book.coverPath;
    if (cover != null) {
      try {
        await File(cover).delete();
      } catch (_) {}
    }
    if (deleteFile) {
      try {
        final file = File(book.path);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (e) {
        debugPrint('Failed to delete book file: $e');
      }
    }
    _books.remove(book);
    _missingIds.remove(id);
    _invalidateSortCache();
    return true;
  }

  Future<Book?> relinkToPath(String id, String newPath) async {
    final idx = _books.indexWhere((b) => b.id == id);
    if (idx < 0) return null;
    final old = _books[idx];
    // Occupied-path guard: another book already owns newPath — refuse so
    // two entries never point at the same file.
    final ownerIdx = _books.indexWhere((b) => b.path == newPath);
    if (ownerIdx >= 0 && _books[ownerIdx].id != id) return null;
    // Existence/type check: the relink target must be a real file. A
    // missing path (moved away again, stale Locate pick) returns null
    // instead of throwing; DB errors below still throw. Sync variants:
    // async disk calls never complete inside a testWidgets FakeAsync zone.
    FileStat st;
    try {
      final type = FileSystemEntity.typeSync(newPath);
      if (type == FileSystemEntityType.notFound ||
          type == FileSystemEntityType.directory) {
        return null;
      }
      st = FileStat.statSync(newPath);
      if (st.type == FileSystemEntityType.notFound ||
          st.type == FileSystemEntityType.directory) {
        return null;
      }
    } on FileSystemException {
      return null;
    }
    final updated = Book(
      id: old.id,
      title: old.title,
      author: old.author,
      path: newPath,
      // Entry follows the file: a cross-format relink (epub→pdf) updates
      // format so the reader picks the correct parser.
      format: formatFromExtension(newPath),
      coverPath: old.coverPath,
      addedAt: old.addedAt,
      lastReadAt: old.lastReadAt,
      progress: old.progress,
      lastChapter: old.lastChapter,
      lastOffset: old.lastOffset,
      description: old.description,
      annotation: old.annotation,
      genre: old.genre,
      seriesName: old.seriesName,
      seriesIndex: old.seriesIndex,
      publisher: old.publisher,
      isbn: old.isbn,
      language: old.language,
      review: old.review,
      publicationDate: old.publicationDate,
      rights: old.rights,
      type: old.type,
      source: old.source,
      titleSort: old.titleSort,
      authorSort: old.authorSort,
      metadataComplete: old.metadataComplete,
      fileSize: st.size,
      mtimeMs: st.modified.millisecondsSinceEpoch,
    );
    _books[idx] = updated;
    if (_db != null) {
      await _db!.updateBook(db.bookToCompanionForUpdate(updated));
    }
    // The old path's entries in every engine namespace are dropped (see the
    // delete path above).
    createEpubEngine(epubEngine).clearCacheFor(old.path);
    _missingIds.remove(id);
    _invalidateSortCache();
    notifyListeners();
    return updated;
  }

  Future<int> removeAllMissing() async {
    final ids = _missingIds.toList();
    for (final id in ids) {
      await deleteBookWithFile(id, deleteFile: false);
    }
    return ids.length;
  }

  /// Deletes every book in [ids], collecting per-item failures instead of
  /// throwing mid-batch. Unknown ids are a silent no-op mirroring
  /// [deleteBookWithFile]. Notifies exactly once at the end.
  Future<(int deleted, List<Object> errors)> deleteBooks(
    Iterable<String> ids, {
    bool deleteFile = false,
  }) async {
    var deleted = 0;
    final errors = <Object>[];
    for (final id in ids.toList()) {
      try {
        if (await _deleteBookInternal(id, deleteFile: deleteFile)) deleted++;
      } catch (e) {
        errors.add(e);
      }
    }
    notifyListeners();
    return (deleted, errors);
  }

  /// Adds every book in [ids] to [collectionId], collecting per-item failures
  /// instead of throwing mid-batch. Duplicate adds fail with a UNIQUE
  /// constraint from the store and land in [errors]. Notifies exactly once
  /// at the end.
  Future<(int added, List<Object> errors)> addBooksToCollection(
    String collectionId,
    Iterable<String> ids,
  ) async {
    var added = 0;
    final errors = <Object>[];
    for (final id in ids.toList()) {
      try {
        // Mirror single-op no-op when no database is attached.
        if (_db == null) continue;
        await _db!.addBookToCollection(collectionId, id);
        added++;
      } catch (e) {
        errors.add(e);
      }
    }
    notifyListeners();
    return (added, errors);
  }

  /// Updates book metadata. Pass null to leave unchanged.
  Future<void> updateBook(
    String id, {
    String? title,
    String? author,
    String? description,
    String? annotation,
    String? genre,
    String? seriesName,
    double? seriesIndex,
    String? publisher,
    String? isbn,
    String? language,
    String? review,
    String? publicationDate,
    String? rights,
    String? type,
    String? source,
    String? titleSort,
    String? authorSort,
  }) async {
    final book = _books.where((b) => b.id == id).firstOrNull;
    if (book == null) return;
    if (title != null) book.title = title;
    if (author != null) book.author = author;
    book.description = description ?? book.description;
    book.annotation = annotation ?? book.annotation;
    book.genre = genre ?? book.genre;
    book.seriesName = seriesName ?? book.seriesName;
    book.seriesIndex = seriesIndex ?? book.seriesIndex;
    book.publisher = publisher ?? book.publisher;
    book.isbn = isbn ?? book.isbn;
    book.language = language ?? book.language;
    book.review = review ?? book.review;
    book.publicationDate = publicationDate ?? book.publicationDate;
    book.rights = rights ?? book.rights;
    book.type = type ?? book.type;
    book.source = source ?? book.source;
    book.titleSort = titleSort ?? book.titleSort;
    book.authorSort = authorSort ?? book.authorSort;
    if (_db != null) {
      await _db!.updateBook(db.bookToCompanionForUpdate(book));
    }
    notifyListeners();
  }

  /// Saves reading position. [chapter] is chapter index (reflowable) or page
  /// index (PDF); [offset] is char offset within the chapter.
  Future<void> savePosition({
    required String id,
    required int chapter,
    required int offset,
    required double progress,
  }) async {
    final book = _books.where((b) => b.id == id).firstOrNull;
    if (book == null) return;
    book
      ..lastChapter = chapter
      ..lastOffset = offset
      ..progress = progress.clamp(0, 1)
      ..lastReadAt = DateTime.now().millisecondsSinceEpoch;
    // Reading stamps lastReadAt, which drives the Recent sort and the
    // Continue-reading card, so the cached `sorted` order must be dropped.
    _invalidateSortCache();
    if (_db != null) {
      await _db!.updateBook(
        db.positionToUpdate(
          id: id,
          lastChapter: book.lastChapter,
          lastOffset: book.lastOffset,
          progress: book.progress,
          lastReadAt: book.lastReadAt,
        ),
      );
    }
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Cover storage
  // ---------------------------------------------------------------------------

  /// Saves [bytes] as [book]'s cover if it has none yet, downscaling first.
  /// Used to backfill covers that metadata extraction intentionally defers
  /// (e.g. CBR, whose archive cannot be read entry-by-entry).
  ///
  /// The downscale runs off the UI isolate ([prepareCoverAsync]): comic pages
  /// are multi-megapixel, and re-encoding one inline froze the reader.
  Future<void> setCoverIfMissing(Book book, List<int> bytes) async {
    final target = _books.where((b) => b.id == book.id).firstOrNull ?? book;
    if (target.coverPath != null || bytes.isEmpty) return;
    final prepared = await prepareCoverAsync(bytes) ?? bytes;
    final path = await _saveCover(prepared);
    if (path == null) return;
    target.coverPath = path;
    if (_db != null) {
      await _db!.updateBook(db.bookToCompanionForUpdate(target));
    }
    notifyListeners();
  }

  Future<String?> _saveCover(List<int>? bytes) async {
    if (bytes == null || bytes.isEmpty) return null;
    try {
      final dir = await _ensureCoversDir();
      final file = File(
        '${dir.path}/cover_${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(1 << 32)}.img',
      );
      await file.writeAsBytes(bytes);
      return file.path;
    } catch (_) {
      return null;
    }
  }

  Future<Directory> _ensureCoversDir() async {
    if (_coversDir != null) return _coversDir!;
    final docs = await getApplicationDocumentsDirectory();
    _coversDir = Directory('${docs.path}/burrow_covers');
    _coversDir!.createSync(recursive: true);
    return _coversDir!;
  }

  /// Removes cover files in the covers directory that aren't referenced by
  /// any book. Runs once at startup; safe to call if the directory is missing.
  Future<void> _cleanupOrphanedCovers() async {
    try {
      final dir = await _ensureCoversDir();
      if (!dir.existsSync()) return;
      final referenced = <String>{
        for (final b in _books)
          if (b.coverPath != null) b.coverPath!,
      };
      for (final file in dir.listSync()) {
        if (file is File && !referenced.contains(file.path)) {
          try {
            file.deleteSync();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  String _newId() =>
      '${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(1 << 32)}';

  // ---------------------------------------------------------------------------
  // Bookmarks
  // ---------------------------------------------------------------------------

  Future<void> addBookmark({
    required String bookId,
    required int chapter,
    required int offset,
    required String snippet,
  }) async {
    if (_db == null) return;
    await _db!.insertBookmark(
      db.BookmarksCompanion.insert(
        id: _newId(),
        bookId: bookId,
        chapter: chapter,
        offset: offset,
        snippet: Value(snippet),
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    notifyListeners();
  }

  Future<List<db.Bookmark>> getBookmarks(String bookId) async {
    if (_db == null) return [];
    return _db!.getBookmarksForBook(bookId);
  }

  Future<void> deleteBookmark(String id) async {
    if (_db == null) return;
    await _db!.deleteBookmarkById(id);
    notifyListeners();
  }

  Future<bool> isBookmarked({
    required String bookId,
    required int chapter,
    required int offset,
  }) async {
    if (_db == null) return false;
    final found = await _db!.findBookmark(
      bookId: bookId,
      chapter: chapter,
      offset: offset,
    );
    return found != null;
  }

  // ---------------------------------------------------------------------------
  // Highlights
  // ---------------------------------------------------------------------------

  Future<String> addHighlight({
    required String bookId,
    required String text,
    String note = '',
    int color = 0,
    int? chapter,
    int? startOffset,
    int? endChapter,
    int? endOffset,
    int? page,
    String? segments,
  }) async {
    _validateHighlight(
      chapter: chapter,
      startOffset: startOffset,
      endChapter: endChapter,
      endOffset: endOffset,
      page: page,
      segments: segments,
    );
    if (_db == null) return '';

    final id = _newId();
    await _db!.insertHighlight(
      db.HighlightsCompanion.insert(
        id: id,
        bookId: bookId,
        quote: text,
        note: Value(note),
        color: Value(color),
        chapter: Value(chapter),
        startOffset: Value(startOffset),
        endChapter: Value(endChapter),
        endOffset: Value(endOffset),
        page: Value(page),
        segments: Value(segments),
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    notifyListeners();
    return id;
  }

  void _validateHighlight({
    required int? chapter,
    required int? startOffset,
    required int? endChapter,
    required int? endOffset,
    required int? page,
    required String? segments,
  }) {
    final hasReflowable =
        chapter != null ||
        startOffset != null ||
        endChapter != null ||
        endOffset != null;
    final hasPdf = page != null || segments != null;
    if (hasReflowable == hasPdf) {
      throw ArgumentError('Highlight needs exactly one locator family');
    }

    if (hasReflowable) {
      if (chapter == null ||
          startOffset == null ||
          endChapter == null ||
          endOffset == null) {
        throw ArgumentError('Reflowable highlight is missing an offset');
      }
      if (chapter < 0 || endChapter < chapter) {
        throw ArgumentError('Invalid highlight chapter range');
      }
      if (startOffset < 0 || endOffset < 0) {
        throw ArgumentError('Highlight offsets must be non-negative');
      }
      if (endChapter == chapter && endOffset <= startOffset) {
        throw ArgumentError('Highlight end must follow its start');
      }
      return;
    }

    if (page == null || page < 1) {
      throw ArgumentError('PDF highlight needs a positive page');
    }
    if (segments == null) {
      throw ArgumentError('PDF highlight needs segments');
    }

    Object? decoded;
    try {
      decoded = jsonDecode(segments);
    } on FormatException {
      throw ArgumentError('PDF highlight segments are not valid JSON');
    }
    if (decoded is! List) {
      throw ArgumentError('PDF highlight segments must be a list');
    }
    for (final entry in decoded) {
      if (entry is! Map || entry['page'] is! int || entry['rects'] is! List) {
        throw ArgumentError('Malformed PDF highlight segment');
      }
    }
  }

  Future<List<db.HighlightRow>> getHighlights(String bookId) async {
    if (_db == null) return [];
    return _db!.getHighlightsForBook(bookId);
  }

  Future<void> updateHighlightNote(String id, String note) async {
    if (_db == null) return;
    await _db!.updateHighlightNote(id, note);
    notifyListeners();
  }

  Future<void> updateHighlightColor(String id, int color) async {
    if (_db == null) return;
    await _db!.updateHighlightColor(id, color);
    notifyListeners();
  }

  Future<void> deleteHighlight(String id) async {
    if (_db == null) return;
    await _db!.deleteHighlightById(id);
    notifyListeners();
  }

  Future<int> countHighlightsForBook(String bookId) async {
    if (_db == null) return 0;
    return _db!.countHighlightsForBook(bookId);
  }

  Future<Map<String, int>> highlightCountsForBooks(
    Iterable<String> bookIds,
  ) async {
    if (_db == null) return {};
    final counts = <String, int>{};
    for (final id in bookIds.toSet()) {
      final count = await _db!.countHighlightsForBook(id);
      if (count > 0) counts[id] = count;
    }
    return counts;
  }

  // ---------------------------------------------------------------------------
  // Collections
  // ---------------------------------------------------------------------------

  Future<String> createCollection(String name) async {
    if (_db == null) return '';
    final id = _newId();
    final collection = db.CollectionsCompanion.insert(
      id: id,
      name: name,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _db!.insertCollection(collection);
    _collections
      ..clear()
      ..addAll(await _db!.getAllCollections());
    notifyListeners();
    return id;
  }

  Future<void> deleteCollection(String id) async {
    if (_db == null) return;
    await _db!.deleteCollectionById(id);
    _collections.removeWhere((c) => c.id == id);
    notifyListeners();
  }

  Future<void> renameCollection(String id, String name) async {
    if (_db == null) return;
    final existing = _collections.where((c) => c.id == id).firstOrNull;
    if (existing == null) return;
    await _db!.updateCollection(
      db.CollectionsCompanion(id: Value(id), name: Value(name)),
    );
    final updated = await _db!.getAllCollections();
    _collections
      ..clear()
      ..addAll(updated);
    notifyListeners();
  }

  /// Persists a collection's sort type. Always updates the in-memory entry;
  /// the database row is written when a db is attached. The collection
  /// screen taps this so the choice survives a restart.
  Future<void> setCollectionSortType(String id, int sortType) async {
    final i = _collections.indexWhere((c) => c.id == id);
    if (i < 0) return;
    _collections[i] = _collections[i].copyWith(sortType: sortType);
    if (_db != null) {
      await _db!.updateCollection(
        db.CollectionsCompanion(id: Value(id), sortType: Value(sortType)),
      );
      _collections
        ..clear()
        ..addAll(await _db!.getAllCollections());
    }
    notifyListeners();
  }

  Future<void> addBookToCollection(String collectionId, String bookId) async {
    if (_db == null) return;
    await _db!.addBookToCollection(collectionId, bookId);
    notifyListeners();
  }

  Future<void> removeBookFromCollection(
    String collectionId,
    String bookId,
  ) async {
    if (_db == null) return;
    await _db!.removeBookFromCollection(collectionId, bookId);
    notifyListeners();
  }

  Future<bool> isBookInCollection(String collectionId, String bookId) async {
    if (_db == null) return false;
    return _db!.isBookInCollection(collectionId, bookId);
  }

  Future<List<Book>> getBooksForCollection(String collectionId) async {
    if (_db == null) return [];
    final links = await _db!.getBooksForCollection(collectionId);
    final bookIds = links.map((l) => l.bookId).toSet();
    return _books.where((b) => bookIds.contains(b.id)).toList();
  }

  Future<int> getCollectionBookCount(String collectionId) async {
    if (_db == null) return 0;
    return _db!.getCollectionBookCount(collectionId);
  }

  Future<List<db.Collection>> getCollectionsForBook(String bookId) async {
    if (_db == null) return [];
    return _db!.getCollectionsForBook(bookId);
  }

  Future<void> reorderCollectionBook(
    String collectionId,
    List<String> bookIds,
  ) async {
    if (_db == null) return;
    final links = await _db!.getBooksForCollection(collectionId);
    for (var i = 0; i < bookIds.length; i++) {
      final link = links.where((l) => l.bookId == bookIds[i]).firstOrNull;
      if (link != null) {
        await _db!.updateCollectionBookSortPosition(link.id, i);
      }
    }
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Author helpers
  // ---------------------------------------------------------------------------

  /// Returns a sorted list of unique author names from all books.
  List<String> get uniqueAuthors {
    final authors = <String>{};
    for (final b in _books) {
      if (b.author.isNotEmpty) authors.add(b.author);
    }
    final sorted = authors.toList()..sort();
    return sorted;
  }

  /// Returns books by a specific author (case-insensitive match).
  List<Book> booksByAuthor(String author) {
    final lower = author.toLowerCase();
    return _books.where((b) => b.author.toLowerCase() == lower).toList();
  }

  /// Returns the number of books by a specific author.
  int authorBookCount(String author) => booksByAuthor(author).length;

  // ---------------------------------------------------------------------------
  // Series helpers
  // ---------------------------------------------------------------------------

  /// Returns a sorted list of unique series names from all books.
  List<String> get uniqueSeries {
    final series = <String>{};
    for (final b in _books) {
      if (b.seriesName != null && b.seriesName!.isNotEmpty) {
        series.add(b.seriesName!);
      }
    }
    final sorted = series.toList()..sort();
    return sorted;
  }

  /// Returns books in a specific series (case-insensitive match).
  List<Book> booksBySeries(String series) {
    final lower = series.toLowerCase();
    return _books.where((b) => b.seriesName?.toLowerCase() == lower).toList();
  }

  /// Returns the number of books in a specific series.
  int seriesBookCount(String series) => booksBySeries(series).length;

  // ---------------------------------------------------------------------------
  // Genre helpers
  // ---------------------------------------------------------------------------

  /// Returns a sorted list of unique genre names from all books.
  /// Genres are stored as comma-separated strings, so this splits them.
  List<String> get uniqueGenres {
    final genres = <String>{};
    for (final b in _books) {
      if (b.genre != null) {
        for (final g in b.genre!.split(',')) {
          final trimmed = g.trim();
          if (trimmed.isNotEmpty) genres.add(trimmed);
        }
      }
    }
    final sorted = genres.toList()..sort();
    return sorted;
  }

  /// Returns books that include [genre] in their comma-separated genre field.
  List<Book> booksByGenre(String genre) {
    final lower = genre.toLowerCase();
    return _books.where((b) {
      if (b.genre == null) return false;
      for (final g in b.genre!.split(',')) {
        if (g.trim().toLowerCase() == lower) return true;
      }
      return false;
    }).toList();
  }

  /// Returns the number of books in a specific genre.
  int genreBookCount(String genre) => booksByGenre(genre).length;

  // ---------------------------------------------------------------------------
  // Reading sessions
  // ---------------------------------------------------------------------------

  /// Starts a new reading session. Returns the session ID.
  Future<int> startSession(String bookId) async {
    if (_db == null) return -1;
    return _db!.insertSession(
      db.ReadingSessionsCompanion.insert(
        bookId: bookId,
        startedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  /// Ends a session with the given page flip count.
  Future<void> endSession(int sessionId, {int pages = 0, int? endedAt}) async {
    if (_db == null) return;
    await _db!.endSession(sessionId, pages: pages, endedAt: endedAt);
  }

  Future<List<db.ReadingSession>> getSessionsForBook(String bookId) async {
    if (_db == null) return [];
    return _db!.getSessionsForBook(bookId);
  }

  Future<List<db.ReadingSession>> getAllSessions() async {
    if (_db == null) return [];
    return _db!.getAllSessions();
  }

  Future<int> getTotalReadingTimeMs(String bookId) async {
    if (_db == null) return 0;
    return _db!.getTotalReadingTimeMs(bookId);
  }

  Future<int> getTotalPagesRead(String bookId) async {
    if (_db == null) return 0;
    return _db!.getTotalPagesRead(bookId);
  }

  Future<Map<int, int>> getDailyReadingTime() async {
    if (_db == null) return {};
    return _db!.getDailyReadingTime();
  }

  Future<int> getReadingStreak() async {
    if (_db == null) return 0;
    return _db!.getReadingStreak();
  }

  Future<Map<int, int>> getHourlyReadingTime() async {
    if (_db == null) return {};
    return _db!.getHourlyReadingTime();
  }

  Future<Map<String, int>> getMonthlyReadingTime() async {
    if (_db == null) return {};
    return _db!.getMonthlyReadingTime();
  }

  Future<int> getLongestSessionMs() async {
    if (_db == null) return 0;
    return _db!.getLongestSessionMs();
  }

  Future<int> getAverageSessionMs() async {
    if (_db == null) return 0;
    return _db!.getAverageSessionMs();
  }

  Future<int> getTodayReadingTimeMs() async {
    if (_db == null) return 0;
    return _db!.getTodayReadingTimeMs();
  }

  Future<int> getThisWeekReadingTimeMs() async {
    if (_db == null) return 0;
    return _db!.getThisWeekReadingTimeMs();
  }

  Future<List<BookStats>> getPerBookStats() async {
    if (_db == null) return [];
    return _db!.getPerBookStats(books);
  }
}
