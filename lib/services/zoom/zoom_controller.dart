import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:vector_math/vector_math_64.dart';

import 'zoom_config.dart';
import 'zoom_math.dart';

/// Single source of truth for a zoomable view's scale and translation.
class ZoomController extends ChangeNotifier {
  ZoomController({
    this.config = ZoomConfig.defaultConfig,
    required TickerProvider vsync,
  }) : _vsync = vsync;

  final ZoomConfig config;
  // ignore: unused_field
  final TickerProvider _vsync;

  double _scale = 1.0;
  Offset _offset = Offset.zero;
  Size _viewport = Size.zero;
  Size _content = Size.zero;
  double? _sourcePixelWidth;
  bool _widthOnly = false;

  double get scale => _scale;
  Offset get offset => _offset;
  Size get viewport => _viewport;
  Size get content => _content;

  double get minScale => ZoomMath.fitScale(
    viewport: _viewport,
    content: _content,
    widthOnly: _widthOnly,
  );

  double get maxScale {
    final configMax = config.maxScale;
    final src = _sourcePixelWidth;
    if (src == null || _content.width <= 0) return configMax;
    final cap = src / _content.width;
    return cap < configMax ? cap : configMax;
  }

  bool get isZoomed => _scale > minScale * 1.01;

  void setViewport(Size viewport, Size content, {bool widthOnly = false}) {
    final first = _viewport == Size.zero;
    _viewport = viewport;
    _content = content;
    _widthOnly = widthOnly;
    if (first) {
      _scale = minScale;
      _offset = ZoomMath.centeredOffset(
        scale: _scale,
        viewport: viewport,
        content: content,
      );
      notifyListeners();
    }
    // Subsequent calls (resize/rotation) re-anchor in Task 8.
  }

  void setSourcePixelWidth(int px) {
    _sourcePixelWidth = px.toDouble();
    if (_scale > maxScale) _scale = maxScale;
    notifyListeners();
  }

  Matrix4 get matrix => Matrix4.identity()
    ..translateByDouble(_offset.dx, _offset.dy, 0, 1)
    ..scaleByDouble(_scale, _scale, 1, 1);

  void reset({bool animate = true}) {
    _scale = minScale;
    _offset = ZoomMath.centeredOffset(
      scale: _scale,
      viewport: _viewport,
      content: _content,
    );
    notifyListeners();
  }

  // zoomTo is completed in Task 7; declared here so the matrix test compiles.
  void zoomTo({
    required double scale,
    required Offset focal,
    bool animate = true,
  }) {
    final target = ZoomMath.clampScale(scale, minScale, maxScale);
    final newOffset = ZoomMath.focalZoomOffset(
      startOffset: _offset,
      startScale: _scale,
      newScale: target,
      focal: focal,
    );
    _scale = target;
    _offset = ZoomMath.clampOffset(
      offset: newOffset,
      scale: target,
      viewport: _viewport,
      content: _content,
    );
    notifyListeners();
  }
}
