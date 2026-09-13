import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
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
  BoolColumn get metadataComplete =>
      boolean().withDefault(const Constant(false))();

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
  TextColumn get collectionId => text().references(Collections, #id)();
  TextColumn get bookId => text().references(Books, #id)();
  IntColumn get addedAt => integer()();
  IntColumn get sortPosition => integer().withDefault(const Constant(0))();
}

class _PerBookAggregate {
  final int totalTimeMs;
  final int totalPages;
  final int sessionCount;

  const _PerBookAggregate({
    required this.totalTimeMs,
    required this.totalPages,
    required this.sessionCount,
  });
}

// ---------------------------------------------------------------------------
// Database
// ---------------------------------------------------------------------------

@DriftDatabase(
  tables: [
    Books,
    Bookmarks,
    ReadingSessions,
    Meta,
    Collections,
    CollectionBooks,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  AppDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 6;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
    },
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        try {
          await m.createTable(collections);
          await m.createTable(collectionBooks);
        } catch (e) {
          debugPrint('Migration step from=$from to=2 failed: $e');
        }
      }
      if (from < 3) {
        try {
          await m.addColumn(books, books.description);
          await m.addColumn(books, books.genre);
          await m.addColumn(books, books.seriesName);
          await m.addColumn(books, books.seriesIndex);
          await m.addColumn(books, books.publisher);
          await m.addColumn(books, books.isbn);
          await m.addColumn(books, books.language);
          await m.addColumn(books, books.review);
        } catch (e) {
          debugPrint('Migration step from=$from to=3 failed: $e');
        }
      }
      if (from < 4) {
        try {
          await m.addColumn(books, books.annotation);
          await m.addColumn(books, books.publicationDate);
          await m.addColumn(books, books.rights);
          await m.addColumn(books, books.type);
          await m.addColumn(books, books.source);
          await m.addColumn(books, books.titleSort);
          await m.addColumn(books, books.authorSort);
        } catch (e) {
          debugPrint('Migration step from=$from to=4 failed: $e');
        }
      }
      if (from < 5) {
        try {
          await m.addColumn(books, books.metadataComplete);
        } catch (e) {
          debugPrint('Migration step from=$from to=5 failed: $e');
        }
      }
      if (from < 6) {
        try {
          await customStatement(
            'CREATE INDEX IF NOT EXISTS idx_bookmarks_book_id ON bookmarks (book_id)',
          );
        } catch (e) {
          debugPrint('Migration step from=$from to=6 failed: $e');
        }
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
    final row = await (select(
      meta,
    )..where((t) => t.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  Future<void> setMeta(String key, String value) async => into(
    meta,
  ).insertOnConflictUpdate(MetaCompanion.insert(key: key, value: value));

  // -- Bookmarks CRUD --------------------------------------------------------

  Future<void> insertBookmark(BookmarksCompanion bookmark) async =>
      into(bookmarks).insert(bookmark);

  Future<List<Bookmark>> getBookmarksForBook(String bookId) async =>
      (select(bookmarks)
            ..where((t) => t.bookId.equals(bookId))
            ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
          .get();

  /// Every bookmark across all books, for library backup/restore.
  Future<List<Bookmark>> getAllBookmarks() async => (select(
    bookmarks,
  )..orderBy([(t) => OrderingTerm.desc(t.createdAt)])).get();

  Future<bool> bookmarkExists(String id) async =>
      await (select(bookmarks)
            ..where((t) => t.id.equals(id))
            ..limit(1))
          .getSingleOrNull() !=
      null;

  Future<bool> sessionExists(String bookId, int startedAt) async =>
      await (select(readingSessions)
            ..where(
              (t) => t.bookId.equals(bookId) & t.startedAt.equals(startedAt),
            )
            ..limit(1))
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
            ..where(
              (t) =>
                  t.bookId.equals(bookId) &
                  t.chapter.equals(chapter) &
                  t.offset.equals(offset),
            )
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

  Future<List<ReadingSession>> getAllSessions() async => (select(
    readingSessions,
  )..orderBy([(t) => OrderingTerm.desc(t.startedAt)])).get();

  Future<int> getTotalReadingTimeMs(String bookId) async {
    final result = await customSelect(
      'SELECT SUM(ended_at - started_at) AS total FROM reading_sessions '
      'WHERE book_id = ? AND ended_at > 0',
      variables: [Variable.withString(bookId)],
    ).get();
    return result.isNotEmpty ? result.first.read<int>('total') : 0;
  }

  Future<int> getTotalPagesRead(String bookId) async {
    final result = await customSelect(
      'SELECT SUM(pages) AS total FROM reading_sessions WHERE book_id = ?',
      variables: [Variable.withString(bookId)],
    ).get();
    return result.isNotEmpty ? result.first.read<int>('total') : 0;
  }

  /// Returns sessions grouped by day (epoch day) with total time in ms.
  Future<Map<int, int>> getDailyReadingTime() async {
    final results = await customSelect(
      'SELECT (started_at / 86400000) AS day, SUM(ended_at - started_at) AS total '
      'FROM reading_sessions WHERE ended_at > 0 GROUP BY day',
    ).get();
    return {for (final r in results) r.read<int>('day'): r.read<int>('total')};
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
    final results = await customSelect(
      'SELECT (started_at % 86400000) / 3600000 AS hour, SUM(ended_at - started_at) AS total '
      'FROM reading_sessions WHERE ended_at > 0 GROUP BY hour',
    ).get();
    return {for (final r in results) r.read<int>('hour'): r.read<int>('total')};
  }

  /// Returns reading time grouped by "YYYY-MM" key.
  Future<Map<String, int>> getMonthlyReadingTime() async {
    final results = await customSelect(
      "SELECT strftime('%Y-%m', started_at / 1000, 'unixepoch') AS month, "
      'SUM(ended_at - started_at) AS total '
      'FROM reading_sessions WHERE ended_at > 0 GROUP BY month',
    ).get();
    return {
      for (final r in results) r.read<String>('month'): r.read<int>('total'),
    };
  }

  /// Returns the longest single reading session in ms.
  Future<int> getLongestSessionMs() async {
    final result = await customSelect(
      'SELECT MAX(ended_at - started_at) AS longest FROM reading_sessions WHERE ended_at > 0',
    ).get();
    return result.isNotEmpty ? result.first.read<int>('longest') : 0;
  }

  /// Returns the average session duration in ms.
  Future<int> getAverageSessionMs() async {
    final result = await customSelect(
      'SELECT AVG(ended_at - started_at) AS avg FROM reading_sessions WHERE ended_at > 0',
    ).get();
    if (result.isEmpty) return 0;
    final avg = result.first.read<double>('avg');
    return avg.round();
  }

  /// Returns total reading time in ms for today.
  Future<int> getTodayReadingTimeMs() async {
    final todayEpoch = (DateTime.now().millisecondsSinceEpoch / 86400000)
        .floor();
    final result = await customSelect(
      'SELECT SUM(ended_at - started_at) AS total '
      'FROM reading_sessions '
      'WHERE ended_at > 0 AND (started_at / 86400000) = ?',
      variables: [Variable.withInt(todayEpoch)],
    ).get();
    return result.isNotEmpty ? result.first.read<int>('total') : 0;
  }

  /// Returns total reading time in ms for the last 7 days.
  Future<int> getThisWeekReadingTimeMs() async {
    final weekAgo = DateTime.now()
        .subtract(const Duration(days: 7))
        .millisecondsSinceEpoch;
    final result = await customSelect(
      'SELECT SUM(ended_at - started_at) AS total '
      'FROM reading_sessions '
      'WHERE ended_at > 0 AND started_at >= ?',
      variables: [Variable.withInt(weekAgo)],
    ).get();
    return result.isNotEmpty ? result.first.read<int>('total') : 0;
  }

  /// Returns per-book reading stats for all started books, sorted by time desc.
  Future<List<BookStats>> getPerBookStats(List<Book> books) async {
    final results = await customSelect(
      'SELECT book_id, SUM(ended_at - started_at) AS totalTime, '
      'SUM(pages) AS totalPages, COUNT(*) AS sessionCount '
      'FROM reading_sessions WHERE ended_at > 0 GROUP BY book_id',
    ).get();
    final statsByBook = <String, _PerBookAggregate>{};
    for (final r in results) {
      statsByBook[r.read<String>('book_id')] = _PerBookAggregate(
        totalTimeMs: r.read<int>('totalTime'),
        totalPages: r.read<int>('totalPages'),
        sessionCount: r.read<int>('sessionCount'),
      );
    }
    final bookList = <BookStats>[];
    for (final book in books) {
      if (!book.isStarted) continue;
      final agg = statsByBook[book.id];
      bookList.add(
        BookStats(
          book: book,
          totalTimeMs: agg?.totalTimeMs ?? 0,
          totalPages: agg?.totalPages ?? 0,
          sessionCount: agg?.sessionCount ?? 0,
        ),
      );
    }
    bookList.sort((a, b) => b.totalTimeMs.compareTo(a.totalTimeMs));
    return bookList;
  }

  // -- Collections CRUD ------------------------------------------------------

  Future<List<Collection>> getAllCollections() async =>
      (select(collections)..orderBy([(t) => OrderingTerm.asc(t.name)])).get();

  Future<void> insertCollection(CollectionsCompanion collection) async =>
      into(collections).insert(collection);

  Future<void> updateCollection(CollectionsCompanion collection) async =>
      (update(
        collections,
      )..where((t) => t.id.equals(collection.id.value))).write(collection);

  Future<void> deleteCollectionById(String id) async {
    await transaction(() async {
      await (delete(
        collectionBooks,
      )..where((t) => t.collectionId.equals(id))).go();
      await (delete(collections)..where((t) => t.id.equals(id))).go();
    });
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
    String collectionId,
    String bookId,
  ) async {
    await (delete(collectionBooks)..where(
          (t) => t.collectionId.equals(collectionId) & t.bookId.equals(bookId),
        ))
        .go();
  }

  Future<List<CollectionBook>> getBooksForCollection(
    String collectionId,
  ) async =>
      (select(collectionBooks)
            ..where((t) => t.collectionId.equals(collectionId))
            ..orderBy([(t) => OrderingTerm.asc(t.sortPosition)]))
          .get();

  Future<bool> isBookInCollection(String collectionId, String bookId) async =>
      await (select(collectionBooks)
            ..where(
              (t) =>
                  t.collectionId.equals(collectionId) & t.bookId.equals(bookId),
            )
            ..limit(1))
          .getSingleOrNull() !=
      null;

  Future<int> getCollectionBookCount(String collectionId) async {
    final count = collectionBooks.id.count();
    final result =
        await (selectOnly(collectionBooks)
              ..where(collectionBooks.collectionId.equals(collectionId))
              ..addColumns([count]))
            .getSingle();
    return result.read(count) ?? 0;
  }

  Future<List<Collection>> getCollectionsForBook(String bookId) async {
    final query = select(collections).join([
      innerJoin(
        collectionBooks,
        collectionBooks.collectionId.equalsExp(collections.id),
      ),
    ])..where(collectionBooks.bookId.equals(bookId));
    final rows = await query.get();
    return rows.map((row) => row.readTable(collections)).toList();
  }

  Future<List<CollectionBook>> getAllCollectionBooks() async =>
      select(collectionBooks).get();

  Future<void> updateCollectionBookSortPosition(
    int id,
    int sortPosition,
  ) async {
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
  metadataComplete: row.metadataComplete,
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
  metadataComplete: Value(book.metadataComplete),
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
  metadataComplete: Value(book.metadataComplete),
);

BooksCompanion positionToUpdate({
  required String id,
  required int lastChapter,
  required int lastOffset,
  required double progress,
  required int lastReadAt,
}) => BooksCompanion(
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
