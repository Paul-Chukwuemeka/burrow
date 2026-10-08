import 'package:flutter/widgets.dart';

import 'zoom_config.dart';
import 'zoom_math.dart';

/// Single source of truth for a zoomable view's scale and translation.
class ZoomController extends ChangeNotifier {
  ZoomController({
    this.config = ZoomConfig.defaultConfig,
    required TickerProvider vsync,
  }) : _vsync = vsync;

  final ZoomConfig config;
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
    final old = _viewport;
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
    } else {
      reanchor(old, viewport);
    }
  }

  void setSourcePixelWidth(int px) {
    _sourcePixelWidth = px.toDouble();
    if (_scale > maxScale) {
      _scale = maxScale;
      _offset = clampOffset(_offset);
    }
    notifyListeners();
  }

  Offset clampOffset(Offset candidate) => ZoomMath.clampOffset(
    offset: candidate,
    scale: _scale,
    viewport: _viewport,
    content: _content,
  );

  Matrix4 get matrix => Matrix4.identity()
    ..translateByDouble(_offset.dx, _offset.dy, 0, 1)
    ..scaleByDouble(_scale, _scale, 1, 1);

  void reset({bool animate = true}) {
    final targetScale = minScale;
    final targetOffset = ZoomMath.centeredOffset(
      scale: targetScale,
      viewport: _viewport,
      content: _content,
    );
    if (animate && !disableAnimations) {
      _animateTo(scale: targetScale, offset: targetOffset);
    } else {
      _apply(scale: targetScale, offset: targetOffset);
    }
  }

  late final AnimationController _anim = AnimationController(
    vsync: _vsync,
    duration: config.animation,
  );

  bool disableAnimations = false;

  int _animGeneration = 0;
  VoidCallback? _animTick;

  void _apply({required double scale, required Offset offset}) {
    _scale = scale;
    _offset = offset;
    notifyListeners();
  }

  void _animateTo({required double scale, required Offset offset}) {
    _anim.stop();
    if (_animTick != null) {
      _anim.removeListener(_animTick!);
      _animTick = null;
    }
    final generation = ++_animGeneration;
    final beginScale = _scale;
    final beginOffset = _offset;
    void tick() {
      final t = config.animationCurve.transform(_anim.value);
      _apply(
        scale: beginScale + (scale - beginScale) * t,
        offset: Offset.lerp(beginOffset, offset, t)!,
      );
    }

    _animTick = tick;
    _anim
      ..reset()
      ..addListener(tick);
    _anim.forward().whenComplete(() {
      if (generation != _animGeneration) return;
      if (_animTick == tick) {
        _anim.removeListener(tick);
        _animTick = null;
      }
      _apply(scale: scale, offset: offset);
    });
  }

  void zoomTo({
    required double scale,
    required Offset focal,
    bool animate = true,
  }) {
    final target = ZoomMath.clampScale(scale, minScale, maxScale);
    final newOffset = ZoomMath.clampOffset(
      offset: ZoomMath.focalZoomOffset(
        startOffset: _offset,
        startScale: _scale,
        newScale: target,
        focal: focal,
      ),
      scale: target,
      viewport: _viewport,
      content: _content,
    );
    if (animate && !disableAnimations) {
      _animateTo(scale: target, offset: newOffset);
    } else {
      _apply(scale: target, offset: newOffset);
    }
  }

  void toggleDoubleTap(Offset focal) {
    if (isZoomed) {
      reset();
    } else {
      zoomTo(scale: config.doubleTapScale, focal: focal);
    }
  }

  late final AnimationController _mom = AnimationController.unbounded(
    vsync: _vsync,
  );

  Offset _momentumStart = Offset.zero;
  VoidCallback? _momTick;

  void panUpdate(Offset delta) {
    stopMomentum();
    _offset = ZoomMath.clampOffset(
      offset: _offset + delta,
      scale: _scale,
      viewport: _viewport,
      content: _content,
      overscroll: config.overscroll,
    );
    notifyListeners();
  }

  void panEnd(Velocity velocity) {
    stopMomentum();
    final speed = velocity.pixelsPerSecond.distance;
    if (speed < 1) {
      _offset = clampOffset(_offset);
      notifyListeners();
      return;
    }
    _momentumStart = _offset;
    final dir = velocity.pixelsPerSecond / speed;
    final sim = ClampingScrollSimulation(
      position: 0,
      velocity: speed,
      friction: config.friction,
    );
    void tick() {
      _offset = ZoomMath.clampOffset(
        offset: _momentumStart + dir * _mom.value,
        scale: _scale,
        viewport: _viewport,
        content: _content,
      );
      notifyListeners();
    }

    _momTick = tick;
    _mom
      ..reset()
      ..addListener(tick);
    _mom.animateWith(sim);
  }

  void stopMomentum() {
    if (_mom.isAnimating) _mom.stop();
    if (_momTick != null) {
      _mom.removeListener(_momTick!);
      _momTick = null;
    }
  }

  bool canPanHorizontal(double dx) {
    if (!isZoomed) return false;
    final min = _viewport.width - _content.width * _scale;
    if (dx < 0) return _offset.dx > min + 0.5;
    return _offset.dx < -0.5;
  }

  bool canPanVertical(double dy) {
    if (!isZoomed) return false;
    final min = _viewport.height - _content.height * _scale;
    if (dy < 0) return _offset.dy > min + 0.5;
    return _offset.dy < -0.5;
  }

  void reanchor(Size oldViewport, Size newViewport) =>
      _reanchor(oldViewport, newViewport, _scale);

  void _reanchor(Size oldViewport, Size newViewport, double oldScale) {
    final newMin = minScale;
    final newScale = _scale < newMin ? newMin : _scale;
    final oldCenter = Offset(oldViewport.width / 2, oldViewport.height / 2);
    final newCenter = Offset(newViewport.width / 2, newViewport.height / 2);
    final contentPoint = (oldCenter - _offset) / oldScale;
    _scale = newScale;
    _offset = ZoomMath.clampOffset(
      offset: newCenter - contentPoint * newScale,
      scale: newScale,
      viewport: _viewport,
      content: _content,
    );
    notifyListeners();
  }

  @override
  void dispose() {
    if (_animTick != null) {
      _anim.removeListener(_animTick!);
      _animTick = null;
    }
    if (_momTick != null) {
      _mom.removeListener(_momTick!);
      _momTick = null;
    }
    _anim.dispose();
    _mom.dispose();
    super.dispose();
  }
}
