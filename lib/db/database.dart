import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/book.dart';
import '../models/book_stats.dart';

part 'database.g.dart';

// ---------------------------------------------------------------------------
// Table definitions
// ---------------------------------------------------------------------------

@DataClassName('BookRow')
class Books extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get author => text().withDefault(const Constant(''))();
  TextColumn get path => text()();
  IntColumn get format => intEnum<BookFormat>()();
  TextColumn? get coverPath => text().nullable()();
  IntColumn get addedAt => integer()();
  IntColumn get lastReadAt => integer().withDefault(const Constant(0))();
  RealColumn get progress => real().withDefault(const Constant(0))();
  IntColumn get lastChapter => integer().withDefault(const Constant(0))();
  IntColumn get lastOffset => integer().withDefault(const Constant(0))();
  TextColumn? get description => text().nullable()();
  TextColumn? get genre => text().nullable()();
  TextColumn? get seriesName => text().nullable()();
  RealColumn? get seriesIndex => real().nullable()();
  TextColumn? get publisher => text().nullable()();
  TextColumn? get isbn => text().nullable()();
  TextColumn? get language => text().nullable()();
  TextColumn? get review => text().nullable()();
  TextColumn? get annotation => text().nullable()();
  TextColumn? get publicationDate => text().nullable()();
  TextColumn? get rights => text().nullable()();
  TextColumn? get type => text().nullable()();
  TextColumn? get source => text().nullable()();
  TextColumn? get titleSort => text().nullable()();
  TextColumn? get authorSort => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class Bookmarks extends Table {
  TextColumn get id => text()();
  TextColumn get bookId => text().references(Books, #id)();
  IntColumn get chapter => integer()();
  IntColumn get offset => integer()();
  TextColumn get snippet => text().withDefault(const Constant(''))();
  IntColumn get createdAt => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

class ReadingSessions extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get bookId => text().references(Books, #id)();
  IntColumn get startedAt => integer()();
  IntColumn get endedAt => integer().withDefault(const Constant(0))();
  IntColumn get pages => integer().withDefault(const Constant(0))();
}

class Meta extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

class Collections extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  IntColumn get sortType =>
      integer().withDefault(const Constant(0))(); // 0=manual,1=alpha,2=recent
  IntColumn get createdAt => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

class CollectionBooks extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get collectionId =>
      text().references(Collections, #id)();
  TextColumn get bookId => text().references(Books, #id)();
  IntColumn get addedAt => integer()();
  IntColumn get sortPosition => integer().withDefault(const Constant(0))();
}

// ---------------------------------------------------------------------------
// Database
// ---------------------------------------------------------------------------

@DriftDatabase(
    tables: [Books, Bookmarks, ReadingSessions, Meta, Collections, CollectionBooks])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  AppDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 4;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
        },
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.createTable(collections);
            await m.createTable(collectionBooks);
          }
          if (from < 3) {
            await m.addColumn(books, books.description);
            await m.addColumn(books, books.genre);
            await m.addColumn(books, books.seriesName);
            await m.addColumn(books, books.seriesIndex);
            await m.addColumn(books, books.publisher);
            await m.addColumn(books, books.isbn);
            await m.addColumn(books, books.language);
            await m.addColumn(books, books.review);
          }
          if (from < 4) {
            await m.addColumn(books, books.annotation);
            await m.addColumn(books, books.publicationDate);
            await m.addColumn(books, books.rights);
            await m.addColumn(books, books.type);
            await m.addColumn(books, books.source);
            await m.addColumn(books, books.titleSort);
            await m.addColumn(books, books.authorSort);
          }
        },
      );

  // -- Books CRUD ------------------------------------------------------------

  Future<List<Book>> getAllBooks() async =>
      (select(books)).get().then((rows) => rows.map(bookFromRow).toList());

  Future<void> insertBook(BooksCompanion book) async =>
      into(books).insert(book);

  Future<void> updateBook(BooksCompanion book) async =>
      (update(books)..where((t) => t.id.equals(book.id.value))).write(book);

  Future<void> deleteBookById(String id) async =>
      (delete(books)..where((t) => t.id.equals(id))).go();

  // -- Meta (schema versioning) ----------------------------------------------

  Future<String?> getMeta(String key) async {
    final row = await (select(meta)..where((t) => t.key.equals(key)))
        .getSingleOrNull();
    return row?.value;
  }

  Future<void> setMeta(String key, String value) async =>
      into(meta).insertOnConflictUpdate(MetaCompanion.insert(
        key: key,
        value: value,
      ));

  // -- Bookmarks CRUD --------------------------------------------------------

  Future<void> insertBookmark(BookmarksCompanion bookmark) async =>
      into(bookmarks).insert(bookmark);

  Future<List<Bookmark>> getBookmarksForBook(String bookId) async =>
      (select(bookmarks)
            ..where((t) => t.bookId.equals(bookId))
            ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
          .get();

  /// Every bookmark across all books, for library backup/restore.
  Future<List<Bookmark>> getAllBookmarks() async =>
      (select(bookmarks)..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
          .get();

  Future<bool> bookmarkExists(String id) async =>
      await (select(bookmarks)..where((t) => t.id.equals(id))..limit(1))
              .getSingleOrNull() !=
          null;

  Future<void> deleteBookmarkById(String id) async =>
      (delete(bookmarks)..where((t) => t.id.equals(id))).go();

  Future<Bookmark?> findBookmark({
    required String bookId,
    required int chapter,
    required int offset,
  }) async =>
      (select(bookmarks)
            ..where((t) =>
                t.bookId.equals(bookId) &
                t.chapter.equals(chapter) &
                t.offset.equals(offset))
            ..limit(1))
          .getSingleOrNull();

  // -- Reading sessions CRUD --------------------------------------------------

  Future<int> insertSession(ReadingSessionsCompanion session) async =>
      into(readingSessions).insert(session);

  Future<void> endSession(int id, {int pages = 0, int? endedAt}) async =>
      (update(readingSessions)..where((t) => t.id.equals(id))).write(
        ReadingSessionsCompanion(
          endedAt: Value(endedAt ?? DateTime.now().millisecondsSinceEpoch),
          pages: Value(pages),
        ),
      );

  Future<List<ReadingSession>> getSessionsForBook(String bookId) async =>
      (select(readingSessions)
            ..where((t) => t.bookId.equals(bookId))
            ..orderBy([(t) => OrderingTerm.desc(t.startedAt)]))
          .get();

  Future<List<ReadingSession>> getAllSessions() async =>
      (select(readingSessions)
            ..orderBy([(t) => OrderingTerm.desc(t.startedAt)]))
          .get();

  Future<int> getTotalReadingTimeMs(String bookId) async {
    final sessions = await getSessionsForBook(bookId);
    var total = 0;
    for (final s in sessions) {
      if (s.endedAt > 0) {
        total += s.endedAt - s.startedAt;
      }
    }
    return total;
  }

  Future<int> getTotalPagesRead(String bookId) async {
    final sessions = await getSessionsForBook(bookId);
    var total = 0;
    for (final s in sessions) {
      total += s.pages;
    }
    return total;
  }

  /// Returns sessions grouped by day (epoch day) with total time in ms.
  Future<Map<int, int>> getDailyReadingTime() async {
    final sessions = await getAllSessions();
    final daily = <int, int>{};
    for (final s in sessions) {
      if (s.endedAt <= 0) continue;
      final day = (s.startedAt / 86400000).floor();
      daily[day] = (daily[day] ?? 0) + (s.endedAt - s.startedAt);
    }
    return daily;
  }

  /// Returns the number of consecutive days with reading, ending today.
  Future<int> getReadingStreak() async {
    final daily = await getDailyReadingTime();
    if (daily.isEmpty) return 0;
    final today = (DateTime.now().millisecondsSinceEpoch / 86400000).floor();
    var streak = 0;
    var day = today;
    while (daily.containsKey(day)) {
      streak++;
      day--;
    }
    return streak;
  }

  /// Returns reading time grouped by hour-of-day (0–23).
  Future<Map<int, int>> getHourlyReadingTime() async {
    final sessions = await getAllSessions();
    final hourly = <int, int>{};
    for (final s in sessions) {
      if (s.endedAt <= 0) continue;
      final hour = DateTime.fromMillisecondsSinceEpoch(s.startedAt).hour;
      hourly[hour] = (hourly[hour] ?? 0) + (s.endedAt - s.startedAt);
    }
    return hourly;
  }

  /// Returns reading time grouped by "YYYY-MM" key.
  Future<Map<String, int>> getMonthlyReadingTime() async {
    final sessions = await getAllSessions();
    final monthly = <String, int>{};
    for (final s in sessions) {
      if (s.endedAt <= 0) continue;
      final d = DateTime.fromMillisecondsSinceEpoch(s.startedAt);
      final key = '${d.year}-${d.month.toString().padLeft(2, '0')}';
      monthly[key] = (monthly[key] ?? 0) + (s.endedAt - s.startedAt);
    }
    return monthly;
  }

  /// Returns the longest single reading session in ms.
  Future<int> getLongestSessionMs() async {
    final sessions = await getAllSessions();
    var longest = 0;
    for (final s in sessions) {
      if (s.endedAt <= 0) continue;
      final dur = s.endedAt - s.startedAt;
      if (dur > longest) longest = dur;
    }
    return longest;
  }

  /// Returns the average session duration in ms.
  Future<int> getAverageSessionMs() async {
    final sessions = await getAllSessions();
    var total = 0;
    var count = 0;
    for (final s in sessions) {
      if (s.endedAt <= 0) continue;
      total += s.endedAt - s.startedAt;
      count++;
    }
    return count > 0 ? total ~/ count : 0;
  }

  /// Returns total reading time in ms for today.
  Future<int> getTodayReadingTimeMs() async {
    final sessions = await getAllSessions();
    final todayEpoch = (DateTime.now().millisecondsSinceEpoch / 86400000).floor();
    var total = 0;
    for (final s in sessions) {
      if (s.endedAt <= 0) continue;
      final day = (s.startedAt / 86400000).floor();
      if (day == todayEpoch) total += s.endedAt - s.startedAt;
    }
    return total;
  }

  /// Returns total reading time in ms for the last 7 days.
  Future<int> getThisWeekReadingTimeMs() async {
    final sessions = await getAllSessions();
    final now = DateTime.now();
    final weekAgo = now.subtract(const Duration(days: 7)).millisecondsSinceEpoch;
    var total = 0;
    for (final s in sessions) {
      if (s.endedAt <= 0) continue;
      if (s.startedAt >= weekAgo) total += s.endedAt - s.startedAt;
    }
    return total;
  }

  /// Returns per-book reading stats for all started books, sorted by time desc.
  Future<List<BookStats>> getPerBookStats(List<Book> books) async {
    final results = <BookStats>[];
    for (final book in books) {
      if (!book.isStarted) continue;
      final sessions = await getSessionsForBook(book.id);
      var totalTime = 0;
      var totalPages = 0;
      var sessionCount = 0;
      for (final s in sessions) {
        if (s.endedAt > 0) {
          totalTime += s.endedAt - s.startedAt;
          sessionCount++;
        }
        totalPages += s.pages;
      }
      results.add(BookStats(
        book: book,
        totalTimeMs: totalTime,
        totalPages: totalPages,
        sessionCount: sessionCount,
      ));
    }
    results.sort((a, b) => b.totalTimeMs.compareTo(a.totalTimeMs));
    return results;
  }

  // -- Collections CRUD ------------------------------------------------------

  Future<List<Collection>> getAllCollections() async =>
      (select(collections)..orderBy([(t) => OrderingTerm.asc(t.name)])).get();

  Future<void> insertCollection(CollectionsCompanion collection) async =>
      into(collections).insert(collection);

  Future<void> updateCollection(CollectionsCompanion collection) async =>
      (update(collections)..where((t) => t.id.equals(collection.id.value)))
          .write(collection);

  Future<void> deleteCollectionById(String id) async {
    await (delete(collectionBooks)..where((t) => t.collectionId.equals(id)))
        .go();
    await (delete(collections)..where((t) => t.id.equals(id))).go();
  }

  Future<void> addBookToCollection(String collectionId, String bookId) async {
    await into(collectionBooks).insert(
      CollectionBooksCompanion.insert(
        collectionId: collectionId,
        bookId: bookId,
        addedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  Future<void> removeBookFromCollection(
      String collectionId, String bookId) async {
    await (delete(collectionBooks)
          ..where((t) =>
              t.collectionId.equals(collectionId) & t.bookId.equals(bookId)))
        .go();
  }

  Future<List<CollectionBook>> getBooksForCollection(String collectionId) async =>
      (select(collectionBooks)
            ..where((t) => t.collectionId.equals(collectionId))
            ..orderBy([(t) => OrderingTerm.asc(t.sortPosition)]))
          .get();

  Future<bool> isBookInCollection(String collectionId, String bookId) async =>
      await (select(collectionBooks)
                ..where((t) =>
                    t.collectionId.equals(collectionId) &
                    t.bookId.equals(bookId))
                ..limit(1))
              .getSingleOrNull() !=
          null;

  Future<int> getCollectionBookCount(String collectionId) async {
    final count = collectionBooks.id.count();
    final result = await (selectOnly(collectionBooks)
          ..where(collectionBooks.collectionId.equals(collectionId))
          ..addColumns([count]))
        .getSingle();
    return result.read(count) ?? 0;
  }

  Future<List<Collection>> getCollectionsForBook(String bookId) async {
    final query = select(collections).join([
      innerJoin(collectionBooks,
          collectionBooks.collectionId.equalsExp(collections.id)),
    ])..where(collectionBooks.bookId.equals(bookId));
    final rows = await query.get();
    return rows.map((row) => row.readTable(collections)).toList();
  }

  Future<List<CollectionBook>> getAllCollectionBooks() async =>
      select(collectionBooks).get();

  Future<void> updateCollectionBookSortPosition(
      int id, int sortPosition) async {
    await (update(collectionBooks)..where((t) => t.id.equals(id))).write(
      CollectionBooksCompanion(sortPosition: Value(sortPosition)),
    );
  }
}

// ---------------------------------------------------------------------------
// Conversion helpers
// ---------------------------------------------------------------------------

Book bookFromRow(BookRow row) => Book(
      id: row.id,
      title: row.title,
      author: row.author,
      path: row.path,
      format: row.format,
      coverPath: row.coverPath,
      addedAt: row.addedAt,
      lastReadAt: row.lastReadAt,
      progress: row.progress,
      lastChapter: row.lastChapter,
      lastOffset: row.lastOffset,
      description: row.description,
      annotation: row.annotation,
      genre: row.genre,
      seriesName: row.seriesName,
      seriesIndex: row.seriesIndex,
      publisher: row.publisher,
      isbn: row.isbn,
      language: row.language,
      review: row.review,
      publicationDate: row.publicationDate,
      rights: row.rights,
      type: row.type,
      source: row.source,
      titleSort: row.titleSort,
      authorSort: row.authorSort,
    );

BooksCompanion bookToCompanion(Book book) => BooksCompanion.insert(
      id: book.id,
      title: book.title,
      author: Value(book.author),
      path: book.path,
      format: book.format,
      coverPath: Value(book.coverPath),
      addedAt: book.addedAt,
      lastReadAt: Value(book.lastReadAt),
      progress: Value(book.progress),
      lastChapter: Value(book.lastChapter),
      lastOffset: Value(book.lastOffset),
      description: Value(book.description),
      annotation: Value(book.annotation),
      genre: Value(book.genre),
      seriesName: Value(book.seriesName),
      seriesIndex: Value(book.seriesIndex),
      publisher: Value(book.publisher),
      isbn: Value(book.isbn),
      language: Value(book.language),
      review: Value(book.review),
      publicationDate: Value(book.publicationDate),
      rights: Value(book.rights),
      type: Value(book.type),
      source: Value(book.source),
      titleSort: Value(book.titleSort),
      authorSort: Value(book.authorSort),
    );

BooksCompanion bookToCompanionForUpdate(Book book) => BooksCompanion(
      id: Value(book.id),
      title: Value(book.title),
      author: Value(book.author),
      path: Value(book.path),
      format: Value(book.format),
      coverPath: Value(book.coverPath),
      addedAt: Value(book.addedAt),
      lastReadAt: Value(book.lastReadAt),
      progress: Value(book.progress),
      lastChapter: Value(book.lastChapter),
      lastOffset: Value(book.lastOffset),
      description: Value(book.description),
      annotation: Value(book.annotation),
      genre: Value(book.genre),
      seriesName: Value(book.seriesName),
      seriesIndex: Value(book.seriesIndex),
      publisher: Value(book.publisher),
      isbn: Value(book.isbn),
      language: Value(book.language),
      review: Value(book.review),
      publicationDate: Value(book.publicationDate),
      rights: Value(book.rights),
      type: Value(book.type),
      source: Value(book.source),
      titleSort: Value(book.titleSort),
      authorSort: Value(book.authorSort),
    );

BooksCompanion positionToUpdate({
  required String id,
  required int lastChapter,
  required int lastOffset,
  required double progress,
  required int lastReadAt,
}) =>
    BooksCompanion(
      id: Value(id),
      lastChapter: Value(lastChapter),
      lastOffset: Value(lastOffset),
      progress: Value(progress),
      lastReadAt: Value(lastReadAt),
    );

// ---------------------------------------------------------------------------
// Backup serialization (bookmarks + sessions; books use Book.toJson)
// ---------------------------------------------------------------------------

Map<String, dynamic> bookmarkToJson(Bookmark b) => {
      'id': b.id,
      'bookId': b.bookId,
      'chapter': b.chapter,
      'offset': b.offset,
      'snippet': b.snippet,
      'createdAt': b.createdAt,
    };

BookmarksCompanion bookmarkFromJson(Map<String, dynamic> j) =>
    BookmarksCompanion.insert(
      id: j['id'] as String,
      bookId: j['bookId'] as String,
      chapter: j['chapter'] as int,
      offset: j['offset'] as int,
      snippet: Value((j['snippet'] as String?) ?? ''),
      createdAt: j['createdAt'] as int? ?? 0,
    );

Map<String, dynamic> sessionToJson(ReadingSession s) => {
      'id': s.id,
      'bookId': s.bookId,
      'startedAt': s.startedAt,
      'endedAt': s.endedAt,
      'pages': s.pages,
    };

ReadingSessionsCompanion sessionFromJson(Map<String, dynamic> j) =>
    ReadingSessionsCompanion.insert(
      bookId: j['bookId'] as String,
      startedAt: j['startedAt'] as int,
      endedAt: Value(j['endedAt'] as int? ?? 0),
      pages: Value(j['pages'] as int? ?? 0),
    );

Map<String, dynamic> collectionToJson(Collection c) => {
      'id': c.id,
      'name': c.name,
      'sortType': c.sortType,
      'createdAt': c.createdAt,
    };

CollectionsCompanion collectionFromJson(Map<String, dynamic> j) =>
    CollectionsCompanion.insert(
      id: j['id'] as String,
      name: j['name'] as String,
      sortType: Value(j['sortType'] as int? ?? 0),
      createdAt: j['createdAt'] as int,
    );

Map<String, dynamic> collectionBookToJson(CollectionBook cb) => {
      'id': cb.id,
      'collectionId': cb.collectionId,
      'bookId': cb.bookId,
      'addedAt': cb.addedAt,
      'sortPosition': cb.sortPosition,
    };

CollectionBooksCompanion collectionBookFromJson(Map<String, dynamic> j) =>
    CollectionBooksCompanion.insert(
      collectionId: j['collectionId'] as String,
      bookId: j['bookId'] as String,
      addedAt: j['addedAt'] as int,
      sortPosition: Value(j['sortPosition'] as int? ?? 0),
    );

// ---------------------------------------------------------------------------
// Connection
// ---------------------------------------------------------------------------

LazyDatabase _openConnection() => LazyDatabase(() async {
      final dir = await getApplicationDocumentsDirectory();
      final file = File(p.join(dir.path, 'burrow.db'));
      return NativeDatabase(file);
    });
