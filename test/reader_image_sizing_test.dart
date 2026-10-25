// Regression: an EPUB whose inline <img> is sized by CSS/HTML attributes must
// paginate and render at the same size.
//
// The reader's page-content wrapper used to rebuild each ImageRun
// field-by-field to attach the image-popup tap handler, silently dropping the
// image's css/html sizing. Pagination then measured a css-capped placeholder
// (20px) while the page rendered an uncapped full-width image (166px+), so
// text pages ended with the image's bottom clipped into the next page's
// territory — the "pages with images overflow/clip" bug. Any sizing field
// dropped again re-introduces it; this mounts the real reader and requires
// every rendered page body to fit its box end to end.
import 'dart:io';
import 'dart:math' as math;

import 'package:burrow/db/database.dart' as db;
import 'package:burrow/models/book.dart';
import 'package:burrow/screens/reader_screen.dart';
import 'package:burrow/services/brightness_controller.dart';
import 'package:burrow/services/library_service.dart';
import 'package:burrow/src/rust/frb_generated.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph, RenderStack;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

class _FakeWakelock extends WakelockPlusPlatformInterface {
  bool _on = false;
  @override
  Future<void> toggle({required bool enable}) async => _on = enable;
  @override
  Future<bool> get enabled async => _on;
}

ReaderScreenState _state(WidgetTester tester) =>
    tester.state<ReaderScreenState>(find.byType(ReaderScreen));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  testWidgets('reader keeps css-sized inline images within their pages', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    WakelockPlusPlatformInterface.instance = _FakeWakelock();
    BrightnessController.instance = BrightnessController(
      getCurrent: () async => 0.5,
      setBrightness: (_) async {},
      resetBrightness: () async {},
    );

    final bookFile = File('test/fixtures/epub/projection.epub');
    expect(bookFile.existsSync(), isTrue, reason: 'fixture must exist');

    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    final book = Book(
      id: 'b-img',
      title: 'Projection',
      author: 'A',
      path: bookFile.path,
      format: BookFormat.epub,
      addedAt: 0,
    );
    final library = LibraryService()
      ..debugAttachDatabase(database)
      ..debugAddAll([book]);
    await database.insertBook(db.bookToCompanion(book));

    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      BrightnessController.instance = BrightnessController();
      await database.close();
    });

    // Landscape was the geometry where the old bug was most visible: the
    // short page budget closed the gap between the measured and rendered
    // placeholder that portrait at full height could still absorb.
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(915, 412);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(home: ReaderScreen(book: book, library: library)),
    );
    for (var i = 0; i < 200; i++) {
      if (_state(tester).debugHasDocument) break;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(_state(tester).debugHasDocument, isTrue);
    await tester.pump();
    await tester.pump();
    for (var i = 0; i < 4000; i++) {
      final s = _state(tester);
      if (!s.debugPaginationRunning && !s.debugLazyRunning && s.debugHasController) {
        break;
      }
      await tester.pump();
    }
    expect(find.byType(PageView), findsOneWidget);

    // Walk every page (single-chapter fixture: flat page == paginator page).
    final total = _state(tester).debugFlatPageCount;
    expect(total, greaterThanOrEqualTo(1));
    final pageHeights = _state(tester).debugPageHeights(0);
    expect(
      pageHeights,
      hasLength(total),
      reason: 'pagination must keep per-page line heights for every page',
    );

    for (var page = 0; page < total; page++) {
      final bodies = tester
          .allElements
          .where((el) => el.widget is RichText)
          .where(
            (el) => el.findAncestorWidgetOfExactType<PageView>() != null,
          )
          .toList();
      for (final el in bodies) {
        final ro = el.findRenderObject() as RenderParagraph;
        if (ro.size.height <= 0) continue;
        RenderObject? ancestor = ro.parent;
        RenderStack? stack;
        while (ancestor != null) {
          if (ancestor is RenderStack) {
            stack = ancestor;
            break;
          }
          ancestor = ancestor.parent;
        }
        if (stack == null) continue;
        var contentBottom = ro.size.height;
        for (final box in ro.getBoxesForSelection(
          TextSelection(
            baseOffset: 0,
            extentOffset: ro.text.toPlainText().length,
          ),
        )) {
          if (box.bottom > contentBottom) contentBottom = box.bottom;
        }
        // RenderParagraph clamps to its constraints, so a clipped body hides
        // as a "fitting" size; the inline-box bottom is the honest measure.
        expect(
          contentBottom,
          lessThanOrEqualTo(stack.size.height + 0.5),
          reason: 'page $page body renders '
              '${contentBottom.toStringAsFixed(1)}px in a '
              '${stack.size.height}px box — image sizing diverged from the '
              'paginator again',
        );
        // And the pagination count must agree with the render on image pages
        // (the original bug was render >> count by ~86px there).
        if (ro.text.toPlainText().contains('\uFFFC')) {
          final counted = math.max(
            0.0,
            pageHeights[page].fold<double>(0.0, (a, b) => a + b),
          );
          expect(
            contentBottom,
            closeTo(counted, 12.0),
            reason: 'page $page: render/render-count mismatch — '
                'pagination counted ${counted.toStringAsFixed(1)}px, rendered '
                '${contentBottom.toStringAsFixed(1)}px',
          );
        }
      }
      if (page < total - 1) {
        await tester.tapAt(const Offset(915 * 0.85, 412 / 2));
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
      }
    }
  });
}
