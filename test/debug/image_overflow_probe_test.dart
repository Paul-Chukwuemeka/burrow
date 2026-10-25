// DIAGNOSTIC PROBE — not a unit test.
//
// Symptom under investigation: "pagination is broken / pages with images are
// overflowing / clipping". A page whose rendered body is taller than its
// allotted box either reports a RenderFlex overflow exception or silently
// clips. Pagination measurement (ChapterPaginationDriver) and rendering
// (_PageContent's RichText) must agree exactly; every mismatch shows up here
// as an overflow or as a body/box height difference.
//
// The probe mounts the real ReaderScreen on each image-bearing fixture EPUB
// at two viewports (portrait + landscape), flips through EVERY page, and for
// each visible page records:
//   * exceptions (RenderFlex overflow surfaces as a FlutterError)
//   * body RenderParagraph size vs its parent box size
//   * paginator (measurement) height sum for the page vs rendered body height
//
// Run:
//   BURROW_IMG_PROBE=1 flutter test test/debug/image_overflow_probe_test.dart
// Optional: BURROW_IMG_PROBE_BOOKS=a.epub:b.epub
import 'dart:io';
import 'dart:ui' as ui;

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

ReaderScreenState _readerState(WidgetTester tester) =>
    tester.state<ReaderScreenState>(find.byType(ReaderScreen));

final _progressView = find.textContaining('Laying out pages');
final _books = Platform.environment['BURROW_IMG_PROBE_BOOKS'] ??
    [
      'test/fixtures/epub/cover-inline.epub',
      'test/fixtures/epub/tall-image.epub',
      'test/fixtures/epub/projection.epub',
      'test/fixtures/epub/multipage.epub',
      'test/fixtures/epub/svg-image.epub',
      'test/fixtures/epub/missing-image.epub',
    ].join(':');

void main() {
  if (Platform.environment['BURROW_IMG_PROBE'] != '1') {
    test('image overflow probe (disabled)', () {
      // ignore: avoid_print
      print('Skipped: set BURROW_IMG_PROBE=1 to run.');
    });
    return;
  }

  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  final bookPaths =
      _books.split(':').where((p) => p.isNotEmpty).map((p) => p.startsWith('/')
              ? p
              : '${Directory.current.path}/$p')
          .toList();

  for (final path in bookPaths) {
    for (final viewport in const [Size(412, 915), Size(915, 412)]) {
      final name = '${path.split('/').last} @ ${viewport.width}x${viewport.height}';
      testWidgets('image overflow probe: $name',
          timeout: const Timeout(Duration(minutes: 4)), (tester) async {
        SharedPreferences.setMockInitialValues({});
        WakelockPlusPlatformInterface.instance = _FakeWakelock();
        BrightnessController.instance = BrightnessController(
          getCurrent: () async => 0.5,
          setBrightness: (_) async {},
          resetBrightness: () async {},
        );

        final tmp = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('burrow_img_probe'),
        ))!;
        final book = Book(
          id: 'probe',
          title: name,
          author: 'probe',
          path: path,
          format: BookFormat.epub,
          addedAt: 0,
        );
        final database = (await tester.runAsync(() async {
          final database = db.AppDatabase.forTesting(NativeDatabase.memory());
          await database.insertBook(db.bookToCompanion(book));
          return database;
        }))!;
        final library = LibraryService()
          ..debugAttachDatabase(database)
          ..debugAddAll([book]);

        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          BrightnessController.instance = BrightnessController();
          await tester.runAsync(() => database.close());
          if (tmp.existsSync()) tmp.deleteSync(recursive: true);
        });

        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = viewport;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          MaterialApp(home: ReaderScreen(book: book, library: library)),
        );
        var parsed = false;
        for (var i = 0; i < 200; i++) {
          if (_readerState(tester).debugHasDocument) {
            parsed = true;
            break;
          }
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
        }
        expect(parsed, isTrue, reason: 'document should parse');
        await tester.pump();
        await tester.pump();

        // Wait for pagination to settle.
        for (var i = 0; i < 4000; i++) {
          final state = _readerState(tester);
          if (!state.debugPaginationRunning &&
              !state.debugLazyRunning &&
              state.debugHasController) {
            break;
          }
          await tester.pump();
        }
        expect(_progressView, findsNothing, reason: 'pagination should settle');
        expect(find.byType(PageView), findsOneWidget);

        // Flip through every page, recording overflow evidence per page.
        final problems = <String>[];
        final state = _readerState(tester);
        final pageHeights = state.debugPageHeights(0);
        final total = state.debugFlatPageCount;
        for (var page = 0; page < total; page++) {
          final countedSum = page < pageHeights.length
              ? pageHeights[page].fold<double>(
                  0.0,
                  (a, b) => a + b,
                )
              : double.nan;
          _recordPageEvidence(
            tester,
            problems: problems,
            label: '$name page $page',
            extra: 'countedSum=${countedSum.toStringAsFixed(1)}',
          );
          if (page < total - 1) {
            await tester.tapAt(
              Offset(viewport.width * 0.85, viewport.height / 2),
            );
            await tester.pumpAndSettle(const Duration(milliseconds: 100));
          }
        }

        if (problems.isNotEmpty) {
          fail('$name: overflow/clipping evidence:\n'
              '${problems.join('\n---\n')}');
        }
      });
    }
  }
}

