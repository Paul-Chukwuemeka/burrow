import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:burrow/db/database.dart' as db;
import 'package:burrow/models/book.dart';
import 'package:burrow/models/reader_settings.dart';
import 'package:burrow/screens/reader_screen.dart';
import 'package:burrow/services/brightness_controller.dart';
import 'package:burrow/services/library_service.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart' hide InteractiveViewer;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

/// Realistically sized pages matter for the vertical list: pages must be
/// tall enough that item 0 stays mounted (the sliver keeps a stable tail
/// otherwise, which breaks "which InteractiveViewer is in the tree"
/// assumptions).
Future<Uint8List?> _renderTestPng(int w, int h) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Offset.zero & Size(w.toDouble(), h.toDouble()));
  canvas.drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..color = const Color(0xFF3366CC),
  );
  final image = await recorder.endRecording().toImage(w, h);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data?.buffer.asUint8List();
}

Future<Book> _writeCbzBook(Directory dir, WidgetTester tester) async {
  final png = (await tester.runAsync(() => _renderTestPng(200, 400)))!;
  final archive = Archive();
  for (var i = 1; i <= 20; i++) {
    archive.addFile(
      ArchiveFile('page${i.toString().padLeft(3, '0')}.png', png.length, png),
    );
  }
  final f = File('${dir.path}/comic.cbz');
  f.writeAsBytesSync(ZipEncoder().encode(archive));
  return Book(
    id: 'c1',
    title: 'Comic',
    author: '',
    path: f.path,
    format: BookFormat.cbz,
    addedAt: 1,
  );
}

class _FakeWakelock extends WakelockPlusPlatformInterface {
  @override
  Future<void> toggle({required bool enable}) async {}
  @override
  Future<bool> get enabled async => false;
}

