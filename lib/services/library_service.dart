import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../db/database.dart' as db;
import '../models/book.dart';
import 'package:drift/drift.dart' show Value;
import '../models/reader_settings.dart';
import '../services/pdf_cover.dart';
import 'document_parser.dart';

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

  db.AppDatabase? _db;
  final List<Book> _books = [];
  final List<db.Collection> _collections = [];
  ReaderSettings settings = ReaderSettings();
  String libraryLayout = 'grid';

  /// Whether the first-run onboarding flow has been completed.
  bool onboardingComplete = false;

  /// Test-only override so tests can supply an in-memory database before
  /// [load] runs instead of opening the real one.
  @visibleForTesting
  void debugAttachDatabase(db.AppDatabase database) => _db = database;

  Directory? _coversDir;

  List<Book> get books => List.unmodifiable(_books);

  List<db.Collection> get collections => List.unmodifiable(_collections);

  /// Test-only: injects books without touching the database.
  @visibleForTesting
  void debugAddAll(Iterable<Book> books) => _books.addAll(books);

  /// Books sorted for display: recently read first, then newest imports.
  List<Book> get sorted {
    final list = [..._books];
    list.sort((a, b) {
      if ((a.lastReadAt > 0) != (b.lastReadAt > 0)) {
        return a.lastReadAt > 0 ? -1 : 1;
      }
      return b.lastReadAt.compareTo(a.lastReadAt) != 0
          ? b.lastReadAt.compareTo(a.lastReadAt)
          : b.addedAt.compareTo(a.addedAt);
    });
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
        } catch (_) {
          // Corrupt legacy data: start fresh rather than crash.
        }
      }
    }

    // Load catalog from the database.
    _books
      ..clear()
      ..addAll(await _db!.getAllBooks());

    // Load collections.
    _collections
      ..clear()
      ..addAll(await _db!.getAllCollections());

    // Settings stay in SharedPreferences.
    final settingsRaw = prefs.getString(_settingsKey);
    if (settingsRaw != null) {
      try {
        settings =
            ReaderSettings.fromJson(jsonDecode(settingsRaw) as Map<String, dynamic>);
      } catch (_) {}
    }

    // Library layout preference.
    libraryLayout = prefs.getString(_layoutKey) ?? 'grid';

    // First-run onboarding state.
    onboardingComplete = prefs.getBool(_onboardingKey) ?? false;

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

  bool containsPath(String path) => _books.any((b) => b.path == path);

  // ---------------------------------------------------------------------------
  // Backup / restore
  // ---------------------------------------------------------------------------

  /// Exports the catalog, bookmarks and reading sessions as a JSON file in
  /// the app documents directory. Returns the written file's path.
  Future<String> exportLibrary() async {
    final dir = await getApplicationDocumentsDirectory();
    final now = DateTime.now();
    final stamp = '${now.year.toString().padLeft(4, '0')}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}'
        '-${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}';
    final file = File(p.join(dir.path, 'burrow-backup-$stamp.json'));

    final bookmarks = _db == null ? <db.Bookmark>[] : await _db!.getAllBookmarks();
    final sessions =
        _db == null ? <db.ReadingSession>[] : await _db!.getAllSessions();
    final collectionBooks =
        _db == null ? <db.CollectionBook>[] : await _db!.getAllCollectionBooks();

    final payload = {
      'format': 'burrow-backup',
      'version': 2,
      'exportedAt': now.millisecondsSinceEpoch,
      'books': _books.map((b) => b.toJson()).toList(),
      'bookmarks': [for (final b in bookmarks) db.bookmarkToJson(b)],
      'sessions': [for (final s in sessions) db.sessionToJson(s)],
      'collections': [for (final c in _collections) db.collectionToJson(c)],
      'collectionBooks': [for (final cb in collectionBooks) db.collectionBookToJson(cb)],
    };
    await file.writeAsString(jsonEncode(payload));
    return file.path;
  }

  /// Restores books, bookmarks and sessions from a backup file.
  ///
  /// Books already in the library (matched by id) are skipped along with
  /// their annotations, so importing the same backup twice is a no-op.
  /// Returns the number of newly imported books.
  Future<int> importLibrary(String path) async {
    final raw = await File(path).readAsString();
    final dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      throw const FormatException('Not a Burrow backup file');
    }
    if (decoded is! Map<String, dynamic> ||
        decoded['format'] != 'burrow-backup') {
      throw const FormatException('Not a Burrow backup file');
    }

    final booksJson = (decoded['books'] as List?) ?? const [];
    final bookmarksJson = (decoded['bookmarks'] as List?) ?? const [];
    final sessionsJson = (decoded['sessions'] as List?) ?? const [];
    final collectionsJson = (decoded['collections'] as List?) ?? const [];
    final collectionBooksJson =
        (decoded['collectionBooks'] as List?) ?? const [];

    var imported = 0;
    for (final item in booksJson) {
      try {
        final book = Book.fromJson(item as Map<String, dynamic>);
        if (_books.any((b) => b.id == book.id)) continue;
        _books.add(book);
        if (_db != null) {
          await _db!.insertBook(db.bookToCompanion(book));
          // Annotations are restored only for newly imported books so
          // repeated imports never duplicate them.
          for (final bm in bookmarksJson) {
            final m = bm as Map<String, dynamic>;
            if (m['bookId'] != book.id) continue;
            if (!await _db!.bookmarkExists(m['id'] as String)) {
              await _db!.insertBookmark(db.bookmarkFromJson(m));
            }
          }
          for (final s in sessionsJson) {
            final m = s as Map<String, dynamic>;
            if (m['bookId'] == book.id) {
              await _db!.insertSession(db.sessionFromJson(m));
            }
          }
        }
        imported++;
      } catch (_) {
        // Malformed entry: skip rather than abort the whole import.
      }
    }

    // Restore collections (skip duplicates by id).
    for (final item in collectionsJson) {
      try {
        final m = item as Map<String, dynamic>;
        final id = m['id'] as String;
        if (_collections.any((c) => c.id == id)) continue;
        if (_db != null) {
          await _db!.insertCollection(db.collectionFromJson(m));
        }
      } catch (_) {}
    }
    // Restore collection-book links (skip duplicates).
    for (final item in collectionBooksJson) {
      try {
        final m = item as Map<String, dynamic>;
        final collectionId = m['collectionId'] as String;
        final bookId = m['bookId'] as String;
        if (_db != null) {
          if (!await _db!.isBookInCollection(collectionId, bookId)) {
            await _db!.addBookToCollection(collectionId, bookId);
          }
        }
      } catch (_) {}
    }
    // Reload collections into memory.
    if (_db != null) {
      _collections
        ..clear()
        ..addAll(await _db!.getAllCollections());
    }

    if (imported > 0) notifyListeners();
    return imported;
  }

  /// Imports a document: parses metadata + cover in a background isolate.
  /// Returns the new book, or null if it was already in the library.
  Future<Book?> importFile(String path) async {
    if (containsPath(path)) return null;

    final format = formatFromExtension(path);
    ParsedDocument doc;
    try {
      doc = await DocumentParser.parse(path, format);
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Could not read this file');
    }

    final book = Book(
      id: _newId(),
      title: doc.title,
      author: doc.author,
      path: path,
      format: format,
      addedAt: DateTime.now().millisecondsSinceEpoch,
      coverPath: await _saveCover(doc.coverBytes),
      description: doc.description,
      annotation: doc.annotation,
      genre: doc.genre,
      seriesName: doc.seriesName,
      seriesIndex: doc.seriesIndex,
      publisher: doc.publisher,
      isbn: doc.isbn,
      language: doc.language,
      publicationDate: doc.publicationDate,
      rights: doc.rights,
      type: doc.type,
      source: doc.source,
      titleSort: doc.titleSort,
      authorSort: doc.authorSort,
    );
    _books.add(book);
    if (_db != null) await _db!.insertBook(db.bookToCompanion(book));
    notifyListeners();

    if (format == BookFormat.pdf && book.coverPath == null) {
      _generatePdfCoverInBackground(book);
    }

    return book;
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
    } catch (_) {
      // Thumbnail failure is non-fatal; placeholder stays.
    }
  }

  Future<void> deleteBook(String id) async {
    final book = _books.where((b) => b.id == id).firstOrNull;
    if (book == null) return;
    _books.remove(book);
    final cover = book.coverPath;
    if (cover != null) {
      try {
        await File(cover).delete();
      } catch (_) {}
    }
    if (_db != null) await _db!.deleteBookById(id);
    notifyListeners();
  }

  /// Deletes a book and optionally its file from disk.
  Future<void> deleteBookWithFile(String id, {bool deleteFile = false}) async {
    final book = _books.where((b) => b.id == id).firstOrNull;
    if (book == null) return;
    _books.remove(book);
    final cover = book.coverPath;
    if (cover != null) {
      try {
        await File(cover).delete();
      } catch (_) {}
    }
    if (deleteFile) {
      try {
        await File(book.path).delete();
      } catch (_) {}
    }
    if (_db != null) await _db!.deleteBookById(id);
    notifyListeners();
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
    book.description = description;
    book.annotation = annotation;
    book.genre = genre;
    book.seriesName = seriesName;
    book.seriesIndex = seriesIndex;
    book.publisher = publisher;
    book.isbn = isbn;
    book.language = language;
    book.review = review;
    book.publicationDate = publicationDate;
    book.rights = rights;
    book.type = type;
    book.source = source;
    book.titleSort = titleSort;
    book.authorSort = authorSort;
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

  Future<String?> _saveCover(List<int>? bytes) async {
    if (bytes == null || bytes.isEmpty) return null;
    try {
      final dir = await _ensureCoversDir();
      final file = File(
        '${dir.path}/cover_${DateTime.now().microsecondsSinceEpoch}_${Random.secure().nextInt(1 << 32)}.img',
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
    if (!_coversDir!.existsSync()) _coversDir!.createSync(recursive: true);
    return _coversDir!;
  }

  String _newId() =>
      '${DateTime.now().microsecondsSinceEpoch}_${Random.secure().nextInt(1 << 32)}';

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
  // Collections
  // ---------------------------------------------------------------------------

  Future<void> createCollection(String name) async {
    if (_db == null) return;
    final collection = db.CollectionsCompanion.insert(
      id: _newId(),
      name: name,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _db!.insertCollection(collection);
    _collections.addAll(await _db!.getAllCollections());
    notifyListeners();
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
      db.CollectionsCompanion(
        id: Value(id),
        name: Value(name),
      ),
    );
    final updated = await _db!.getAllCollections();
    _collections
      ..clear()
      ..addAll(updated);
    notifyListeners();
  }

  Future<void> addBookToCollection(String collectionId, String bookId) async {
    if (_db == null) return;
    await _db!.addBookToCollection(collectionId, bookId);
    notifyListeners();
  }

  Future<void> removeBookFromCollection(
      String collectionId, String bookId) async {
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
      String collectionId, List<String> bookIds) async {
    if (_db == null) return;
    for (var i = 0; i < bookIds.length; i++) {
      final links = await _db!.getBooksForCollection(collectionId);
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
}
