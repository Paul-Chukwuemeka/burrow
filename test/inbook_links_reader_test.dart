// In-book links at the reader surface: tapping a link's text on the rendered
// page jumps to the target chapter. The fixture's contents page is chapter 0,
// so its first link ("Part One") must land the reader on chapter 1, whose
// body starts "First body." — and the tap must not also flip the page (it
// sits inside the left 30% prev-zone, so the link check must win).
import 'dart:io';

import 'package:burrow/db/database.dart' as db;
import 'package:burrow/models/book.dart';
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

/// Concatenates the plain text of one RichText's spans.
String _plainOf(InlineSpan span) {
  final buffer = StringBuffer();
  void walk(InlineSpan s) {
    if (s is TextSpan) {
      buffer.write(s.text ?? '');
      for (final child in s.children ?? const <InlineSpan>[]) {
        walk(child);
      }
    }
  }

  walk(span);
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

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    WakelockPlusPlatformInterface.instance = _FakeWakelock();
    BrightnessController.instance = BrightnessController(
      getCurrent: () async => 0.5,
      setBrightness: (_) async {},
      resetBrightness: () async {},
    );
    tmp = await Directory.systemTemp.createTemp('burrow_inbook_links');
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    library = LibraryService();

    final source = File('test/fixtures/epub/inbook-links.epub');
    await File('${tmp.path}/Link Book.epub')
        .writeAsBytes(source.readAsBytesSync());
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  testWidgets('tapping a link jumps to the target chapter', (tester) async {
    final book = Book(
      id: 'b1',
      title: 'Link Book',
      author: 'L. Author',
      path: '${tmp.path}/Link Book.epub',
      format: BookFormat.epub,
      addedAt: 1000,
    );

    await tester.pumpWidget(
      MaterialApp(home: ReaderScreen(book: book, library: library)),
    );
    final state = tester.state<ReaderScreenState>(
      find.byType(ReaderScreen),
    );

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

    // The contents page must be paginated with its link spans alive before
    // anything is tappable.
    RenderParagraph? paragraph;
    for (var i = 0; i < 200 && paragraph == null; i++) {
      final renders = tester
          .renderObjectList<RenderParagraph>(find.byType(RichText))
          .where((p) => p.text.toPlainText().contains('Part One'));
      if (renders.isNotEmpty) {
        paragraph = renders.first;
        break;
      }
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(paragraph, isNotNull, reason: 'the contents page must be rendered');

    // Tap on the caret rect of the link text's middle, laid out with the
    // paragraph's own metrics. It sits inside the prev-zone, so the link
    // check must take precedence over page-flipping.
    final pageText = paragraph!.text.toPlainText();
    final linkOffset = pageText.indexOf('Part One') + 2;
    final painter = TextPainter(
      text: paragraph!.text,
      textDirection: paragraph.textDirection,
    )..layout(maxWidth: paragraph.size.width);
    final caret = painter.getOffsetForCaret(
      TextPosition(offset: linkOffset),
      Rect.zero,
    );
    painter.dispose();
    // The caret sits at the line's top edge; land inside the line box.
    final tapPoint = paragraph!.localToGlobal(caret + const Offset(4, 12));
    await tester.tapAt(tapPoint);

    // The jump unmutes chapter 1 across a (possibly async) pagination pass.
    var jumped = false;
    for (var i = 0; i < 400 && !jumped; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      jumped = tester
          .widgetList<RichText>(find.byType(RichText))
          .map((rt) => _plainOf(rt.text))
          .any((t) => t.contains('First body.'));
    }
    expect(jumped, isTrue, reason: 'the link tap must land on chapter 1');
  });
}
