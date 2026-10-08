import 'dart:ui';

import 'package:burrow/services/zoom/zoom_math.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fitScale fits to screen in page mode', () {
    final s = ZoomMath.fitScale(
      viewport: const Size(400, 800),
      content: const Size(1000, 1500),
    );
    expect(s, closeTo(0.4, 1e-9));
  });

  test('fitScale fits to width in continuous mode', () {
    final s = ZoomMath.fitScale(
      viewport: const Size(400, 800),
      content: const Size(1000, 1500),
      widthOnly: true,
    );
    expect(s, closeTo(0.4, 1e-9));
  });

  test('fitScale widthOnly ignores height', () {
    final s = ZoomMath.fitScale(
      viewport: const Size(400, 800),
      content: const Size(1000, 200),
      widthOnly: true,
    );
    expect(s, closeTo(0.4, 1e-9));
  });

  test('fitScale page mode uses the constraining (height) axis', () {
    final s = ZoomMath.fitScale(
      viewport: const Size(400, 800),
      content: const Size(1000, 4000),
    );
    expect(s, closeTo(0.2, 1e-9));
  });

  test('fitScale widthOnly ignores the height constraint', () {
    final s = ZoomMath.fitScale(
      viewport: const Size(400, 800),
      content: const Size(1000, 4000),
      widthOnly: true,
    );
    expect(s, closeTo(0.4, 1e-9));
  });

  test('fitScale returns 1 for empty content', () {
    expect(
      ZoomMath.fitScale(viewport: const Size(400, 800), content: Size.zero),
      1.0,
    );
  });

  test('clampScale clamps to range', () {
    expect(ZoomMath.clampScale(3.0, 1.0, 5.0), 3.0);
    expect(ZoomMath.clampScale(0.2, 1.0, 5.0), 1.0);
    expect(ZoomMath.clampScale(9.0, 1.0, 5.0), 5.0);
  });

  test('focalZoomOffset keeps the content point under the focal fixed', () {
    const startOffset = Offset(10, 20);
    const startScale = 1.0;
    const newScale = 2.0;
    const focal = Offset(100, 150);
    final newOffset = ZoomMath.focalZoomOffset(
      startOffset: startOffset,
      startScale: startScale,
      newScale: newScale,
      focal: focal,
    );
    // content point under focal before:
    final c = (focal - startOffset) / startScale;
    // viewport position of c after:
    final after = newOffset + c * newScale;
    expect(after.dx, closeTo(focal.dx, 1e-6));
    expect(after.dy, closeTo(focal.dy, 1e-6));
  });

  test('focalZoomOffset is identity when scale is unchanged', () {
    final o = ZoomMath.focalZoomOffset(
      startOffset: const Offset(5, 5),
      startScale: 2.0,
      newScale: 2.0,
      focal: const Offset(50, 50),
    );
    expect(o.dx, closeTo(5, 1e-9));
    expect(o.dy, closeTo(5, 1e-9));
  });

  test('clampOffset prevents blank space at edges', () {
    const viewport = Size(400, 800);
    const content = Size(1000, 1500);
    const scale = 1.0; // scaled content 1000x1500 larger than viewport
    // too far right (>0) clamps to 0
    expect(
      ZoomMath.clampOffset(
        offset: const Offset(50, 0),
        scale: scale,
        viewport: viewport,
        content: content,
      ),
      const Offset(0, 0),
    );
    // too far left clamps to viewport - scaledContent
    expect(
      ZoomMath.clampOffset(
        offset: const Offset(-900, 0),
        scale: scale,
        viewport: viewport,
        content: content,
      ),
      const Offset(-600, 0),
    );
  });

  test('clampOffset centers an axis smaller than the viewport', () {
    final o = ZoomMath.clampOffset(
      offset: const Offset(100, 100),
      scale: 0.5,
      viewport: const Size(400, 800),
      content: const Size(400, 800),
    );
    // scaled content 200x400 -> centered on both axes
    expect(o.dx, closeTo(100, 1e-9));
    expect(o.dy, closeTo(200, 1e-9));
  });

  test('clampOffset allows overscroll during a drag', () {
    final o = ZoomMath.clampOffset(
      offset: const Offset(30, 0),
      scale: 1.0,
      viewport: const Size(400, 800),
      content: const Size(1000, 1500),
      overscroll: 48,
    );
    expect(o.dx, closeTo(30, 1e-9));
  });

  test('centeredOffset centers both axes', () {
    final o = ZoomMath.centeredOffset(
      scale: 0.5,
      viewport: const Size(400, 800),
      content: const Size(400, 800),
    );
    expect(o.dx, closeTo(100, 1e-9));
    expect(o.dy, closeTo(200, 1e-9));
  });

  test('rubberBand passes through in-range scale unchanged', () {
    expect(ZoomMath.rubberBand(2.0, 1.0, 5.0, 0.35), 2.0);
  });

  test('rubberBand damps below-min and above-max scale', () {
    expect(ZoomMath.rubberBand(0.5, 1.0, 5.0, 0.35), closeTo(0.825, 1e-9));
    expect(ZoomMath.rubberBand(6.0, 1.0, 5.0, 0.35), closeTo(5.35, 1e-9));
  });

  test('reanchorOffset keeps the center content point fixed', () {
    const offset = Offset(-100, -200);
    const oldViewport = Size(400, 800);
    const newViewport = Size(800, 400);
    final o = ZoomMath.reanchorOffset(
      offset: offset,
      oldViewport: oldViewport,
      newViewport: newViewport,
      oldScale: 1.0,
      newScale: 1.0,
    );
    // content point at old center:
    const scale = 1.0;
    final c = (Offset(200, 400) - offset) / scale;
    // its viewport position after re-anchor:
    final after = o + c * scale;
    expect(after.dx, closeTo(400, 1e-6));
    expect(after.dy, closeTo(200, 1e-6));
  });

  test('reanchorOffset keeps the center content point fixed across scale change', () {
    const offset = Offset(-100, -200);
    const oldViewport = Size(400, 800);
    const newViewport = Size(800, 400);
    const oldScale = 1.0;
    const newScale = 2.0;
    final o = ZoomMath.reanchorOffset(
      offset: offset,
      oldViewport: oldViewport,
      newViewport: newViewport,
      oldScale: oldScale,
      newScale: newScale,
    );
    // content point at the old center, using the old scale:
    final c = (Offset(200, 400) - offset) / oldScale;
    // its viewport position after re-anchor, using the new scale:
    final after = o + c * newScale;
    expect(after.dx, closeTo(400, 1e-6));
    expect(after.dy, closeTo(200, 1e-6));
  });
}
