import 'dart:math' as math;
import 'dart:ui';

/// Pure, widget-free zoom math. Every function is deterministic and side-effect
/// free so it can be unit-tested without a Flutter binding.
class ZoomMath {
  const ZoomMath._();

  /// Scale at which [content] exactly fits [viewport].
  ///
  /// Page mode (`widthOnly: false`) fits the constraining axis; continuous
  /// mode (`widthOnly: true`) fits width so tall content overflows and scrolls.
  static double fitScale({
    required Size viewport,
    required Size content,
    bool widthOnly = false,
  }) {
    if (content.width <= 0 || content.height <= 0) return 1.0;
    if (viewport.width <= 0 || viewport.height <= 0) return 1.0;
    final byWidth = viewport.width / content.width;
    if (widthOnly) return byWidth;
    final byHeight = viewport.height / content.height;
    return math.min(byWidth, byHeight);
  }

  static double clampScale(double scale, double min, double max) {
    if (min > max) return min;
    return scale.clamp(min, max);
  }

  /// Offset that keeps the content point under [focal] fixed while the scale
  /// changes from [startScale] to [newScale].
  static Offset focalZoomOffset({
    required Offset startOffset,
    required double startScale,
    required double newScale,
    required Offset focal,
  }) {
    if (startScale <= 0) return startOffset;
    final ratio = newScale / startScale;
    return focal - (focal - startOffset) * ratio;
  }

  /// Offset [scale] would produce for [content] centered in [viewport].
  static Offset centeredOffset({
    required double scale,
    required Size viewport,
    required Size content,
  }) => Offset(
    (viewport.width - content.width * scale) / 2,
    (viewport.height - content.height * scale) / 2,
  );

  /// Clamps [offset] so content edges stay within [viewport], centering any
  /// axis whose scaled content is smaller than the viewport. [overscroll]
  /// widens the allowed range by that many pixels during an active drag.
  static Offset clampOffset({
    required Offset offset,
    required double scale,
    required Size viewport,
    required Size content,
    double overscroll = 0,
  }) {
    final scaledW = content.width * scale;
    final scaledH = content.height * scale;

    final double x;
    if (scaledW <= viewport.width) {
      x = (viewport.width - scaledW) / 2;
    } else {
      x = offset.dx.clamp(
        viewport.width - scaledW - overscroll,
        overscroll,
      );
    }

    final double y;
    if (scaledH <= viewport.height) {
      y = (viewport.height - scaledH) / 2;
    } else {
      y = offset.dy.clamp(
        viewport.height - scaledH - overscroll,
        overscroll,
      );
    }

    return Offset(x, y);
  }

  /// Damped value when [scale] is outside [min]..[max]; unchanged inside.
  static double rubberBand(
    double scale,
    double min,
    double max,
    double resistance,
  ) {
    if (scale < min) return min - (min - scale) * resistance;
    if (scale > max) return max + (scale - max) * resistance;
    return scale;
  }

  /// New offset that keeps the content point at the old viewport center at the
  /// new viewport center after a viewport size or scale change.
  static Offset reanchorOffset({
    required Offset offset,
    required Size oldViewport,
    required Size newViewport,
    required double oldScale,
    required double newScale,
  }) {
    if (oldScale <= 0) return offset;
    final oldCenter = Offset(oldViewport.width / 2, oldViewport.height / 2);
    final newCenter = Offset(newViewport.width / 2, newViewport.height / 2);
    final contentPoint = (oldCenter - offset) / oldScale;
    return newCenter - contentPoint * newScale;
  }
}
