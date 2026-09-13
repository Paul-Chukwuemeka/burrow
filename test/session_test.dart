import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:burrow/db/database.dart';
import 'package:burrow/models/book.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  group('Reading sessions', () {
    test('insert and retrieve sessions', () async {
      // First insert a book so the FK constraint is satisfied.
      await db.insertBook(
        BooksCompanion.insert(
          id: 'book1',
          title: 'Test Book',
          path: '/test.epub',
          format: BookFormat.epub,
          addedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );

      final id = await db.insertSession(
        ReadingSessionsCompanion.insert(bookId: 'book1', startedAt: 1000),
      );

      expect(id, greaterThan(0));

      final sessions = await db.getSessionsForBook('book1');
      expect(sessions.length, 1);
      expect(sessions.first.bookId, 'book1');
      expect(sessions.first.startedAt, 1000);
      expect(sessions.first.endedAt, 0);
      expect(sessions.first.pages, 0);
    });

    test('endSession sets endedAt and pages', () async {
      await db.insertBook(
        BooksCompanion.insert(
          id: 'book1',
          title: 'Test Book',
          path: '/test.epub',
          format: BookFormat.epub,
          addedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );

      final id = await db.insertSession(
        ReadingSessionsCompanion.insert(bookId: 'book1', startedAt: 1000),
      );

      await db.endSession(id, pages: 42);

      final sessions = await db.getSessionsForBook('book1');
      expect(sessions.first.endedAt, greaterThan(0));
      expect(sessions.first.pages, 42);
    });

    test('getAllSessions returns all sessions', () async {
      await db.insertBook(
        BooksCompanion.insert(
          id: 'book1',
          title: 'Test Book',
          path: '/test.epub',
          format: BookFormat.epub,
          addedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      await db.insertBook(
        BooksCompanion.insert(
          id: 'book2',
          title: 'Another Book',
          path: '/test2.epub',
          format: BookFormat.epub,
          addedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );

      await db.insertSession(
        ReadingSessionsCompanion.insert(bookId: 'book1', startedAt: 1000),
      );
      await db.insertSession(
        ReadingSessionsCompanion.insert(bookId: 'book2', startedAt: 2000),
      );

      final all = await db.getAllSessions();
      expect(all.length, 2);
    });

    test('getTotalReadingTimeMs sums session durations', () async {
      await db.insertBook(
        BooksCompanion.insert(
          id: 'book1',
          title: 'Test Book',
          path: '/test.epub',
          format: BookFormat.epub,
          addedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );

      // Session 1: 1000ms to 2000ms = 1000ms
      final id1 = await db.insertSession(
        ReadingSessionsCompanion.insert(bookId: 'book1', startedAt: 1000),
      );
      await db.endSession(id1, pages: 10, endedAt: 2000);

      // Session 2: 3000ms to 5000ms = 2000ms
      final id2 = await db.insertSession(
        ReadingSessionsCompanion.insert(bookId: 'book1', startedAt: 3000),
      );
      await db.endSession(id2, pages: 20, endedAt: 5000);

      final totalMs = await db.getTotalReadingTimeMs('book1');
      expect(totalMs, 3000);
    });

    test('getTotalPagesRead sums pages', () async {
      await db.insertBook(
        BooksCompanion.insert(
          id: 'book1',
          title: 'Test Book',
          path: '/test.epub',
          format: BookFormat.epub,
          addedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );

      final id1 = await db.insertSession(
        ReadingSessionsCompanion.insert(bookId: 'book1', startedAt: 1000),
      );
      await db.endSession(id1, pages: 15);

      final id2 = await db.insertSession(
        ReadingSessionsCompanion.insert(bookId: 'book1', startedAt: 2000),
      );
      await db.endSession(id2, pages: 25);

      final total = await db.getTotalPagesRead('book1');
      expect(total, 40);
    });

    test('getDailyReadingTime groups by day', () async {
      await db.insertBook(
        BooksCompanion.insert(
          id: 'book1',
          title: 'Test Book',
          path: '/test.epub',
          format: BookFormat.epub,
          addedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );

      // Session on today, started just before it ends so the duration is
      // always positive regardless of the wall-clock time the test runs at.
      final now = DateTime.now().millisecondsSinceEpoch;
      final id1 = await db.insertSession(
        ReadingSessionsCompanion.insert(bookId: 'book1', startedAt: now),
      );
      await db.endSession(id1, pages: 5, endedAt: now + 1000);

      final daily = await db.getDailyReadingTime();
      expect(daily.length, 1);
      expect(daily.values.first, greaterThan(0));
    });

    test('getReadingStreak counts consecutive days', () async {
      await db.insertBook(
        BooksCompanion.insert(
          id: 'book1',
          title: 'Test Book',
          path: '/test.epub',
          format: BookFormat.epub,
          addedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );

      // Create a session for today, started just before it ends.
      final now = DateTime.now().millisecondsSinceEpoch;
      final id1 = await db.insertSession(
        ReadingSessionsCompanion.insert(bookId: 'book1', startedAt: now),
      );
      await db.endSession(id1, pages: 5, endedAt: now + 1000);

      // Create a session for yesterday.
      final yesterdayStart = now - 86400000;
      final id2 = await db.insertSession(
        ReadingSessionsCompanion.insert(
          bookId: 'book1',
          startedAt: yesterdayStart,
        ),
      );
      await db.endSession(id2, pages: 3, endedAt: yesterdayStart + 1000);

      final streak = await db.getReadingStreak();
      expect(streak, 2);
    });

    test('getReadingStreak is 0 when no sessions', () async {
      final streak = await db.getReadingStreak();
      expect(streak, 0);
    });
  });
}
