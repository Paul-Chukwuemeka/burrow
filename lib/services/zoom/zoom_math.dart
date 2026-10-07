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

  static double clampScale(double scale, double min, double max) =>
      scale.clamp(min, max);

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
}
