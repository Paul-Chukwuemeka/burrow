import 'package:burrow/controllers/comic_controller.dart';
import 'package:burrow/models/book.dart';
import 'package:burrow/models/reader_settings.dart';
import 'package:burrow/services/library_service.dart';
import 'package:flutter_test/flutter_test.dart';

Book _comic() => Book(
  id: 'c1',
  title: 'Comic',
  author: '',
  path: '/tmp/c.cbz',
  format: BookFormat.cbz,
  addedAt: 1,
);

void main() {
  test('notePageChanged records a flip', () {
    var flips = 0;
    final ctrl = ComicReaderController(
      book: _comic(),
      settings: ReaderSettings(),
      library: LibraryService(),
      onPageFlipped: () => flips++,
    );

    ctrl.notePageChanged(3);

    expect(ctrl.comicPage, 3);
    expect(flips, 1);
    ctrl.dispose();
  });
}
