import 'package:burrow/screens/reader_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fillOrderFor walks forward from the anchor, then backward', () {
    expect(fillOrderFor(6, 2), [2, 3, 4, 5, 1, 0]);
  });

  test('fillOrderFor covers every chapter once from the anchor', () {
    expect(fillOrderFor(4, 0), [0, 1, 2, 3]);
    expect(fillOrderFor(4, 3), [3, 2, 1, 0]);
  });
}
