import 'package:flutter/material.dart';

/// Fixed highlight palette. The stored value is the index into this list.
const int kHighlightColorCount = 5;

const List<Color> kHighlightColors = [
  Color(0xFFFFD54F), // amber
  Color(0xFF81C784), // green
  Color(0xFF64B5F6), // blue
  Color(0xFFF06292), // pink
  Color(0xFFBA68C8), // purple
];

const List<String> kHighlightColorNames = [
  'Amber',
  'Green',
  'Blue',
  'Pink',
  'Purple',
];

/// A highlight range clipped to one chapter, ready to paint.
typedef HighlightSlice = ({int start, int end, int color});

/// Background colour for a stored palette [index], clamped into the palette.
Color highlightBackground(int index, {required bool dark}) {
  final color = kHighlightColors[index.clamp(0, kHighlightColorCount - 1)];
  return color.withValues(alpha: dark ? 0.28 : 0.35);
}
