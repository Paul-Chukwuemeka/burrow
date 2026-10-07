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
}
