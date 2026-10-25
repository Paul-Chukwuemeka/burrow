import 'package:burrow/controllers/reader_selection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('dragToOffset extends forward to the exact character', () {
    final s = ReaderSelection()..beginWord(4, 9);
    s.dragToOffset(12); // three characters into the next word
    expect(s.start, 4);
    expect(s.end, 12);
  });

  test('dragToOffset before the anchor moves the start to the character', () {
    final s = ReaderSelection()..beginWord(10, 17);
    s.dragToOffset(5);
    expect(s.start, 5);
    expect(s.end, 17);
  });

  test('dragToOffset inside the anchor word keeps the whole word', () {
    final s = ReaderSelection()..beginWord(4, 9);
    s.dragToOffset(7);
    expect(s.start, 4);
    expect(s.end, 9);
  });

  test('dragToOffset without an anchor does nothing', () {
    final s = ReaderSelection();
    s.dragToOffset(5);
    expect(s.isActive, isFalse);
  });

  test('setStart/setEnd keep start < end', () {
    final s = ReaderSelection()..beginWord(4, 9);
    s.setStart(8); // clamped to 8, which is < 9
    expect(s.start, 8);
    s.setEnd(2); // clamps to start + 1
    expect(s.end, 9); // caller is expected to word-snap; model never crosses
  });

  test('clear notifies and empties', () {
    var notified = 0;
    final s = ReaderSelection()..addListener(() => notified++);
    s.beginWord(0, 3);
    s.clear();
    expect(s.isActive, isFalse);
    expect(notified, 2);
  });
}
