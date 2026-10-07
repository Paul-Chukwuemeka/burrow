import 'package:flutter/animation.dart';

/// All tunable constants for the comic zoom engine.
class ZoomConfig {
  const ZoomConfig({
    this.maxScale = 5.0,
    this.doubleTapScale = 2.5,
    this.animation = const Duration(milliseconds: 250),
    this.animationCurve = Curves.easeOutCubic,
    this.snapBackDuration = const Duration(milliseconds: 180),
    this.edgeSwipeThreshold = 72.0,
    this.edgeSwipeVelocity = 420.0,
    this.overscroll = 48.0,
    this.rubberBandResistance = 0.35,
    this.friction = 0.015,
    this.prefetchRadius = 2,
    this.zoomIndicatorFadeMs = 1000,
    this.keepZoomAcrossPagesDefault = false,
  });

  final double maxScale;
  final double doubleTapScale;
  final Duration animation;
  final Curve animationCurve;
  final Duration snapBackDuration;
  final double edgeSwipeThreshold;
  final double edgeSwipeVelocity;
  final double overscroll;
  final double rubberBandResistance;
  final double friction;
  final int prefetchRadius;
  final int zoomIndicatorFadeMs;
  final bool keepZoomAcrossPagesDefault;

  static const ZoomConfig defaultConfig = ZoomConfig();
}
