// The Settings "Dictionary" tile shows the current default-dictionary
// choice, opens the picker in management mode, and refreshes after a change.
import 'package:burrow/models/reader_settings.dart';
import 'package:burrow/screens/settings_screen.dart';
import 'package:burrow/services/library_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Finder _tileIcon() => find.byIcon(Icons.translate);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('burrow/dictionary_out');
  List<Object?>? nextApps = [
    {'packageName': 'net.guten.cpp', 'label': 'Guten Dict'},
  ];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'listDefineApps') return nextApps;
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<LibraryService> pumpSettings(WidgetTester tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final service = LibraryService();
    await tester.pumpWidget(
      MaterialApp(home: SettingsScreen(library: service)),
    );
    await tester.pumpAndSettle();
    return service;
  }

  /// Scrolls the Dictionary tile into view; the section sits below the fold
  /// and the ListView builds children lazily, so ensureVisible can't find it
  /// until it has been scrolled toward. Drags (no fling momentum) in steps,
  /// checking for the tile between steps so it can't be overshot.
  Future<void> ensureTileBuilt(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      if (tester.widgetList(_tileIcon()).isNotEmpty) return;
      await tester.drag(
        find.byType(ListView).first,
        const Offset(0, -250),
      );
      await tester.pumpAndSettle();
    }
    fail('Dictionary tile never scrolled into view');
  }

  Future<void> openTile(WidgetTester tester) async {
    await ensureTileBuilt(tester);
    final tile = find.ancestor(
      of: _tileIcon(),
      matching: find.byType(ListTile),
    );
    await tester.tap(tile);
    await tester.pumpAndSettle();
  }

  testWidgets('tile exists and shows ask-every-time with no default', (
    tester,
  ) async {
    await pumpSettings(tester);
    await ensureTileBuilt(tester);

    expect(find.text('Dictionary'), findsWidgets);
    expect(find.text('Ask every time'), findsOneWidget);
  });

  testWidgets('subtitle names the pinned external app', (tester) async {
    final service = LibraryService()
      ..settings.defaultDictionary = 'net.guten.cpp';
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: SettingsScreen(library: service)),
    );
    await tester.pumpAndSettle();
    await ensureTileBuilt(tester);

    expect(find.text('Guten Dict (always)'), findsOneWidget);
  });

  testWidgets('tile opens the picker; choosing Burrow persists and relabels', (
    tester,
  ) async {
    final service = await pumpSettings(tester);

    await openTile(tester);

    expect(find.text('Define with Burrow'), findsOneWidget);

    await tester.tap(find.text('Define with Burrow'));
    await tester.pumpAndSettle();

    expect(service.settings.defaultDictionary, burrowDefaultDictionary);
    await ensureTileBuilt(tester);
    expect(find.text('Built-in (always)'), findsOneWidget);
  });

  testWidgets('choosing Ask every time resets the default', (tester) async {
    final service = LibraryService()
      ..settings.defaultDictionary = 'net.guten.cpp';
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: SettingsScreen(library: service)),
    );
    await tester.pumpAndSettle();

    await openTile(tester); // opens in management mode

    // The tile subtitle behind the sheet also says "Ask every time"; the
    // picker's row is the last match.
    await tester.tap(find.text('Ask every time').last);
    await tester.pumpAndSettle();

    expect(service.settings.defaultDictionary, isNull);
    await ensureTileBuilt(tester);
    expect(find.text('Ask every time'), findsOneWidget);
  });
}
