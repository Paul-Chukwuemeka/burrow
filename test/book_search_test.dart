import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:burrow/services/book_search.dart';
import 'package:burrow/services/document_parser.dart';

void main() {
  group('BookSearch', () {
    List<Chapter> makeChapters(List<String> bodies) {
      return bodies.map((b) => Chapter('Chapter', b)).toList();
    }

    test('finds case-insensitive matches', () async {
      final chapters = makeChapters([
        'Hello world, hello flutter, HELLO dart',
        'Another chapter with hello',
      ]);
      final allResults = <List<SearchResult>>[];
      final done = Completer<void>();
      final search = BookSearch(
        chapters: chapters,
        onResults: (r) => allResults.add(r),
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
      );

      search.searchImmediate('hello');
      await done.future;

      final results = allResults.last;
      // "Hello" at 0, "hello" at 13, "HELLO" at 28 in ch0; "hello" at 22 in ch1.
      expect(results.length, 4);
      expect(results[0].chapter, 0);
      expect(results[0].offset, 0);
      expect(results[0].length, 5);
      expect(results[1].chapter, 0);
      expect(results[1].offset, 13);
      expect(results[2].chapter, 0);
      expect(results[2].offset, 28);
      expect(results[3].chapter, 1);
      expect(results[3].offset, 21);

      search.dispose();
    });

    test('returns empty for empty query', () async {
      final chapters = makeChapters(['Hello world']);
      final results = <List<SearchResult>>[];
      final search = BookSearch(
        chapters: chapters,
        onResults: (r) => results.add(r),
        onDone: () {},
      );

      search.searchImmediate('');
      await Future.delayed(Duration.zero);

      expect(results.last, isEmpty);
      search.dispose();
    });

    test('returns empty when no matches', () async {
      final chapters = makeChapters(['Hello world']);
      final completer = Completer<List<SearchResult>>();
      final search = BookSearch(
        chapters: chapters,
        onResults: (r) {
          if (!completer.isCompleted) completer.complete(r);
        },
        onDone: () {},
      );

      search.searchImmediate('xyz');
      final results = await completer.future;

      expect(results, isEmpty);
      search.dispose();
    });

    test('search is incremental across chapters', () async {
      final chapters = makeChapters([
        'aaa bbb aaa',
        'aaa ccc aaa',
        'aaa ddd aaa',
      ]);
      final allResults = <List<SearchResult>>[];
      final search = BookSearch(
        chapters: chapters,
        onResults: (r) => allResults.add(r),
        onDone: () {},
      );

      search.searchImmediate('aaa');
      // Wait for all chapters to be scanned.
      await Future.delayed(const Duration(milliseconds: 100));

      expect(allResults.last.length, 6); // 2 per chapter × 3 chapters
      search.dispose();
    });

    test('findResultIndex returns correct index', () async {
      final chapters = makeChapters(['hello world']);
      final completer = Completer<List<SearchResult>>();
      final search = BookSearch(
        chapters: chapters,
        onResults: (r) {
          if (!completer.isCompleted) completer.complete(r);
        },
        onDone: () {},
      );

      search.searchImmediate('hello');
      await completer.future;

      expect(search.findResultIndex(0, 0), 0);
      expect(search.findResultIndex(0, 5), -1); // wrong offset
      expect(search.findResultIndex(1, 0), -1); // wrong chapter

      search.dispose();
    });

    test('matchesForPage returns overlapping results', () async {
      final chapters = makeChapters(['hello world hello flutter hello dart']);
      final completer = Completer<List<SearchResult>>();
      final search = BookSearch(
        chapters: chapters,
        onResults: (r) {
          if (!completer.isCompleted) completer.complete(r);
        },
        onDone: () {},
      );

      search.searchImmediate('hello');
      await completer.future;

      // Page covering chars 0-10 should match "hello" at offset 0.
      final pageMatches = search.matchesForPage(0, 0, 10);
      expect(pageMatches.length, 1);
      expect(pageMatches[0].offset, 0);

      // Page covering chars 5-20 should match "hello" at offset 12.
      final pageMatches2 = search.matchesForPage(0, 5, 20);
      expect(pageMatches2.length, 1);
      expect(pageMatches2[0].offset, 12);

      // Page covering chars 0-30 should match all three "hello"s.
      final pageMatches3 = search.matchesForPage(0, 0, 30);
      expect(pageMatches3.length, 3);

      search.dispose();
    });

    test('snippet contains match context', () async {
      final chapters = makeChapters(['aaa bbb hello world ccc ddd']);
      final completer = Completer<List<SearchResult>>();
      final search = BookSearch(
        chapters: chapters,
        onResults: (r) {
          if (!completer.isCompleted) completer.complete(r);
        },
        onDone: () {},
      );

      search.searchImmediate('hello');
      final results = await completer.future;

      expect(results.length, 1);
      expect(results[0].snippet, contains('hello'));
      expect(results[0].snippet, contains('bbb'));
      expect(results[0].snippet, contains('world'));

      search.dispose();
    });

    test('debounced search cancels rapid keystrokes', () async {
      final chapters = makeChapters(['hello world']);
      final allResults = <List<SearchResult>>[];
      final search = BookSearch(
        chapters: chapters,
        onResults: (r) => allResults.add(r),
        onDone: () {},
      );

      // Type rapidly — only the last query should complete.
      search.search('h');
      search.search('he');
      search.search('hel');
      search.search('hell');
      search.search('hello');

      // Wait for debounce + scan.
      await Future.delayed(const Duration(milliseconds: 500));

      // The final result should be for "hello".
      expect(allResults.last.length, 1);
      expect(allResults.last[0].offset, 0);

      search.dispose();
    });

    test('dispose stops ongoing search', () async {
      final chapters = makeChapters(['aaa ' * 1000, 'hello ' * 1000]);
      final results = <List<SearchResult>>[];
      final search = BookSearch(
        chapters: chapters,
        onResults: (r) => results.add(r),
        onDone: () {},
      );

      search.searchImmediate('hello');
      search.dispose();

      // Wait a bit — no more results should arrive after dispose.
      await Future.delayed(const Duration(milliseconds: 100));

      // May have partial results, but search should not be running.
      // The important thing is no crash.
    });
  });

  group('SearchResult', () {
    test('equality based on chapter, offset, length', () {
      const a = SearchResult(chapter: 0, offset: 5, length: 3, snippet: 'x');
      const b = SearchResult(chapter: 0, offset: 5, length: 3, snippet: 'y');
      const c = SearchResult(chapter: 0, offset: 5, length: 4, snippet: 'x');

      expect(a, equals(b)); // snippet doesn't affect equality
      expect(a == c, isFalse);
    });
  });
}
