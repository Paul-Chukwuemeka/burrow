// Inbound define word: another app sends Burrow a definition lookup (the
// system Define menu picking Burrow, or a ColorDict-style lookup). The
// library drains the word off the share channel and resolves it through the
// same dictionary router as in-reader lookups.
import 'package:burrow/models/reader_settings.dart';
import 'package:burrow/screens/library_screen.dart';
import 'package:burrow/services/library_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> launches;
  String? pendingWord;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    launches = [];
    pendingWord = 'Serendipity';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('burrow/share_in'),
          (call) async {
            if (call.method == 'getSharedFiles') return <Object?>[];
            // Consume-once: the native bridge hands a word out a single time.
            if (call.method == 'getDefineWord') {
              final word = pendingWord;
              pendingWord = null;
              return word;
            }
            return null;
          },
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('burrow/dictionary_out'),
          (call) async {
            if (call.method == 'defineWith') return launches.add(call);
            return null;
          },
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('burrow/share_in'), null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('burrow/dictionary_out'),
          null,
        );
  });

  Future<LibraryService> pumpLibrary(WidgetTester tester) async {
    final library = LibraryService()
      ..settings.defaultDictionary = 'com.test.day';
    addTearDown(library.dispose);
    await tester.pumpWidget(
      MaterialApp(home: LibraryScreen(library: library, autoScanOnOpen: false)),
    );
    await tester.pumpAndSettle();
    return library;
  }

  testWidgets('a pending define word resolves through the default dictionary', (
    tester,
  ) async {
    await pumpLibrary(tester);

    expect(launches, hasLength(1));
    expect(launches.single.method, 'defineWith');
    final args = launches.single.arguments! as Map<dynamic, dynamic>;
    expect(args['packageName'], 'com.test.day');
    // The word is normalized the same way in-reader lookups are: lookups are
    // definition queries, not verbatim echo.
    expect(args['word'], 'serendipity');
  });

  testWidgets('a drained word is never handed out twice', (tester) async {
    await pumpLibrary(tester);
    expect(launches, hasLength(1));

    // Relaunching into the foreground re-drains (like a share would) but the
    // consumed word produces no second launch.
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
    await tester.pumpAndSettle();

    expect(launches, hasLength(1));
  });
}
