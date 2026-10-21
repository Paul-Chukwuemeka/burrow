// Confirms what "Recent" sorts by.
//
// LibraryService.sorted (the library screen's Recent mode):
//   1. any book with lastReadAt > 0 always out-ranks a never-read book,
//      no matter how old or how it was imported;
//   2. among read books, higher lastReadAt (more recently read) first;
//   3. tie-break is addedAt descending (newest import first).
// lastReadAt is written by savePosition() every time the reader saves a
// reading position, so "Recent" = the most recently touched reading spot.
import 'package:burrow/models/book.dart';
import 'package:burrow/services/library_service.dart';
import 'package:flutter_test/flutter_test.dart';

Book _book(String id, {required int addedAt, required int lastReadAt}) => Book(
      id: id,
      title: 'Book $id',
      author: '',
      path: '/tmp/recent-$id.epub',
      format: BookFormat.epub,
      addedAt: addedAt,
      lastReadAt: lastReadAt,
    );

void main() {
  test('sorted: read books first by lastReadAt desc, unread after newest-imports', () {
    final lib = LibraryService()
      ..debugAddAll([
        // Deliberately declared in reverse so the comparator must do work.
        _book('unread-old-import', addedAt: 1, lastReadAt: 0),
        _book('mid', addedAt: 9, lastReadAt: 100), // newer import, older read
        _book('unread-new-import', addedAt: 5, lastReadAt: 0),
        _book('fresh', addedAt: 2, lastReadAt: 800), // older import, newest read
        _book('older-read', addedAt: 3, lastReadAt: 500),
      ]);

    final order = lib.sorted.map((b) => b.id).toList();

    // Read books, most recently read first.
    expect(order.indexOf('fresh'), lessThan(order.indexOf('older-read')));
    expect(order.indexOf('older-read'), lessThan(order.indexOf('mid')));
    // Read books rank above both unread books — never-read goes last.
    expect(order.indexOf('mid'), lessThan(order.indexOf('unread-new-import')));
    expect(order.indexOf('mid'), lessThan(order.indexOf('unread-old-import')));
    // Unread books tie on lastReadAt (0) → addedAt descending.
    expect(
      order.indexOf('unread-new-import'),
      lessThan(order.indexOf('unread-old-import')),
    );
    expect(lib.mostRecent?.id, 'fresh');
  });

  test('new read stamps jump a book to the top of Recent', () async {
    final lib = LibraryService()
      ..debugAddAll([
        _book('a', addedAt: 1, lastReadAt: 900),
        _book('b', addedAt: 2, lastReadAt: 0),
      ]);
    expect(lib.sorted.first.id, 'a');

    // Resuming/staging progress on 'b' stamps its lastReadAt via savePosition
    // (no database in unit tests, so the in-memory book is the whole world).
    await lib.savePosition(id: 'b', chapter: 0, offset: 0, progress: 0.01);

    expect(lib.sorted.first.id, 'b');
  });
}
