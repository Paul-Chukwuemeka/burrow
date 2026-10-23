import 'dart:io';

import 'package:burrow/models/book.dart';
import 'package:burrow/screens/reader_screen.dart';
import 'package:burrow/services/brightness_controller.dart';
import 'package:burrow/services/library_service.dart';
import 'package:burrow/src/rust/frb_generated.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

class _FakeWakelock extends WakelockPlusPlatformInterface {
  @override
  Future<bool> get enabled async => false;
  @override
  Future<void> toggle({required bool enable}) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  late Directory tmp;
  late LibraryService library;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    WakelockPlusPlatformInterface.instance = _FakeWakelock();
    BrightnessController.instance = BrightnessController(
      getCurrent: () async => 0.5,
      setBrightness: (_) async {},
      resetBrightness: () async {},
    );
    tmp = await Directory.systemTemp.createTemp('burrow_search_fullscreen');
    await File('${tmp.path}/Search Book.txt').writeAsString(
      'Chapter One\n\nAlpha needle beta.\n\nChapter Two\n\nGamma needle delta.\n',
    );
    library = LibraryService();
  });

  tearDown(() async {
    BrightnessController.instance = BrightnessController();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  testWidgets('search overlay fills the screen', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(412, 915);
    addTearDown(tester.view.reset);
    addTearDown(() => tester.pumpWidget(const SizedBox()));

    final book = Book(
      id: 'search-book',
      title: 'Search Book',
      author: 'Author',
      path: '${tmp.path}/Search Book.txt',
      format: BookFormat.txt,
      addedAt: 1000,
    );

    await tester.pumpWidget(
      MaterialApp(home: ReaderScreen(book: book, library: library)),
    );
    final state = tester.state<ReaderScreenState>(find.byType(ReaderScreen));
    for (var i = 0; i < 200 && !state.debugHasDocument; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(state.debugHasDocument, isTrue);

    // Finish the full-book layout so the page view is on screen.
    for (var i = 0; i < 4000 && !state.debugAllReady; i++) {
      await tester.pump();
    }
    await tester.pump();

    // Show the reader chrome, then open search.
    await tester.tapAt(const Offset(206, 457));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();

    final overlay = find.byKey(const Key('reader-search-overlay'));
    expect(overlay, findsOneWidget);
    expect(tester.getSize(overlay), const Size(412, 915));
  });
}
