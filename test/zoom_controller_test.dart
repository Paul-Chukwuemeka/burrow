import 'package:burrow/services/zoom/zoom_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
    final p = Offset(c.content.width / 2, c.content.height / 2);
    final v = c.matrix.transform3(Vector3(p.dx, p.dy, 0));
    expect(v.x, closeTo(c.offset.dx + c.scale * p.dx, 1e-6));
    expect(v.y, closeTo(c.offset.dy + c.scale * p.dy, 1e-6));
    c.dispose();
  });

  test('toggleDoubleTap zooms to doubleTapScale then back to fit', () {
    final c = ZoomController(vsync: const TestVSync())..disableAnimations = true;
    c.setViewport(const Size(400, 800), const Size(1000, 1500));
    c.toggleDoubleTap(const Offset(200, 400));
    expect(c.scale, closeTo(c.config.doubleTapScale, 1e-9));
    expect(c.isZoomed, isTrue);
    c.toggleDoubleTap(const Offset(200, 400));
    expect(c.scale, closeTo(c.minScale, 1e-9));
    expect(c.isZoomed, isFalse);
    c.dispose();
  });

  test('toggleDoubleTap centers the tap point', () {
    final c = ZoomController(vsync: const TestVSync())..disableAnimations = true;
    c.setViewport(const Size(400, 800), const Size(1000, 1500));
    const focal = Offset(120, 300);
    final before = (focal - c.offset) / c.scale;
    c.toggleDoubleTap(focal);
    final after = c.offset + before * c.scale;
    expect(after.dx, closeTo(focal.dx, 1e-3));
    expect(after.dy, closeTo(focal.dy, 1e-3));
    c.dispose();
  });

  test('panUpdate clamps and canPan reports edges', () {
    final c = ZoomController(vsync: const TestVSync());
    c.setViewport(const Size(400, 800), const Size(1000, 1500));
    c.zoomTo(scale: 2.0, focal: const Offset(200, 400), animate: false);
    final minLeft = 400.0 - 1000 * 2.0 - c.config.overscroll; // -1648
    c.panUpdate(const Offset(-10000, 0));
    expect(c.offset.dx, closeTo(minLeft, 1e-6));
    expect(c.canPanHorizontal(-10), isFalse);
    expect(c.canPanHorizontal(10), isTrue);
    c.dispose();
  });

  testWidgets('stopMomentum halts an in-flight fling', (tester) async {
    final c = ZoomController(vsync: const TestVSync());
    c.setViewport(const Size(400, 800), const Size(1000, 1500));
    c.zoomTo(scale: 2.0, focal: const Offset(200, 400), animate: false);
    final start = c.offset.dx;
    c.panEnd(const Velocity(pixelsPerSecond: Offset(-2000, 0)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));
    final moved = c.offset.dx;
    expect(moved, isNot(closeTo(start, 1e-6)));
    c.stopMomentum();
    final stopped = c.offset.dx;
    await tester.pump(const Duration(milliseconds: 200));
    expect(c.offset.dx, closeTo(stopped, 1e-9));
    c.dispose();
  });

  test('reanchor keeps the center content point after resize', () {
    final c = ZoomController(vsync: const TestVSync());
    c.setViewport(const Size(400, 800), const Size(1000, 1500));
    c.zoomTo(scale: 2.0, focal: const Offset(200, 400), animate: false);
    final center = (Offset(200, 400) - c.offset) / c.scale;
    c.setViewport(const Size(800, 400), const Size(1000, 1500));
    final after = c.offset + center * c.scale;
    expect(after.dx, closeTo(400, 1e-3));
    expect(after.dy, closeTo(200, 1e-3));
    c.dispose();
  });

  test('reanchor raises scale to the new min and keeps the center content point', () {
    final c = ZoomController(vsync: const TestVSync());
    c.setViewport(
      const Size(400, 800),
      const Size(1000, 1500),
      widthOnly: true,
    );
    c.zoomTo(scale: 2.0, focal: const Offset(200, 400), animate: false);
    final contentPoint = (const Offset(200, 400) - c.offset) / c.scale;
    c.setViewport(
      const Size(2400, 600),
      const Size(1000, 1500),
      widthOnly: true,
    );
    expect(c.scale, closeTo(2.4, 1e-9));
    final after = c.offset + contentPoint * c.scale;
    expect(after.dx, closeTo(1200, 1e-3));
    expect(after.dy, closeTo(300, 1e-3));
    c.dispose();
  });

  testWidgets('toggleDoubleTap animates back to fit when zoomed', (tester) async {
    final c = ZoomController(vsync: const TestVSync());
    c.setViewport(const Size(400, 800), const Size(1000, 1500));
    c.toggleDoubleTap(const Offset(200, 400));
    await tester.pumpAndSettle();
    expect(c.isZoomed, isTrue);
    c.toggleDoubleTap(const Offset(200, 400));
    expect(c.scale, closeTo(c.config.doubleTapScale, 1e-9));
    await tester.pumpAndSettle();
    expect(c.scale, closeTo(c.minScale, 1e-6));
    c.dispose();
  });
}
