import 'dart:io';

import 'package:burrow/db/database.dart' as db;
import 'package:burrow/models/book.dart';
import 'package:burrow/models/reader_settings.dart';
import 'package:burrow/screens/reader_screen.dart';
import 'package:burrow/services/brightness_controller.dart';
import 'package:burrow/services/library_service.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

/// Keeps the wakelock plugin out of widget tests.
class _FakeWakelock extends WakelockPlusPlatformInterface {
  bool _on = false;

  @override
  Future<void> toggle({required bool enable}) async => _on = enable;

  @override
  Future<bool> get enabled async => _on;
}

/// Multi-chapter body long enough that pagination cannot finish in one frame.
String _bookText() {
  final b = StringBuffer();
  for (var c = 1; c <= 6; c++) {
    b.writeln('Chapter $c');
    // Paragraphs must not start with "Chapter N" or the TXT chapterizer
    // treats every line as a heading.
    for (var p = 0; p < 24; p++) {
      b.writeln('Para $c.$p opens here. '
          '${List.generate(45, (i) => 'w$c-$p-$i').join(' ')}');
    }
    // Blank-line run: chapter boundary for the TXT chapterizer.
    b.write('\n\n\n\n');
  }
  return b.toString();
}

final _progressView = find.textContaining('Laying out pages');
final _marker = RegExp(r'w\d+-\d+-\d+');

ReaderScreenState _readerState(WidgetTester tester) =>
    tester.state<ReaderScreenState>(find.byType(ReaderScreen));

int _pageCount(WidgetTester tester) => tester
    .widget<PageView>(find.byType(PageView))
    .childrenDelegate
    .estimatedChildCount!;

/// Body text of the page currently on screen.
String _visibleText(WidgetTester tester) {
  final buffer = StringBuffer();
  for (final rt in tester.widgetList<RichText>(find.byType(RichText))) {
    buffer.write(rt.text.toPlainText());
  }
  return buffer.toString();
}

/// Pump frames until pagination settles into a rendered reader. The returned
/// frame count is the point of the exercise: a blocking pass settles in one.
Future<int> _settlePagination(WidgetTester tester) async {
  var frames = 0;
  final problems = <String>[];
  while (frames < 4000) {
    final state = _readerState(tester);
    if (!state.debugPaginationRunning &&
        !state.debugLazyRunning &&
        state.debugHasController) {
      break;
    }
    await tester.pump();
    frames++;
    final e = tester.takeException();
    if (e != null) {
      problems.add('frame $frames (running=${state.debugPaginationRunning} '
          'lazy=${state.debugLazyRunning} '
          'ctl=${state.debugHasController}): $e');
      if (problems.length > 3) break;
    }
  }
  // Let the frame that mounts the PageView run.
  await tester.pump();
  if (problems.isNotEmpty) {
    fail('exceptions during settle:\n${problems.join('\n---\n')}');
  }
  return frames;
}

