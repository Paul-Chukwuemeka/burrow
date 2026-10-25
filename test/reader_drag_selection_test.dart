// Paragraph-level hit-testing and drag selection in the reflowable reader.
//
// A long press must snap to the word under the finger using the rendered
// paragraph's own metrics (not a reconstructed TextPainter), dragging extends
// the selection character by character, and lifting shows the selection
// toolbar.
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
    // Sync write: a real async file write never completes inside the
    // FakeAsync zone that testWidgets runs the test body in.
    File(dest).writeAsBytesSync(File(fixtureFile).readAsBytesSync());
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

  testWidgets('drag extends the selection by characters, not words', (
    tester,
  ) async {
    final state = await mountReader(tester);
    final g = await tester.startGesture(globalForWord(tester, 'first'));
    await tester.pump(const Duration(milliseconds: 600));
    // The pointing device lands on the middle of "chapter"; the selection must
    // follow the caret to that exact character (word snapping would give
    // "first chapter").
    await g.moveTo(globalForWord(tester, 'chapter'));
    await tester.pump();
    await g.up();
    await tester.pumpAndSettle();
    expect(state.debugSelectionText, 'first cha');
    expect(find.text('Define'), findsNothing);
    expect(find.text('Copy'), findsOneWidget);
  });

  testWidgets('dragging before the anchor extends to the exact character', (
    tester,
  ) async {
    final state = await mountReader(tester);
    final g = await tester.startGesture(globalForWord(tester, 'chapter'));
    await tester.pump(const Duration(milliseconds: 600));
    await g.moveTo(globalForWord(tester, 'first'));
    await tester.pump();
    await g.up();
    await tester.pumpAndSettle();
    // "first" starts at 4; the pointer's caret is mid-word at 6.
    expect(state.debugSelectionText, 'rst chapter');
  });

  testWidgets('long-press on punctuation selects nothing', (tester) async {
    final state = await mountReader(tester);
    await tester.longPressAt(globalForWord(tester, '.'));
    await tester.pumpAndSettle();
    expect(state.debugSelection.isActive, isFalse);
  });

  testWidgets('a long-press that hits no word clears the selection', (
    tester,
  ) async {
    final state = await mountReader(tester);
    await tester.longPressAt(globalForWord(tester, 'first'));
    await tester.pumpAndSettle();
    expect(state.debugSelectionText, 'first');
    expect(find.text('Define'), findsOneWidget);

    // A fresh long-press on the period starts no selection; it must not leave
    // the previous word selected (and its toolbar on screen).
    await tester.longPressAt(globalForWord(tester, '.'));
    await tester.pumpAndSettle();
    expect(state.debugSelection.isActive, isFalse);
    expect(find.text('Define'), findsNothing);
  });

  testWidgets('long-press outside the body selects nothing', (tester) async {
    final state = await mountReader(tester);
    // 15px above the body paragraph: the chapter-title band, not reading text.
    await tester.longPressAt(
      bodyParagraph(tester, 'first').localToGlobal(const Offset(20, -15)),
    );
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

    testWidgets('start handle on a page first line is hit-testable', (
      tester,
    ) async {
      final state = await mountReaderFor(tester, multi);
      // Long-press the first word on line 1 (the paragraph's own top-left), so
      // the selection's start caret sits at the top of the body box — where an
      // unclamped handle box would hang above the Stack and be unhittable.
      // Then extend along the line so the end caret (and handle) moves clear
      // of the start handle: the two 44px boxes overlap on a one-word
      // selection, and the end handle (the later Stack child) would win.
      final body = bodyParagraph(tester, 'w0');
      final g = await tester.startGesture(
        body.localToGlobal(const Offset(0, 6)),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await g.moveTo(body.localToGlobal(Offset(body.size.width / 2, 6)));
      await tester.pump();
      await g.up();
      await tester.pumpAndSettle();
      expect(state.debugSelection.isActive, isTrue);
      final startBefore = state.debugSelection.start!;

      final startHandle = find.byKey(const Key('selectionHandleStart'));
      expect(startHandle, findsOneWidget);

      // Drag the *painted handle*, not the box centre: on a first-line start
      // handle the box clamps to the top of the Stack while the teardrop is
      // translated upward. The shape must be clamped back inside the hit box
      // or this gesture falls through and the selection start does not move.
      final handle = find.descendant(
        of: startHandle,
        matching: find.byType(CustomPaint),
      );
      expect(handle, findsOneWidget);
      await tester.drag(handle, const Offset(120, 0));
      await tester.pumpAndSettle();
      expect(state.debugSelection.start, greaterThan(startBefore));
    });

    testWidgets('both handles hang above their caret and point down', (
      tester,
    ) async {
      final state = await mountReaderFor(tester, multi);
      final body = bodyParagraph(tester, 'w0');
      final text = body.text.toPlainText();
      final tokens = text.trim().split(RegExp(r'\s+'));
      final tokenOffsets = <int>[];
      var cursor = 0;
      for (final token in tokens) {
        final offset = text.indexOf(token, cursor);
        tokenOffsets.add(offset);
        cursor = offset + token.length;
      }
      final painter = TextPainter(
        text: body.text,
        textDirection: body.textDirection,
      )..layout(maxWidth: body.size.width);
      final caretYs = [
        for (final offset in tokenOffsets)
          painter.getOffsetForCaret(TextPosition(offset: offset), Rect.zero).dy,
      ];
      painter.dispose();

      // Start on the second line and end two lines lower, so neither handle is
      // pushed down by the first-line clamp.
      final startIndex = caretYs.indexWhere((y) => y > 30);
      expect(startIndex, greaterThanOrEqualTo(0));
      final endIndex = caretYs.indexWhere((y) => y > caretYs[startIndex] + 20);
      expect(endIndex, greaterThan(startIndex));

      final g = await tester.startGesture(
        globalForWord(tester, tokens[startIndex]),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await g.moveTo(globalForWord(tester, tokens[endIndex]));
      await tester.pump();
      await g.up();
      await tester.pumpAndSettle();

      final startHandle = find.byKey(const Key('selectionHandleStart'));
      final endHandle = find.byKey(const Key('selectionHandleEnd'));
      expect(startHandle, findsOneWidget);
      expect(endHandle, findsOneWidget);

      Offset caretAt(int flatOffset) => body.localToGlobal(
        body.getOffsetForCaret(
          TextPosition(offset: flatOffset.clamp(0, text.length).toInt()),
          Rect.zero,
        ),
      );
      final startCaret = caretAt(state.debugSelection.start!);
      final endCaret = caretAt(state.debugSelection.end!);
      final startGlyph = tester.getRect(
        find.descendant(of: startHandle, matching: find.byType(CustomPaint)),
      );
      final endGlyph = tester.getRect(
        find.descendant(of: endHandle, matching: find.byType(CustomPaint)),
      );

      // The bottom edge is the teardrop's tip: both tips sit above their
      // caret, so both handles point down at the text.
      expect(startGlyph.bottom, lessThanOrEqualTo(startCaret.dy));
      expect(endGlyph.bottom, lessThanOrEqualTo(endCaret.dy));
      expect(startGlyph.height, greaterThan(startGlyph.width));
      expect(endGlyph.height, greaterThan(endGlyph.width));
    });

    testWidgets('end handle drag trims single characters', (tester) async {
      final state = await mountReader(tester);
      // Select "first chapter" exactly: long-press "first", drag to the period's
      // caret (just past the word).
      final g = await tester.startGesture(globalForWord(tester, 'first'));
      await tester.pump(const Duration(milliseconds: 600));
      await g.moveTo(globalForWord(tester, '.'));
      await tester.pump();
      await g.up();
      await tester.pumpAndSettle();
      expect(state.debugSelectionText, 'first chapter');
      final endBefore = state.debugSelection.end!;

      // A short left drag lands inside the last characters: the end moves by a
      // character or two, where word snapping would jump a whole word.
      await tester.drag(
        find.byKey(const Key('selectionHandleEnd')),
        const Offset(-40, 0),
      );
      await tester.pumpAndSettle();
      final endAfter = state.debugSelection.end!;
      expect(endAfter, lessThan(endBefore));
      expect(endBefore - endAfter, inInclusiveRange(1, 5));
      expect(state.debugSelectionText, startsWith('first cha'));
    });

    testWidgets(
      'dragging the start handle past the end collapses to a character',
      (tester) async {
        final state = await mountReaderFor(tester, multi);
        final body = bodyParagraph(tester, 'w0');
        final tokens = body.text.toPlainText().trim().split(RegExp(r'\s+'));

        // Extend a few lines down: the toolbar anchors at the lift caret (the
        // end), so the start handle on line 1 stays clear of it and is the
        // widget that receives the drag below.
        final g = await tester.startGesture(
          globalForWord(tester, tokens.first),
        );
        await tester.pump(const Duration(milliseconds: 600));
        await g.moveTo(globalForWord(tester, tokens[20]));
        await tester.pump();
        await g.up();
        await tester.pumpAndSettle();
        final before = state.debugSelectionText ?? '';
        expect(before, isNotEmpty);
        expect(before.split(' ').length, greaterThan(1));

        final startHandle = find.byKey(const Key('selectionHandleStart'));
        expect(startHandle, findsOneWidget);

        // Character precision: crossing the start past the end clamps to
        // `end - 1`, leaving a one-character selection at the far end instead
        // of inverting the range.
        await tester.drag(
          startHandle,
          globalForWord(tester, tokens[21]) - tester.getCenter(startHandle),
        );
        await tester.pumpAndSettle();
        final after = state.debugSelectionText!;
        expect(after.length, 1);
        expect(before.endsWith(after), isTrue);
      },
    );
  });

  group('end handle bridged only when the page edge is selected', () {
    late Book punct;

    setUp(() async {
      punct = await makeBook(
        'test/fixtures/epub/multipage-punct.epub',
        'Multi Punct',
      );
    });

    testWidgets('covers the final character then flips to the end handle', (
      tester,
    ) async {
      final state = await mountReaderFor(tester, punct);
      final body = bodyParagraph(tester, 'w0');
      final pageText = body.text.toPlainText().trim();

      final g = await tester.startGesture(globalForWord(tester, 'w0'));
      await tester.pump(const Duration(milliseconds: 600));
      // The far bottom-right caret is the page's exclusive end, so the final
      // period is inside the selection.
      await g.moveTo(
        body.localToGlobal(Offset(body.size.width - 2, body.size.height - 2)),
      );
      await tester.pump();
      await g.up();
      await tester.pumpAndSettle();

      final selected = state.debugSelectionText!;
      expect(selected, pageText);
      expect(selected.endsWith('.'), isTrue);

      final size = tester.getSize(find.byType(ReaderScreen));
      await tester.tapAt(Offset(size.width * 0.85, size.height * 0.5));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('selectionHandleEnd')), findsOneWidget);
    });

    testWidgets('stops short of the page edge and flips to no end handle', (
      tester,
    ) async {
      await mountReaderFor(tester, punct);
      final body = bodyParagraph(tester, 'w0');
      final pageText = body.text.toPlainText().trim();
      final lastToken = pageText.split(RegExp(r'\s+')).last;
      final lastWord = lastToken.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');

      final g = await tester.startGesture(globalForWord(tester, 'w0'));
      await tester.pump(const Duration(milliseconds: 600));
      // Mid-word: the caret never reaches the final period, so the page's
      // last character is not covered.
      await g.moveTo(globalForWord(tester, lastWord));
      await tester.pump();
      await g.up();
      await tester.pumpAndSettle();

      // The handle belongs on this page at the selection end...
      expect(find.byKey(const Key('selectionHandleEnd')), findsOneWidget);

      // ...but the selection offers no continuation on the next page.
      final size = tester.getSize(find.byType(ReaderScreen));
      await tester.tapAt(Offset(size.width * 0.85, size.height * 0.5));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('selectionHandleEnd')), findsNothing);
    });
  });

  testWidgets('tapping an in-book link jumps and clears the selection', (
    tester,
  ) async {
    final state = await mountReaderFor(
      tester,
      await makeBook('test/fixtures/epub/inbook-links.epub', 'Link Book'),
    );
    // The contents page's "Footnote" link jumps to a later chapter, so the
    // selection must clear and the reader must land on a page whose body reads
    // "Third body ... at the foot.".
    await tester.longPressAt(globalForWord(tester, 'Footnote'));
    await tester.pumpAndSettle();
    expect(state.debugSelection.isActive, isTrue);
    expect(find.text('Define'), findsOneWidget);

    await tester.tapAt(globalForWord(tester, 'Footnote'));
    await tester.pumpAndSettle();
    expect(state.debugSelection.isActive, isFalse);
    expect(find.text('Define'), findsNothing);

    // The tap must have followed the link, not merely cleared the selection
    // (a centre-zone clear would satisfy the assertion above).
    var jumped =
        visibleText(tester).contains('Third body') ||
        visibleText(tester).contains('at the foot.');
    for (var i = 0; i < 400 && !jumped; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      jumped =
          visibleText(tester).contains('Third body') ||
          visibleText(tester).contains('at the foot.');
    }
    expect(
      jumped,
      isTrue,
      reason: 'the link tap must jump to the footnote target',
    );
  });
}
