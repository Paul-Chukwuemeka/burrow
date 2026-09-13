import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Material 3 Expressive inspired reading-progress bar.
///
/// A smooth, fully-rounded linear progress indicator with a thick track.
/// The fill animates from zero on first build (emphasized decelerate).
class SegmentedProgressBar extends StatelessWidget {
  const SegmentedProgressBar({
    super.key,
    required this.value,
    required this.track,
    required this.fill,
    this.height = 6,
    this.animate = true,
  });

  /// 0..1
  final double value;
  final Color track;
  final Color fill;
  final double height;

  /// Set false inside continuously-animating parents to avoid re-tweening.
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final clamped = value.clamp(0.0, 1.0);
    return TweenAnimationBuilder<double>(
      tween: Tween(end: clamped),
      duration: animate ? const Duration(milliseconds: 600) : Duration.zero,
      curve: Easing.emphasizedDecelerate,
      builder: (context, animated, _) => CustomPaint(
        size: Size.fromHeight(height),
        painter: _ProgressBarPainter(value: animated, track: track, fill: fill),
      ),
    );
  }
}

class _ProgressBarPainter extends CustomPainter {
  _ProgressBarPainter({
    required this.value,
    required this.track,
    required this.fill,
  });

  final double value;
  final Color track;
  final Color fill;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = ui.Radius.circular(size.height / 2);
    final bounds = Offset.zero & size;

    // Track.
    canvas.drawRRect(
      ui.RRect.fromRectAndRadius(bounds, radius),
      Paint()..color = track,
    );

    // Fill.
    if (value > 0) {
      final fillWidth = size.width * value;
      final fillRect = Rect.fromLTWH(0, 0, fillWidth, size.height);
      canvas.drawRRect(
        ui.RRect.fromRectAndRadius(fillRect, radius),
        Paint()..color = fill,
      );
    }
  }

  @override
  bool shouldRepaint(_ProgressBarPainter old) =>
      old.value != value || old.track != track || old.fill != fill;
}