/// Pump the reader and wait until the comic viewport is live: a [PageView]
/// in horizontal mode, an [InteractiveViewer] item in vertical mode.
Future<ReaderScreenState> _pumpReader(
  WidgetTester tester,
  Book book,
  LibraryService library,
) async {
  await tester.pumpWidget(
    MaterialApp(home: ReaderScreen(book: book, library: library)),
  );
  for (var i = 0; i < 100; i++) {
    if (find.byType(PageView).evaluate().isNotEmpty ||
        find.byType(InteractiveViewer).evaluate().isNotEmpty) {
      break;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  await tester.pump();
  return tester.state<ReaderScreenState>(find.byType(ReaderScreen));
}

/// Enter zoom mode via double-tap: two quick taps, then wait out the
/// double-tap window so the zoom toggle has fired.
Future<void> _doubleTapZoom(WidgetTester tester) async {
  await tester.tapAt(const Offset(206, 450));
  await tester.pump(const Duration(milliseconds: 40));
  await tester.tapAt(const Offset(206, 450));
  await tester.pump(const Duration(milliseconds: 300));
}

InteractiveViewer _iv(WidgetTester tester) =>
    tester.widget<InteractiveViewer>(find.byType(InteractiveViewer).first);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late db.AppDatabase database;
  late LibraryService library;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    WakelockPlusPlatformInterface.instance = _FakeWakelock();
    BrightnessController.instance = BrightnessController(
      getCurrent: () async => 0.5,
      setBrightness: (_) async {},
      resetBrightness: () async {},
    );
    tmp = await Directory.systemTemp.createTemp('burrow_zoom');
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    library = LibraryService()..debugAttachDatabase(database);
  });

  tearDown(() async {
    BrightnessController.instance = BrightnessController();
    await database.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  testWidgets('horizontal zoom: drag pans the page instead of flipping',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(412, 915);
    addTearDown(tester.view.reset);

    library.settings.comicReadingMode = ComicReadingMode.paginated;
    final book = await _writeCbzBook(tmp, tester);
    library.debugAddAll([book]);
    final state = await _pumpReader(tester, book, library);
    expect(state.debugComicPage, 0);

    await _doubleTapZoom(tester);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    final tc = _iv(tester).transformationController!;
    expect(tc.value.getMaxScaleOnAxis(), closeTo(1.1, 0.01));

    // Zoomed page turns off pager swipes so pan owns the drag.
    final pageView = tester.widget<PageView>(find.byType(PageView).first);
    expect(pageView.physics, isA<NeverScrollableScrollPhysics>());

    // One-finger drag left: must pan the zoomed panel, not flip the page.
    await tester.drag(
      find.byType(InteractiveViewer).first,
      const Offset(-200, 0),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(state.debugComicPage, 0, reason: 'drag while zoomed must not flip');
    expect(
      tc.value.storage[12],
      lessThan(-1),
      reason: 'drag while zoomed must pan the transform',
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('horizontal zoom: zoom-out (pinch back) resumes page swiping',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(412, 915);
    addTearDown(tester.view.reset);

    library.settings.comicReadingMode = ComicReadingMode.paginated;
    final book = await _writeCbzBook(tmp, tester);
    library.debugAddAll([book]);
    final state = await _pumpReader(tester, book, library);
    await _doubleTapZoom(tester);

    // Simulate the state after a pinch-out back to fit scale (what the
    // InteractiveViewer writes once the gesture ends at minScale).
    _iv(tester).transformationController!.value = Matrix4.identity();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final pageView = tester.widget<PageView>(find.byType(PageView).first);
    expect(pageView.physics, isNot(isA<NeverScrollableScrollPhysics>()));

    // Swiping again turns the page (InteractiveViewer at fit scale must not
    // swallow the drag).
    await tester.drag(find.byType(PageView).first, const Offset(-400, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(state.debugComicPage, 1);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('horizontal zoom: exiting zoom resets the transform',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(412, 915);
    addTearDown(tester.view.reset);

    library.settings.comicReadingMode = ComicReadingMode.paginated;
    final book = await _writeCbzBook(tmp, tester);
    library.debugAddAll([book]);
    final state = await _pumpReader(tester, book, library);
    await _doubleTapZoom(tester);

    await _doubleTapZoom(tester); // exit zoom mode
    await tester.pump();

    expect(state.debugComicTransform!.value.getMaxScaleOnAxis(), closeTo(1.0, 0.01));

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('vertical zoom: drag pans the panel instead of scrolling',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(412, 915);
    addTearDown(tester.view.reset);

    library.settings.comicReadingMode = ComicReadingMode.vertical;
    final book = await _writeCbzBook(tmp, tester);
    library.debugAddAll([book]);
    final state = await _pumpReader(tester, book, library);
    expect(state.debugComicPage, 0);

    await _doubleTapZoom(tester);

    // Double-tap zoom applies its level to the current page's transformer.
    final tc = state.debugVerticalTransformerFor(state.debugComicPage);
    expect(tc.value.getMaxScaleOnAxis(), closeTo(1.1, 0.01));
    expect(state.debugComicZoomed, isTrue);

    // Zoomed page turns off list scrolling so pan owns the drag.
    final list = tester.widget<ScrollView>(
      find.byType(ListView).first,
    );
    expect(list.physics, isA<NeverScrollableScrollPhysics>());

    final scrollable = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(ListView).first,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    final offsetBefore = scrollable.position.pixels;

    // One-finger drag down: must pan the zoomed panel, not scroll pages.
    await tester.drag(
      find.byType(InteractiveViewer).first,
      const Offset(0, 200),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      scrollable.position.pixels,
      offsetBefore,
      reason: 'drag while zoomed must not scroll the list',
    );
    expect(
      state.debugComicPage,
      0,
      reason: 'drag while zoomed must not turn pages',
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('vertical: zoom-out (pinch back) resumes scrolling',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(412, 915);
    addTearDown(tester.view.reset);

    library.settings.comicReadingMode = ComicReadingMode.vertical;
    final book = await _writeCbzBook(tmp, tester);
    library.debugAddAll([book]);
    final state = await _pumpReader(tester, book, library);
    await _doubleTapZoom(tester);

    // Simulate the state after a pinch-out back to fit scale (what the
    // InteractiveViewer writes once the gesture ends at minScale).
    state
        .debugVerticalTransformerFor(state.debugComicPage)
        .value = Matrix4.identity();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final list = tester.widget<ScrollView>(
      find.byType(ListView).first,
    );
    expect(list.physics, isNot(isA<NeverScrollableScrollPhysics>()));
    expect(state.debugComicZoomed, isFalse);

    // Full swipe works again (the list scrolls; a partial-page swipe is
    // still page 0, so assert the scroll offset instead of the page index).
    final scrollable2 = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(ListView).first,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.drag(
      find.byType(ListView).first,
      const Offset(0, -400),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(scrollable2.position.pixels, greaterThan(0));

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('vertical: exiting zoom resets every page transform',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(412, 915);
    addTearDown(tester.view.reset);

    library.settings.comicReadingMode = ComicReadingMode.vertical;
    final book = await _writeCbzBook(tmp, tester);
    library.debugAddAll([book]);
    final state = await _pumpReader(tester, book, library);
    await _doubleTapZoom(tester);
    expect(state.debugComicZoomed, isTrue);

    // Zoom an off-screen page's transformer as if the user had scrolled to
    // it and zoomed there earlier.
    state.debugVerticalTransformerFor(2).value = Matrix4.identity()
      ..scaleByDouble(2.0, 2.0, 1.0, 1.0);
    await tester.pump();
    expect(state.debugComicZoomed, isTrue);

    await _doubleTapZoom(tester); // exit zoom mode
    await tester.pump(const Duration(milliseconds: 300));

    expect(state.debugComicZoomed, isFalse);
    for (final tc in state.debugAllVerticalTransformers) {
      expect(tc.value.getMaxScaleOnAxis(), closeTo(1.0, 0.01));
    }

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
