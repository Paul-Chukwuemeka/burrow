// Paragraph-level hit-testing and drag selection in the reflowable reader.
//
// A long press must snap to the word under the finger using the rendered
// paragraph's own metrics (not a reconstructed TextPainter), dragging extends
// the selection word by word, and lifting shows the selection toolbar.
import 'dart:io';

import 'package:burrow/db/database.dart' as db;
import 'package:burrow/models/book.dart';
import 'package:burrow/models/reader_settings.dart';
import 'package:burrow/screens/reader_screen.dart';
import 'package:burrow/services/brightness_controller.dart';
import 'package:burrow/services/library_service.dart';
import 'package:burrow/src/rust/frb_generated.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

class _FakeWakelock extends WakelockPlusPlatformInterface {
  @override
  Future<bool> get enabled async => false;
  @override
  Future<void> toggle({required bool enable}) async {}
}

// The body paragraph on the current page whose plain text contains [needle].
RenderParagraph bodyParagraph(WidgetTester tester, String needle) => tester
    .renderObjectList<RenderParagraph>(find.byType(RichText))
    .firstWhere((p) => p.text.toPlainText().contains(needle));

// Global point at the middle of the first [word] in that paragraph, using the
// paragraph's own metrics (the same technique as inbook_links_reader_test).
Offset globalForWord(WidgetTester tester, String word) {
  final p = bodyParagraph(tester, word);
  final text = p.text.toPlainText();
  final off = text.indexOf(word);
  final tp = TextPainter(text: p.text, textDirection: p.textDirection)
    ..layout(maxWidth: p.size.width);
  final caret = tp.getOffsetForCaret(
    TextPosition(offset: off + word.length ~/ 2),
    Rect.zero,
  );
  tp.dispose();
  return p.localToGlobal(caret + const Offset(0, 6));
}

