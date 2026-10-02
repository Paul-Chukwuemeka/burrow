import 'package:burrow/controllers/book_selection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('enter starts selection with one id', () {
    final s = BookSelection();
    s.enter('a');
    expect(s.isSelecting, isTrue);
    expect(s.selectedIds, {'a'});
  });

  test('toggle adds then removes', () {
    final s = BookSelection();
    s.enter('a');
    s.toggle('b');
    expect(s.selectedIds, {'a', 'b'});
    s.toggle('a');
    expect(s.selectedIds, {'b'});
  });

  test('toggle last id exits selection', () {
    final s = BookSelection();
    s.enter('a');
    s.toggle('a');
    expect(s.isSelecting, isFalse);
    expect(s.selectedIds, isEmpty);
  });

  test('selectAll + clear', () {
    final s = BookSelection();
    s.selectAll(['a', 'b', 'c']);
    expect(s.count, 3);
    s.clear();
    expect(s.isSelecting, isFalse);
  });

  test('toggle unknown id is a no-op add (by design)', () {
    final s = BookSelection();
    s.toggle('zzz');
    expect(s.selectedIds, {'zzz'});
  });
}
