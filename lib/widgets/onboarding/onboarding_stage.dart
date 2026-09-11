import 'package:flutter/material.dart';

import '../../models/reader_settings.dart';

class StageSpec {
  const StageSpec({
    required this.w,
    required this.h,
    required this.radius,
    required this.bg,
    required this.fg,
    required this.icon,
  });

  final double w;
  final double h;
  final double radius;
  final Color bg;
  final Color fg;
  final IconData icon;
}

StageSpec specFor(ColorScheme s, int i) => switch (i) {
      0 => StageSpec(
          w: 210, h: 210, radius: 74,
          bg: s.primaryContainer, fg: s.onPrimaryContainer,
          icon: Icons.auto_stories_outlined),
      1 => StageSpec(
          w: 168, h: 134, radius: 32,
          bg: s.secondaryContainer, fg: s.onSecondaryContainer,
          icon: Icons.folder_open_rounded),
      2 => StageSpec(
          w: 152, h: 152, radius: 28,
          bg: s.tertiaryContainer, fg: s.onTertiaryContainer,
          icon: Icons.tune_rounded),
      3 => StageSpec(
          w: 152, h: 152, radius: 28,
          bg: s.primaryContainer, fg: s.onPrimaryContainer,
          icon: Icons.menu_book_rounded),
      _ => StageSpec(
          w: 174, h: 152, radius: 30,
          bg: s.secondaryContainer, fg: s.onSecondaryContainer,
          icon: Icons.layers_outlined),
    };

/// The shared-element "den": one container that morphs its size, shape and
/// fill between pages so the flow reads as a single object travelling
/// through (den → folder → book → pages → shelf).
Widget buildStage(BuildContext context, int i, {
  bool showPermissionCheck = false,
  bool showScanCheck = false,
}) {
  final scheme = Theme.of(context).colorScheme;
  final s = specFor(scheme, i);
  return AnimatedContainer(
    duration: const Duration(milliseconds: 540),
    curve: Easing.emphasizedDecelerate,
    width: s.w,
    height: s.h,
    decoration: ShapeDecoration(
      color: s.bg,
      shape: RoundedSuperellipseBorder(
        borderRadius: BorderRadius.circular(s.radius),
      ),
    ),
    child: Stack(
      alignment: Alignment.center,
      children: [
        if (i == 0)
          _denGraphic(scheme)
        else
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: Icon(
              s.icon,
              key: ValueKey(s.icon),
              size: s.w * 0.42,
              color: s.fg,
            ),
          ),
        if (showScanCheck)
          Positioned(
            right: 6,
            bottom: 6,
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: scheme.primary,
                shape: BoxShape.circle,
                border: Border.all(color: scheme.surface, width: 3),
              ),
              child: Icon(Icons.check_rounded, size: 20, color: scheme.onPrimary),
            ),
          ),
        if (showPermissionCheck)
          Positioned(
            right: 6,
            bottom: 6,
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: scheme.primary,
                shape: BoxShape.circle,
                border: Border.all(color: scheme.surface, width: 3),
              ),
              child: Icon(Icons.check_rounded, size: 20, color: scheme.onPrimary),
            ),
          ),
      ],
    ),
  );
}

/// A page curled into a den: sepia page resting inside a moss ring, with a
/// warm lamp dot — "burrowing into a book".
Widget _denGraphic(ColorScheme scheme) {
  final sepia = ReaderTheme.sepia;
  return Stack(
    alignment: Alignment.center,
    children: [
      Transform.rotate(
        angle: -0.07,
        child: Container(
          width: 118,
          height: 172,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: sepia.background,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: sepia.muted.withValues(alpha: 0.4)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 7,
                decoration: BoxDecoration(
                  color: sepia.muted.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(3.5),
                ),
              ),
              const SizedBox(height: 10),
              for (final w in [72.0, 80.0, 66.0, 74.0, 58.0]) ...[
                Container(
                  width: w,
                  height: 5,
                  decoration: BoxDecoration(
                    color: sepia.text.withValues(alpha: 0.22),
                    borderRadius: BorderRadius.circular(2.5),
                  ),
                ),
                const SizedBox(height: 6),
              ],
              const Spacer(),
              Container(
                width: 54,
                height: 5,
                decoration: BoxDecoration(
                  color: sepia.accent,
                  borderRadius: BorderRadius.circular(2.5),
                ),
              ),
            ],
          ),
        ),
      ),
      Positioned(
        right: 10,
        bottom: 16,
        child: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(color: scheme.tertiary, shape: BoxShape.circle),
          child: Icon(
            Icons.bedtime_rounded,
            size: 16,
            color: scheme.onTertiary,
          ),
        ),
      ),
    ],
  );
}