/// Body text currently rendered on screen.
String visibleText(WidgetTester tester) {
  final buffer = StringBuffer();
  for (final rt in tester.widgetList<RichText>(find.byType(RichText))) {
    buffer.write(rt.text.toPlainText());
  }
  return buffer.toString();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

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
    tmp = await Directory.systemTemp.createTemp('burrow_drag_selection');
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    library = LibraryService();

    final source = File('test/fixtures/epub/minimal.epub');
    await File(
      '${tmp.path}/Minimal Book.epub',
    ).writeAsBytes(source.readAsBytesSync());

    book = Book(
      id: 'b1',
      title: 'Minimal Book',
      author: 'A. Author',
      path: '${tmp.path}/Minimal Book.epub',
      format: BookFormat.epub,
      addedAt: 1000,
    );
  });

  tearDown(() async {
    BrightnessController.instance = BrightnessController();
    await database.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  ReaderScreenState readerState(WidgetTester tester) =>
      tester.state<ReaderScreenState>(find.byType(ReaderScreen));

  /// Pump until pagination is idle and the page view is mounted.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4000; i++) {
      final s = readerState(tester);
      if (!s.debugPaginationRunning &&
          !s.debugLazyRunning &&
          s.debugHasController) {
        break;
      }
      await tester.pump();
    }
    await tester.pump();
  }

  /// Copies a committed fixture into the temp dir and returns a [Book] backed
  /// by it, so a test can mount a reader on a different fixture than [setUp]'s.
  Future<Book> makeBook(String fixtureFile, String title) async {
    final dest = '${tmp.path}/$title.epub';
    await File(dest).writeAsBytes(File(fixtureFile).readAsBytesSync());
    return Book(
      id: 'b-$title',
      title: title,
      author: 'A. Author',
      path: dest,
      format: BookFormat.epub,
      addedAt: 1000,
    );
  }

  Future<ReaderScreenState> mountReaderFor(WidgetTester tester, Book b) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(412, 915);
    addTearDown(tester.view.reset);
    // Unmount before the suite-level tearDown closes the database: the
    // reader's dispose() persists position/session through it.
    addTearDown(() => tester.pumpWidget(const SizedBox()));

    await tester.pumpWidget(
      MaterialApp(
        home: ReaderScreen(book: b, library: library),
      ),
    );
    final state = readerState(tester);
    for (var i = 0; i < 200; i++) {
      if (state.debugHasDocument) break;
      // Real IO (the engine parse runs off a native port): FakeAsync time
      // does not advance it — pump while the real delay runs in runAsync.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(state.debugHasDocument, isTrue);
    await settle(tester);
    expect(state.debugAllReady, isTrue);
    return state;
  }

  Future<ReaderScreenState> mountReader(WidgetTester tester) =>
      mountReaderFor(tester, book);

  testWidgets('long-press on a chapter first page selects the pressed word', (
    tester,
  ) async {
    final state = await mountReader(tester);
    await tester.longPressAt(globalForWord(tester, 'first'));
    await tester.pumpAndSettle();
    expect(state.debugSelectionText, 'first');
    expect(find.text('Define'), findsOneWidget);
  });

  testWidgets(
    'long-press still hits the right word when justified with a custom margin',
    (tester) async {
      final state = await mountReader(tester);
      library.settings.horizontalMargin = 32;
      library.settings.textJustification = TextJustification.justify;
      state.debugApplySettingsChange();
      await settle(tester);

      await tester.longPressAt(globalForWord(tester, 'chapter'));
      await tester.pumpAndSettle();
      expect(state.debugSelectionText, 'chapter');
    },
  );

  testWidgets('drag extends the selection and drops Define', (tester) async {
    final state = await mountReader(tester);
    final g = await tester.startGesture(globalForWord(tester, 'first'));
    await tester.pump(const Duration(milliseconds: 600));
    await g.moveTo(globalForWord(tester, 'chapter'));
    await tester.pump();
    await g.up();
    await tester.pumpAndSettle();
    expect(state.debugSelectionText, 'first chapter');
    expect(find.text('Define'), findsNothing);
    expect(find.text('Copy'), findsOneWidget);
  });

  testWidgets('long-press on punctuation selects nothing', (tester) async {
    final state = await mountReader(tester);
    await tester.longPressAt(globalForWord(tester, '.'));
    await tester.pumpAndSettle();
    expect(state.debugSelection.isActive, isFalse);
  });

  testWidgets('centre tap clears; side tap flips and keeps', (tester) async {
    final state = await mountReader(tester);
    await tester.longPressAt(globalForWord(tester, 'first'));
    await tester.pumpAndSettle();
    final size = tester.getSize(find.byType(ReaderScreen));
    await tester.tapAt(Offset(size.width * 0.85, size.height * 0.5));
    await tester.pumpAndSettle();
    // The page receives the tap directly (no toolbar barrier on the EPUB
    // path): a right-zone tap flips to the next chapter but keeps the
    // selection.
    expect(visibleText(tester), contains('The second chapter.'));
    expect(state.debugSelection.isActive, isTrue); // flipped, kept
    await tester.tapAt(Offset(size.width * 0.5, size.height * 0.5));
    await tester.pumpAndSettle();
    expect(state.debugSelection.isActive, isFalse); // centre cleared
  });

  group('selection handles and cross-page continuation', () {
    late Book multi;

    setUp(() async {
      multi = await makeBook('test/fixtures/epub/multipage.epub', 'Multi');
    });

    testWidgets('drag to the page bottom clamps to the last word on this page', (
      tester,
    ) async {
      final state = await mountReaderFor(tester, multi);
      final g = await tester.startGesture(globalForWord(tester, 'w0'));
      await tester.pump(const Duration(milliseconds: 600));
      final body = bodyParagraph(tester, 'w0');
      final pageText = body.text.toPlainText().trim();
      await g.moveTo(
        // The right edge of the last line, so the drag reaches this page's
        // final word: a middle-of-line x would land on the second-to-last word.
        body.localToGlobal(Offset(body.size.width - 2, body.size.height - 2)),
      );
      await tester.pump();
      await g.up();
      await tester.pumpAndSettle();
      expect(state.debugSelectionText, pageText); // whole page, not past it
      expect(find.byKey(const Key('selectionHandleEnd')), findsNothing);
    });

    testWidgets('end handle on the next page extends across the boundary', (
      tester,
    ) async {
      final state = await mountReaderFor(tester, multi);
      final g = await tester.startGesture(globalForWord(tester, 'w0'));
      await tester.pump(const Duration(milliseconds: 600));
      final body = bodyParagraph(tester, 'w0');
      await g.moveTo(
        // The right edge of the last line, so the drag reaches this page's
        // final word: a middle-of-line x would land on the second-to-last word.
        body.localToGlobal(Offset(body.size.width - 2, body.size.height - 2)),
      );
      await tester.pump();
      await g.up();
      await tester.pumpAndSettle();
      final before = state.debugSelectionText!;
      final size = tester.getSize(find.byType(ReaderScreen));
      await tester.tapAt(Offset(size.width * 0.85, size.height * 0.5));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('selectionHandleEnd')), findsOneWidget);
      await tester.drag(
        find.byKey(const Key('selectionHandleEnd')),
        const Offset(0, 120),
      );
      await tester.pumpAndSettle();
      expect(state.debugSelectionText!.length, greaterThan(before.length));
      expect(state.debugSelectionText!.startsWith(before), isTrue);
    });
  });
}
