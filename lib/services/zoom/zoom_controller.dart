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
    final m = cap < configMax ? cap : configMax;
    return m < minScale ? minScale : m;
  }

  bool get isZoomed => _scale > minScale + 0.01;

  void setViewport(Size viewport, Size content, {bool widthOnly = false}) {
    final first = _viewport == Size.zero;
    final old = _viewport;
    _viewport = viewport;
    _content = content;
    _widthOnly = widthOnly;
    if (first) {
      _scale = minScale;
      _offset = _widthOnly
          ? Offset((viewport.width - content.width * _scale) / 2, 0)
          : ZoomMath.centeredOffset(
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
    final targetOffset = _widthOnly
        ? Offset((_viewport.width - _content.width * targetScale) / 2, 0)
        : ZoomMath.centeredOffset(
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
    _stopSnap();
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

  late final AnimationController _snap = AnimationController(
    vsync: _vsync,
    duration: config.snapBackDuration,
  );

  Offset _momentumStart = Offset.zero;
  VoidCallback? _momTick;
  VoidCallback? _snapTick;

  void panUpdate(Offset delta) {
    stopMomentum();
    _stopSnap();
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
    _stopSnap();
    final speed = velocity.pixelsPerSecond.distance;
    if (speed < 1) {
      _snapBack();
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
        overscroll: config.overscroll,
      );
      notifyListeners();
    }

    _momTick = tick;
    _mom
      ..reset()
      ..addListener(tick);
    _mom.animateWith(sim).whenComplete(() {
      if (_momTick != tick) return;
      _mom.removeListener(tick);
      _momTick = null;
      _snapBack();
    });
  }

  void _snapBack() {
    final target = clampOffset(_offset);
    if (target == _offset) return;
    if (disableAnimations || config.snapBackDuration == Duration.zero) {
      _offset = target;
      notifyListeners();
      return;
    }
    _animateOffsetTo(target);
  }

  void _animateOffsetTo(Offset target) {
    _stopSnap();
    final begin = _offset;
    void tick() {
      final t = config.animationCurve.transform(_snap.value);
      _offset = Offset.lerp(begin, target, t)!;
      notifyListeners();
    }

    _snapTick = tick;
    _snap
      ..reset()
      ..addListener(tick);
    _snap.forward().whenComplete(() {
      if (_snapTick != tick) return;
      _snap.removeListener(tick);
      _snapTick = null;
      _offset = target;
      notifyListeners();
    });
  }

  void _stopSnap() {
    if (_snap.isAnimating) _snap.stop();
    if (_snapTick != null) {
      _snap.removeListener(_snapTick!);
      _snapTick = null;
    }
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
    final newScale = ZoomMath.clampScale(_scale, minScale, maxScale);
    _scale = newScale;
    _offset = ZoomMath.clampOffset(
      offset: ZoomMath.reanchorOffset(
        offset: _offset,
        oldViewport: oldViewport,
        newViewport: newViewport,
        oldScale: oldScale,
        newScale: newScale,
      ),
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
    if (_snapTick != null) {
      _snap.removeListener(_snapTick!);
      _snapTick = null;
    }
    _anim.dispose();
    _mom.dispose();
    _snap.dispose();
    super.dispose();
  }
}
