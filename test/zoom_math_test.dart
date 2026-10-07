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
}