/// Collects layout-evidence about the page currently mounted.
void _recordPageEvidence(
  WidgetTester tester, {
  required List<String> problems,
  required String label,
  String extra = '',
}) {
  final e = tester.takeException();
  if (e != null) {
    problems.add('$label: exception: $e');
  }
  for (final el in tester.allElements) {
    if (el.widget is! RichText) continue;
    if (el.findAncestorWidgetOfExactType<PageView>() == null) continue;
    final ro = el.findRenderObject() as RenderParagraph;
    if (ro.size.height <= 0.0) continue;
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
    final hasImage = ro.text.toPlainText().contains('\uFFFC');
    // RenderParagraph clamps its laid-out size to its constraints, so an
    // over-tall page looks "fine" by size alone. Measure the true content
    // extent: the bottom of the last inline box (placeholders included).
    final boxes = ro.getBoxesForSelection(
      TextSelection(
        baseOffset: 0,
        extentOffset: ro.text.toPlainText().length,
      ),
      boxHeightStyle: ui.BoxHeightStyle.tight,
    );
    var contentBottom = ro.size.height;
    for (final box in boxes) {
      if (box.bottom > contentBottom) contentBottom = box.bottom;
    }
    // ignore: avoid_print
    print(
      'EVIDENCE $label body=${ro.size.width}x${ro.size.height} '
      'stack=${stack.size.width}x${stack.size.height} '
      'contentBottom=${contentBottom.toStringAsFixed(1)} image=$hasImage $extra',
    );
    final over = contentBottom - stack.size.height;
    if (over > 0.5) {
      // Detail dump: which content extends past the box?
      final plain = ro.text.toPlainText();
      for (final b in boxes) {
        final mid = Offset(
          (b.left + b.right) / 2,
          (b.top + b.bottom) / 2,
        );
        final pos = ro.getPositionForOffset(mid).offset;
        final snippet = plain.substring(
          pos.clamp(0, plain.length),
          (pos + 14).clamp(0, plain.length),
        );
        // ignore: avoid_print
        print(
          '  box top=${b.top.toStringAsFixed(1)} '
          'bottom=${b.bottom.toStringAsFixed(1)} '
          'at=$pos "${snippet.replaceAll('\n', '␤')}"',
        );
      }
      problems.add(
        '$label: RichText ${ro.size.width}x${ro.size.height} exceeds '
        '${stack.size.width}x${stack.size.height} by ${over.toStringAsFixed(1)}px',
      );
    }
  }
}
