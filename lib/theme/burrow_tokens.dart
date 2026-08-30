import 'package:flutter/material.dart';

import '../models/book.dart';

/// burrow design tokens — Material 3 Expressive.
///
/// One place for the shape scale, format tonal roles and layout constants so
/// screens stay coherent instead of drifting into uniform radii everywhere.
abstract final class Burrow {
  // -- Shape scale (deliberately non-uniform across component classes) ------
  /// Extra-small: progress-bar tracks, format badges, small pills.
  static const double shapeXs = 6;

  /// Small: filter chips, menu items.
  static const double shapeSm = 12;

  /// Medium: grid book cards, list tiles.
  static const double shapeMd = 16;

  /// Large: Continue Reading hero card, FAB, search field.
  static const double shapeLg = 28;

  /// Extra-large: bottom sheets (book details, import options).
  static const double shapeXl = 32;

  static BorderRadius r(double radius) => BorderRadius.circular(radius);

  // -- Covers ----------------------------------------------------------------
  /// Every cover renders as a 2:3 portrait book frame.
  static const double coverAspectRatio = 2 / 3;

  // -- Layout -----------------------------------------------------------------
  static const double fabHeight = 60;
  static const double fabMargin = 16;

  /// Minimum bottom inset any scrolling content must reserve so the docked
  /// FAB never overlaps the last row of cards.
  static const double fabClearance = fabHeight + fabMargin + 28;

  // -- Format tonal roles -----------------------------------------------------
  ///
  /// Badges are tonal chips keyed to the earthy palette, not flat black
  /// rectangles. EPUB rides the brand's green container; TXT and PDF get
  /// sibling ochre/clay pairs tuned for AA contrast in both modes.
  static (Color bg, Color fg) formatTonal(
    ColorScheme scheme,
    BookFormat format,
  ) =>
      switch (format) {
        BookFormat.epub => (scheme.primaryContainer, scheme.onPrimaryContainer),
        BookFormat.txt => (
            scheme.brightness == Brightness.light
                ? const Color(0xFFFFE3BC)
                : const Color(0xFF503B14),
            scheme.brightness == Brightness.light
                ? const Color(0xFF5A421A)
                : const Color(0xFFFFDDA4),
          ),
        BookFormat.pdf => (
            scheme.brightness == Brightness.light
                ? const Color(0xFFFFDACF)
                : const Color(0xFF5A2117),
            scheme.brightness == Brightness.light
                ? const Color(0xFF66241A)
                : const Color(0xFFFFB5A1),
          ),
      };
}
