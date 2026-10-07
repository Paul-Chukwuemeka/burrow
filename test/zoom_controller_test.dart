import 'dart:ui';

import 'package:burrow/services/zoom/zoom_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart';

void main() {
  test('setViewport fits and centers content', () {
    final c = ZoomController(vsync: const TestVSync());
    c.setViewport(const Size(400, 800), const Size(1000, 1500));
    expect(c.minScale, closeTo(0.4, 1e-9));
    expect(c.scale, closeTo(0.4, 1e-9));
    // scaled content 400x600 is centered vertically: (800-600)/2 = 100
    expect(c.offset.dx, closeTo(0, 1e-9));
    expect(c.offset.dy, closeTo(100, 1e-9));
    expect(c.isZoomed, isFalse);
    c.dispose();
  });

  test('maxScale is capped by source resolution', () {
    final c = ZoomController(vsync: const TestVSync());
    // content 1000 logical px wide; source 3000 px -> cap 3.0
    c.setViewport(const Size(400, 800), const Size(1000, 1500));
    c.setSourcePixelWidth(3000);
    expect(c.maxScale, closeTo(3.0, 1e-9));
    c.dispose();
  });

  test('matrix maps content through offset and scale', () {
    final c = ZoomController(vsync: const TestVSync());
    c.setViewport(const Size(400, 800), const Size(1000, 1500));
    c.zoomTo(scale: 2.0, focal: const Offset(200, 400), animate: false);
    final v = c.matrix.transform3(Vector3(0, 0, 0));
    expect(v.x, closeTo(c.offset.dx, 1e-6));
    expect(v.y, closeTo(c.offset.dy, 1e-6));
    c.dispose();
  });
}