/// Apply a settings mutation through the same path the sheet's callback uses,
/// so these tests stay focused on the reader's response to it.
Future<void> _applySettings(
  WidgetTester tester,
  void Function() mutate,
) async {
  mutate();
  _readerState(tester).debugApplySettingsChange();
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late db.AppDatabase database;
  late LibraryService library;
  late Book book;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    WakelockPlusPlatformInterface.instance = _FakeWakelock();
    BrightnessController.instance = BrightnessController(
      getCurrent: () async => 0.5,
      setBrightness: (_) async {},
      resetBrightness: () async {},
    );

    tmp = await Directory.systemTemp.createTemp('burrow_repaginate');
    final bookFile = File('${tmp.path}/Long Book.txt');
    await bookFile.writeAsString(_bookText());

    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    book = Book(
      id: 'b1',
      title: 'Long Book',
      author: 'Author',
      path: bookFile.path,
      format: BookFormat.txt,
      addedAt: 1000,
    );
    library = LibraryService()
      ..debugAttachDatabase(database)
      ..debugAddAll([book]);
    await database.insertBook(db.bookToCompanion(book));
  });

  tearDown(() async {
    BrightnessController.instance = BrightnessController();
    await database.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// Mount the reader and wait for the document to parse. Parsing runs on a
  /// real isolate, which only progresses outside the fake-async zone.
  Future<void> mountReader(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(412, 915);
    addTearDown(tester.view.reset);

    // Unmount before the suite-level tearDown closes the database: the
    // reader's dispose() persists position/session through it.
    addTearDown(() => tester.pumpWidget(const SizedBox()));

    await tester.pumpWidget(
      MaterialApp(home: ReaderScreen(book: book, library: library)),
    );
    for (var i = 0; i < 100; i++) {
      if (_readerState(tester).debugHasDocument) break;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(_readerState(tester).debugHasDocument, isTrue,
        reason: 'document should have parsed');
    // The reflowable LayoutBuilder starts pagination in a post-frame callback.
    await tester.pump();
    await tester.pump();
  }

  Future<void> openReader(WidgetTester tester) async {
    await mountReader(tester);
    await _settlePagination(tester);
    expect(find.byType(PageView), findsOneWidget,
        reason: 'reader should be showing pages');
  }

  group('Reader repagination', () {
    testWidgets('opens immediately and paginates the rest in the background',
        (tester) async {
      await mountReader(tester);
      // The reader is shown without waiting for the whole book.
      expect(_progressView, findsNothing,
          reason: 'normal chapters open without a progress view');
      expect(find.byType(PageView), findsOneWidget);
      expect(_readerState(tester).debugLazyRunning, isTrue,
          reason: 'remaining chapters paginate in the background');

      await _settlePagination(tester);
      expect(find.byType(PageView), findsOneWidget);
      expect(_readerState(tester).debugLazyRunning, isFalse);
    });

    testWidgets('a font-size change does not block the frame', (tester) async {
      await openReader(tester);
      final before = _pageCount(tester);

      await _applySettings(tester, () => library.settings.fontSize = 28);

      // Lazy pagination: the reader stays interactive, no progress indicator.
      expect(_progressView, findsNothing,
          reason: 'lazy pagination does not show a progress view');
      expect(find.byType(PageView), findsOneWidget,
          reason: 'PageView stays visible during background pagination');

      await _settlePagination(tester);

      expect(find.byType(PageView), findsOneWidget);
      expect(_pageCount(tester), greaterThan(before),
          reason: 'a bigger font must produce more pages');
    });

    testWidgets('a font-size change re-paginates the current chapter at once',
        (tester) async {
      await openReader(tester);
      tester.widget<PageView>(find.byType(PageView)).controller!.jumpToPage(3);
      await tester.pump();
      final e = tester.takeException();
      if (e != null) fail('overflow on jump frame: $e');

      double bodyFontSize() {
        for (final rt in tester.widgetList<RichText>(find.byType(RichText))) {
          final size = rt.text.style?.fontSize;
          if (size != null) return size;
        }
        fail('no styled RichText on the visible page');
      }

      expect(bodyFontSize(), 18,
          reason: 'the initial layout renders at the default font size');

      await _applySettings(tester, () => library.settings.fontSize = 28);

      // The visible chapter is re-paginated synchronously, so the new font is
      // on screen immediately while the rest of the book pages in background.
      expect(bodyFontSize(), 28,
          reason: 'the current chapter must switch to the new font at once');
      expect(_readerState(tester).debugLazyRunning, isTrue,
          reason: 'the remaining chapters paginate in the background');

      await _settlePagination(tester);

      expect(bodyFontSize(), 28,
          reason: 'the new font persists after the background pass settles');
      final err = tester.takeException();
      if (err != null) fail('exception after settle: $err');
    });

    testWidgets('reading position survives a font-size change', (tester) async {
      await openReader(tester);

      // Read a few pages in.
      tester.widget<PageView>(find.byType(PageView)).controller!.jumpToPage(5);
      await tester.pump();
      final e1 = tester.takeException();
      if (e1 != null) fail('overflow on jump frame: $e1');
      final word = _marker.firstMatch(_visibleText(tester))!.group(0)!;

      library.settings.fontSize = 24;
      _readerState(tester).debugApplySettingsChange();
      final e2 = tester.takeException();
      if (e2 != null) fail('exception synchronously after apply: $e2');
      // Lazy pagination: reader stays interactive immediately.
      await tester.pump();
      final e3 = tester.takeException();
      if (e3 != null) {
        fail('overflow on first frame after apply '
            '(running=${_readerState(tester).debugPaginationRunning} '
            'lazy=${_readerState(tester).debugLazyRunning} '
            'ctl=${_readerState(tester).debugHasController}): $e3');
      }
      await _settlePagination(tester);

      expect(_visibleText(tester), contains(word),
          reason: 'should land back on the text we were reading');
    });

    testWidgets('line-height change repaginates and keeps position',
        (tester) async {
      await openReader(tester);
      final before = _pageCount(tester);

      tester.widget<PageView>(find.byType(PageView)).controller!.jumpToPage(4);
      await tester.pump();
      final word = _marker.firstMatch(_visibleText(tester))!.group(0)!;

      await _applySettings(tester, () => library.settings.lineHeight = 2.2);
      // Lazy pagination: no progress indicator, reader stays visible.
      expect(_progressView, findsNothing);
      await _settlePagination(tester);

      expect(_pageCount(tester), greaterThan(before));
      expect(_visibleText(tester), contains(word));
    });

    testWidgets('font-family change repaginates', (tester) async {
      await openReader(tester);

      await _applySettings(tester, () => library.settings.fontFamily = 'Bitter');
      // Lazy pagination: no progress indicator.
      expect(_progressView, findsNothing);
      await _settlePagination(tester);

      expect(find.byType(PageView), findsOneWidget);
    });

    testWidgets('a non-layout setting change does not repaginate',
        (tester) async {
      await openReader(tester);
      final before = _pageCount(tester);

      await _applySettings(tester, () => library.settings.keepScreenOn = true);

      expect(_progressView, findsNothing,
          reason: 'signature is unchanged, so no pass should start');
      expect(find.byType(PageView), findsOneWidget);
      expect(_pageCount(tester), before);
    });

    testWidgets('a theme change does not repaginate', (tester) async {
      await openReader(tester);
      final before = _pageCount(tester);

      await _applySettings(
        tester,
        () => library.settings.readerTheme = ReaderThemeMode.dark,
      );

      expect(_progressView, findsNothing);
      expect(_pageCount(tester), before);
    });

    testWidgets('rapid changes leave the original position intact',
        (tester) async {
      await openReader(tester);

      tester.widget<PageView>(find.byType(PageView)).controller!.jumpToPage(4);
      await tester.pump();
      final word = _marker.firstMatch(_visibleText(tester))!.group(0)!;

      // Three changes a frame apart: each supersedes the last mid-pass.
      await _applySettings(tester, () => library.settings.fontSize = 22);
      await tester.pump();
      await _applySettings(tester, () => library.settings.fontSize = 15);
      await tester.pump();
      await _applySettings(tester, () => library.settings.fontSize = 26);

      await _settlePagination(tester);

      expect(_visibleText(tester), contains(word),
          reason: 'the position captured before the first pass must be kept');
    });

    testWidgets('superseded passes do not corrupt the layout', (tester) async {
      // A stale generation writing chapters at the previous style would leave a
      // page count that disagrees with a clean pass at the final style.
      await openReader(tester);
      await _applySettings(tester, () => library.settings.fontSize = 22);
      await tester.pump();
      await _applySettings(tester, () => library.settings.fontSize = 15);
      await tester.pump();
      await _applySettings(tester, () => library.settings.fontSize = 26);
      await _settlePagination(tester);
      final interleaved = _pageCount(tester);

      // Now mount a fresh reader that only ever saw 26.
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      library.settings.fontSize = 26;
      await openReader(tester);

      expect(interleaved, _pageCount(tester));
    });

    testWidgets('navigating during a layout pass is not undone', (tester) async {
      await openReader(tester);
      tester.widget<PageView>(find.byType(PageView)).controller!.jumpToPage(3);
      await tester.pump();

      // Change a layout setting, then navigate before the reflow settles.
      library.settings.fontSize = 28;
      _readerState(tester).debugApplySettingsChange();
      await tester.pump();
      expect(_readerState(tester).debugLazyRunning, isTrue,
          reason: 'the reflow should still be running');

      tester.widget<PageView>(find.byType(PageView)).controller!.jumpToPage(6);
      await tester.pump();
      final word = _marker.firstMatch(_visibleText(tester))!.group(0)!;

      await _settlePagination(tester);

      expect(_visibleText(tester), contains(word),
          reason: 'the page navigated to during the pass must be kept');
    });

    testWidgets('a layout change keeps the page count complete during reflow',
        (tester) async {
      await openReader(tester);
      final before = _pageCount(tester);

      // Apply a font change but do not settle: the live set must stay complete
      // (no placeholder chapters, no `…` total, enabled scrubber) while the
      // new layout builds in the background.
      library.settings.fontSize = 28;
      _readerState(tester).debugApplySettingsChange();
      await tester.pump();

      expect(_readerState(tester).debugAllReady, isTrue,
          reason: 'the live layout stays complete during the reflow');
      expect(_readerState(tester).debugLazyRunning, isTrue,
          reason: 'the reflow runs in the background');
      expect(find.byType(PageView), findsOneWidget);
      expect(tester.takeException(), isNull);

      await _settlePagination(tester);
      expect(_readerState(tester).debugAllReady, isTrue);
      expect(_pageCount(tester), greaterThan(before));
    });

    testWidgets('reader layout ignores the app-wide text size scale',
        (tester) async {
      // The reader body has its own font size; the global "Text size" must not
      // change pagination or the rendered page, or pages would break early.
      await openReader(tester);
      final pagesAt100 = _pageCount(tester);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      tester.platformDispatcher.textScaleFactorTestValue = 1.2;
      addTearDown(
          tester.platformDispatcher.clearTextScaleFactorTestValue);
      await openReader(tester);

      expect(tester.takeException(), isNull,
          reason: 'the page must not overflow at a larger global text size');
      expect(_pageCount(tester), pagesAt100,
          reason: 'pagination is independent of the global text size');

      final pageRichTexts = tester.widgetList<RichText>(
        find.descendant(
          of: find.byType(PageView),
          matching: find.byType(RichText),
        ),
      );
      expect(pageRichTexts, isNotEmpty);
      expect(
        pageRichTexts.every((rt) => rt.textScaler == TextScaler.noScaling),
        isTrue,
        reason: 'page text must render unscaled',
      );
    });
  });
}
