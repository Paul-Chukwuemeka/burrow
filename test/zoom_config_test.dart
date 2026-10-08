import 'package:burrow/services/zoom/zoom_config.dart';
import 'package:flutter/animation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('defaults match the spec', () {
    const c = ZoomConfig();
    expect(c.maxScale, 5.0);
    expect(c.doubleTapScale, 2.5);
    expect(c.animation, const Duration(milliseconds: 250));
    expect(c.animationCurve, Curves.easeOutCubic);
    expect(c.snapBackDuration, const Duration(milliseconds: 180));
    expect(c.edgeSwipeThreshold, 72.0);
    expect(c.edgeSwipeVelocity, 420.0);
    expect(c.overscroll, 48.0);
    expect(c.rubberBandResistance, 0.35);
    expect(c.friction, 0.015);
    expect(c.prefetchRadius, 2);
    expect(c.zoomIndicatorFadeMs, 1000);
    expect(c.keepZoomAcrossPagesDefault, false);
  });

  test('defaultConfig is a const ZoomConfig', () {
    expect(ZoomConfig.defaultConfig.maxScale, 5.0);
  });
}
