// Tapping a painted highlight in the reflowable reader opens its actions, and
// deleting from there removes it with an undo path. The Notes tab is not the
// only way to edit or remove a highlight.
import 'dart:io';

import 'package:burrow/db/database.dart';
import 'package:burrow/models/book.dart';
import 'package:burrow/screens/reader_screen.dart';
import 'package:burrow/services/brightness_controller.dart';
import 'package:burrow/services/library_service.dart';
import 'package:burrow/src/rust/frb_generated.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

class _FakeWakelock extends WakelockPlusPlatformInterface {
  @override
  Future<void> toggle({required bool enable}) async {}
  @override
  Future<bool> get enabled async => false;
}

RenderParagraph _bodyParagraph(WidgetTester tester, String needle) => tester
    .renderObjectList<RenderParagraph>(find.byType(RichText))
    .firstWhere((p) => p.text.toPlainText().contains(needle));

Offset _globalForWord(WidgetTester tester, String word) {
  final p = _bodyParagraph(tester, word);
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

void main() {
  setUpAll(() async {
    await RustLib.init();
  });

  late Directory tmp;
  late AppDatabase database;
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
    tmp = await Directory.systemTemp.createTemp('burrow_highlight_actions');
    database = AppDatabase.forTesting(NativeDatabase.memory());
    library = LibraryService()..debugAttachDatabase(database);

    final dest = '${tmp.path}/Minimal Book.epub';
    File(dest).writeAsBytesSync(
      File('test/fixtures/epub/minimal.epub').readAsBytesSync(),
    );
    book = Book(
      id: 'b1',
      title: 'Minimal Book',
      author: 'A. Author',
      path: dest,
      format: BookFormat.epub,
      addedAt: 1000,
    );
    await database.insertBook(bookToCompanion(book));
  });

  tearDown(() async {
    BrightnessController.instance = BrightnessController();
    await database.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<ReaderScreenState> mount(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(412, 915);
    addTearDown(tester.view.reset);
    addTearDown(() => tester.pumpWidget(const SizedBox()));

    await tester.pumpWidget(
      MaterialApp(
        home: ReaderScreen(book: book, library: library),
      ),
    );
    final state = tester.state<ReaderScreenState>(find.byType(ReaderScreen));
    for (var i = 0; i < 200; i++) {
      if (state.debugHasDocument) break;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(state.debugHasDocument, isTrue);
    for (var i = 0; i < 200 && !state.debugAllReady; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(state.debugAllReady, isTrue);
    await tester.pumpAndSettle();
    return state;
  }

  testWidgets('tapping a highlight opens its actions and delete undoes', (
    tester,
  ) async {
    final body = (await mount(tester)).debugChapterBody(0);
    final start = body.indexOf('first');
    expect(start, greaterThanOrEqualTo(0));
    await tester.pumpWidget(const SizedBox());

    final id = await library.addHighlight(
      bookId: 'b1',
      text: body.substring(start, start + 'first'.length),
      chapter: 0,
      startOffset: start,
      endChapter: 0,
      endOffset: start + 'first'.length,
    );
    expect(await library.countHighlightsForBook('b1'), 1);

    await mount(tester);
    await tester.tapAt(_globalForWord(tester, 'first'));
    await tester.pumpAndSettle();

    expect(find.text('Edit note'), findsOneWidget);
    expect(find.text('Delete highlight'), findsOneWidget);

    await tester.tap(find.text('Delete highlight'));
    await tester.pumpAndSettle();

    expect(find.text('Highlight deleted'), findsOneWidget);
    expect(await library.countHighlightsForBook('b1'), 0);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();

    expect(await library.countHighlightsForBook('b1'), 1);
    final rows = await library.getHighlights('b1');
    expect(rows.single.id, isNot(id));
    expect(rows.single.quote, 'first');
  });

  testWidgets('tapping plain text does not open the highlight sheet', (
    tester,
  ) async {
    final body = (await mount(tester)).debugChapterBody(0);
    final start = body.indexOf('first');
    await tester.pumpWidget(const SizedBox());
    await library.addHighlight(
      bookId: 'b1',
      text: body.substring(start, start + 'first'.length),
      chapter: 0,
      startOffset: start,
      endChapter: 0,
      endOffset: start + 'first'.length,
    );

    await mount(tester);
    final words = body.split(RegExp(r'\s+'));
    final other = words.firstWhere((w) => w != 'first' && w.length > 2);
    await tester.tapAt(_globalForWord(tester, other));
    await tester.pumpAndSettle();

    expect(find.text('Delete highlight'), findsNothing);
  });

  testWidgets('a highlight with a note offers Open note', (tester) async {
    final body = (await mount(tester)).debugChapterBody(0);
    final start = body.indexOf('first');
    await tester.pumpWidget(const SizedBox());
    await library.addHighlight(
      bookId: 'b1',
      text: body.substring(start, start + 'first'.length),
      chapter: 0,
      startOffset: start,
      endChapter: 0,
      endOffset: start + 'first'.length,
      note: 'my thought',
    );

    await mount(tester);
    await tester.tapAt(_globalForWord(tester, 'first'));
    await tester.pumpAndSettle();

    expect(find.text('Open note'), findsOneWidget);

    await tester.tap(find.text('Open note'));
    await tester.pumpAndSettle();

    expect(find.text('my thought'), findsOneWidget);

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'updated');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final rows = await library.getHighlights('b1');
    expect(rows.single.note, 'updated');
  });
}
