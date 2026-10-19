import 'package:burrow/controllers/reader_selection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('beginWord then dragToWord forward keeps the anchor word', () {
    final s = ReaderSelection()..beginWord(4, 9);
    s.dragToWord(10, 17);
    expect(s.start, 4);
    expect(s.end, 17);
  });

  test('dragToWord before the anchor moves the start', () {
    final s = ReaderSelection()..beginWord(10, 17);
    s.dragToWord(0, 3);
    expect(s.start, 0);
    expect(s.end, 17);
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
