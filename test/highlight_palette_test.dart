import 'package:burrow/models/highlight_palette.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('palette and names have five entries', () {
    expect(kHighlightColors, hasLength(kHighlightColorCount));
    expect(kHighlightColorNames, hasLength(kHighlightColorCount));
    expect(kHighlightColorCount, 5);
  });

  test('highlightBackground clamps a negative index', () {
    final color = highlightBackground(-1, dark: false);
    expect(color.r, kHighlightColors.first.r);
    expect(color.g, kHighlightColors.first.g);
    expect(color.b, kHighlightColors.first.b);
  });

  test('highlightBackground clamps an oversized index', () {
    final color = highlightBackground(99, dark: false);
    expect(color.r, kHighlightColors.last.r);
    expect(color.g, kHighlightColors.last.g);
    expect(color.b, kHighlightColors.last.b);
  });

  test('uses light and dark alphas', () {
    expect(highlightBackground(0, dark: false).a, closeTo(0.35, 0.001));
    expect(highlightBackground(0, dark: true).a, closeTo(0.28, 0.001));
  });
}
