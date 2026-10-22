import 'package:burrow/controllers/search_controller.dart';
import 'package:burrow/models/book.dart';
import 'package:burrow/models/document.dart';
import 'package:flutter_test/flutter_test.dart';

ReaderSearchController makeController() {
  return ReaderSearchController(
    book: Book(
      id: 'book',
      title: 'Title',
      author: 'Author',
      path: '/tmp/book.epub',
      format: BookFormat.epub,
      addedAt: 0,
    ),
  );
}

void main() {
  group('ReaderSearchController', () {
    test('clearing text cancels a pending debounced scan', () async {
      final ctrl = makeController();
      ctrl.setChapters([for (var i = 0; i < 3; i++) Chapter('c$i', 'hello')]);

      ctrl.searchController.text = 'hello';
      ctrl.onSearchTextChanged();
      ctrl.searchController.text = '';
      ctrl.onSearchTextChanged();

      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(ctrl.searchResults, isEmpty);
      expect(ctrl.bookSearch!.allResults, isEmpty);

      ctrl.dispose();
    });

    test('clearing text cancels an in-flight scan', () async {
      final ctrl = makeController();
      ctrl.setChapters([
        for (var i = 0; i < 40; i++) Chapter('c$i', 'hello ' * 200),
      ]);

      ctrl.searchController.text = 'hello';
      ctrl.onSearchTextChanged();
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(ctrl.searchResults, isNotEmpty);

      ctrl.searchController.text = '';
      ctrl.onSearchTextChanged();

      expect(ctrl.bookSearch!.allResults, isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(ctrl.searchResults, isEmpty);

      ctrl.dispose();
    });

    test('a new query clears stale results immediately', () async {
      final ctrl = makeController();
      ctrl.setChapters([Chapter('c', 'hello world hello')]);

      ctrl.searchController.text = 'hello';
      ctrl.onSearchTextChanged();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(ctrl.searchResults, isNotEmpty);

      ctrl.searchController.text = 'world';
      ctrl.onSearchTextChanged();

      expect(ctrl.searchResults, isEmpty);
      expect(ctrl.currentResultIndex, -1);

      ctrl.dispose();
    });

    test('does not select a result before the reader jumps to one', () async {
      final ctrl = makeController();
      ctrl.setChapters([Chapter('c', 'hello world hello')]);

      ctrl.searchController.text = 'hello';
      ctrl.onSearchTextChanged();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(ctrl.searchResults.length, 2);

      expect(ctrl.currentResultIndex, -1);
      ctrl.nextResult();
      expect(ctrl.currentResultIndex, 0);

      ctrl.dispose();
    });

    test('exposes truncation from the underlying search', () async {
      final ctrl = makeController();
      ctrl.setChapters([Chapter('c', 'x ' * 600)]);

      ctrl.searchController.text = 'x';
      ctrl.onSearchTextChanged();

      await Future<void>.delayed(const Duration(milliseconds: 450));

      expect(ctrl.searchResults.length, 500);
      expect(ctrl.isTruncated, isTrue);

      ctrl.dispose();
    });
  });
}
