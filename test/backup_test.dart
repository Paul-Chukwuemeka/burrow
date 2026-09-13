import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:burrow/db/database.dart';
import 'package:burrow/models/book.dart';
import 'package:burrow/services/library_service.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.documentsPath);
  final String documentsPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => documentsPath;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late AppDatabase db;
  late LibraryService service;

  setUpAll(() {
    tempDir = Directory.systemTemp.createTempSync('burrow_backup_test');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
  });

  tearDownAll(() {
    tempDir.deleteSync(recursive: true);
  });

  Book seedBook(String id) => Book(
        id: id,
        title: 'Book $id',
        author: 'Author $id',
        path: '/tmp/$id.epub',
        format: BookFormat.epub,
        addedAt: 1000,
        lastReadAt: 2000,
        progress: 0.5,
        lastChapter: 3,
        lastOffset: 42,
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
    service = LibraryService();
    service.debugAttachDatabase(db);

    await db.insertBook(bookToCompanion(seedBook('book1')));
    await db.insertBook(bookToCompanion(seedBook('book2')));
    await db.insertBookmark(BookmarksCompanion.insert(
      id: 'bm1',
      bookId: 'book1',
      chapter: 1,
      offset: 99,
      snippet: Value('somewhere in the text'),
      createdAt: 1234,
    ));
    await db.insertSession(ReadingSessionsCompanion.insert(
      bookId: 'book1',
      startedAt: 5000,
      endedAt: Value(6000),
      pages: Value(12),
    ));

    await service.load();
  });

  tearDown(() async {
    await db.close();
  });

  group('Library backup', () {
    test('export writes JSON containing books, bookmarks and sessions',
        () async {
      final path = await service.exportLibrary();

      expect(File(path).existsSync(), isTrue);
      final map =
          jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
      expect(map['format'], 'burrow-backup');
      expect((map['books'] as List).length, 2);
      expect((map['bookmarks'] as List).length, 1);
      expect((map['sessions'] as List).length, 1);
      final bm = (map['bookmarks'] as List).single;
      expect(bm['bookId'], 'book1');
      expect(bm['snippet'], 'somewhere in the text');
    });

    test('restore imports books, bookmarks and sessions into a fresh library',
        () async {
      final backupPath = await service.exportLibrary();

      // Fresh database + service, like a new device.
      final freshDb = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(freshDb.close);
      final fresh = LibraryService();
      fresh.debugAttachDatabase(freshDb);

      final count = await fresh.importLibrary(backupPath);
      expect(count, 2);
      expect(fresh.books.length, 2);

      final restored = fresh.books.firstWhere((b) => b.id == 'book1');
      expect(restored.title, 'Book book1');
      expect(restored.progress, 0.5);
      expect(restored.lastChapter, 3);

      final bookmarks = await freshDb.getBookmarksForBook('book1');
      expect(bookmarks.length, 1);
      expect(bookmarks.first.snippet, 'somewhere in the text');

      final sessions = await freshDb.getSessionsForBook('book1');
      expect(sessions.length, 1);
      expect(sessions.first.startedAt, 5000);
      expect(sessions.first.pages, 12);
    });

    test('restoring the same backup twice does not duplicate anything',
        () async {
      final backupPath = await service.exportLibrary();

      final freshDb = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(freshDb.close);
      final fresh = LibraryService();
      fresh.debugAttachDatabase(freshDb);

      expect(await fresh.importLibrary(backupPath), 2);
      expect(await fresh.importLibrary(backupPath), 0);
      expect(await fresh.importLibrary(backupPath), 0);

      expect(fresh.books.length, 2);
      expect(await freshDb.getBookmarksForBook('book1').then((l) => l.length),
          1);
      expect(await freshDb.getSessionsForBook('book1').then((l) => l.length),
          1);
    });

    test('import rejects files that are not Burrow backups', () async {
      final bad = File('${tempDir.path}/not-a-backup.json')
        ..writeAsStringSync('{"hello": "world"}');

      expect(
        () => service.importLibrary(bad.path),
        throwsFormatException,
      );
    });

    test('import rejects books with path traversal in their paths', () async {
      final beforeCount = service.books.length;
      final crafted = {
        'format': 'burrow-backup',
        'version': 2,
        'books': [
          {
            'id': 'evil1',
            'title': 'Traversal',
            'author': '',
            'path': '/foo/../../etc/passwd',
            'format': 'pdf',
            'addedAt': 1000,
          },
          {
            'id': 'evil2',
            'title': 'Dots',
            'author': '',
            'path': '../relative/book.epub',
            'format': 'epub',
            'addedAt': 1000,
          },
        ],
      };
      final f = File('${tempDir.path}/traversal.json')
        ..writeAsStringSync(jsonEncode(crafted));

      final count = await service.importLibrary(f.path);
      expect(count, 0);
      expect(service.books.length, beforeCount);
    });

    test('import accepts paths with ".." inside a directory name', () async {
      final beforeCount = service.books.length;
      final crafted = {
        'format': 'burrow-backup',
        'version': 2,
        'books': [
          {
            'id': 'good1',
            'title': 'The..Theory',
            'author': '',
            'path': '/sdcard/books/The..Theory/book.epub',
            'format': 'epub',
            'addedAt': 1000,
          },
        ],
      };
      final f = File('${tempDir.path}/good-traversal.json')
        ..writeAsStringSync(jsonEncode(crafted));

      final count = await service.importLibrary(f.path);
      expect(count, 1);
      expect(service.books.length, beforeCount + 1);
      final imported =
          service.books.firstWhere((b) => b.id == 'good1');
      expect(imported.path, '/sdcard/books/The..Theory/book.epub');
    });
  });
}
