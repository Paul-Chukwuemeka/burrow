import 'package:burrow/models/reader_settings.dart';
import 'package:burrow/services/dictionary_router.dart';
import 'package:burrow/services/library_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('burrow/dictionary_out');
  List<Object?>? nextApps;
  bool launchResult = true;
  bool throwMissingPlugin = false;
  final defineCalls = <Map<String, dynamic>>[];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    nextApps = [
      {'packageName': 'net.a', 'label': 'App A'},
      {'packageName': 'net.b', 'label': 'App B'},
    ];
    launchResult = true;
    throwMissingPlugin = false;
    defineCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (throwMissingPlugin) throw MissingPluginException();
          switch (call.method) {
            case 'listDefineApps':
              return nextApps;
            case 'defineWith':
              defineCalls.add(
                Map<String, dynamic>.from(call.arguments as Map),
              );
              return launchResult;
            default:
              return null;
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<LibraryService> pumpRouter(
    WidgetTester tester, {
    String? word,
    LibraryService? lib,
  }) async {
    final service = lib ?? LibraryService();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () =>
                    DictionaryRouter.resolve(
                      context,
                      library: service,
                      theme: service.settings.colors,
                      word: word,
                    ),
                child: const Text('define'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('define'));
    await tester.pumpAndSettle();
    return service;
  }

  testWidgets('ask mode with two apps shows the picker', (tester) async {
    final lib = await pumpRouter(tester, word: 'sample');

    expect(find.text('Define with Burrow'), findsOneWidget);
    expect(find.text('App A'), findsOneWidget);
    expect(find.text('App B'), findsOneWidget);
    expect(defineCalls, isEmpty);
    expect(lib.settings.defaultDictionary, isNull);
  });

  testWidgets('tapping an app row launches it once, does not persist', (
    tester,
  ) async {
    final lib = await pumpRouter(tester, word: 'sample');

    await tester.tap(find.text('App A'));
    await tester.pumpAndSettle();

    expect(
      defineCalls.single,
      {'packageName': 'net.a', 'word': 'sample'},
    );
    expect(lib.settings.defaultDictionary, isNull);
    expect(find.text('Define with Burrow'), findsNothing);
  });

  testWidgets('pinning an app persists the default', (tester) async {
    final lib = await pumpRouter(tester, word: 'sample');

    final tile = find.ancestor(
      of: find.text('App A'),
      matching: find.byType(ListTile),
    );
    await tester.tap(find.descendant(
      of: tile,
      matching: find.byTooltip('Always'),
    ));
    await tester.pumpAndSettle();

    expect(lib.settings.defaultDictionary, 'net.a');
    expect(
      defineCalls.single,
      {'packageName': 'net.a', 'word': 'sample'},
    );
  });

  testWidgets('default external, launch succeeds → sheet skipped', (
    tester,
  ) async {
    final lib = LibraryService();
    lib.settings.defaultDictionary = 'net.a';
    await pumpRouter(tester, word: 'sample', lib: lib);

    expect(find.text('Define with Burrow'), findsNothing);
    expect(find.text('App A'), findsNothing);
    expect(defineCalls.single, {
      'packageName': 'net.a',
      'word': 'sample',
    });
  });

  testWidgets('default external, app gone → picker and revert', (
    tester,
  ) async {
    final lib = LibraryService();
    lib.settings.defaultDictionary = 'net.gone';
    launchResult = false;

    await pumpRouter(tester, word: 'sample', lib: lib);

    expect(find.text('Define with Burrow'), findsOneWidget);
    expect(find.text('App A'), findsOneWidget);
    expect(lib.settings.defaultDictionary, isNull);
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('burrow.settings.v1') ?? '';
    expect(raw.contains('net.gone'), isFalse);
  });

  testWidgets('default Burrow opens built-in sheet (download dialog first)',
      (tester) async {
    final lib = LibraryService();
    lib.settings.defaultDictionary = burrowDefaultDictionary;

    await pumpRouter(tester, word: 'sample', lib: lib);

    expect(find.text('Download dictionary?'), findsOneWidget);
    expect(defineCalls, isEmpty);
  });

  testWidgets('no external apps → straight to built-in', (tester) async {
    nextApps = [];
    final lib = await pumpRouter(tester, word: 'sample');

    expect(find.text('Define with Burrow'), findsNothing);
    expect(find.text('Download dictionary?'), findsOneWidget);
    expect(lib.settings.defaultDictionary, isNull);
  });

  testWidgets('management mode shows picker despite default', (tester) async {
    final lib = LibraryService();
    lib.settings.defaultDictionary = 'net.a';

    await pumpRouter(tester, lib: lib); // word: null

    expect(find.text('Ask every time'), findsOneWidget);
    expect(find.text('Define with Burrow'), findsOneWidget);

    await tester.tap(find.text('Ask every time'));
    await tester.pumpAndSettle();

    expect(lib.settings.defaultDictionary, isNull);
  });
}
