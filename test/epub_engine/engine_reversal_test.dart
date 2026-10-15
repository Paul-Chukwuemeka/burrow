// Engine-flag retirement test (retire-dart-engine Task 7).
//
// The engine flag is retired: `rust` is the only engine. The factory rejects
// the removed `dart` id outright, and a stale persisted `dart` value is
// normalized to Rust at load — the reader and metadata worker can never
// resolve a removed engine.
import 'dart:io';

import 'package:drift/native.dart';
import 'package:burrow/db/database.dart';
import 'package:burrow/models/document.dart';
import 'package:burrow/services/epub/epub_engine_factory.dart';
import 'package:burrow/services/library_service.dart';
import 'package:burrow/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.documentsPath);
  final String documentsPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => documentsPath;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  test('the factory rejects the retired dart id', () {
    expect(() => createEpubEngine('dart'), throwsArgumentError);
  });

  test('the rust engine parses through the seam', () async {
    final engine = createEpubEngine(rustEpubEngineId);
    expect(
      await engine.parse('test/fixtures/epub/minimal.epub'),
      isA<ParsedDocument>(),
    );
  });

  group('engine flag persistence after the Dart retirement', () {
    late Directory tempDir;

    setUpAll(() {
      tempDir = Directory.systemTemp.createTempSync('burrow_engine_flag');
      PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    });

    tearDownAll(() {
      tempDir.deleteSync(recursive: true);
    });

    Future<LibraryService> loadWithPrefs(Map<String, Object> prefs) async {
      SharedPreferences.setMockInitialValues(prefs);
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final service = LibraryService();
      service.debugAttachDatabase(db);
      await service.load();
      return service;
    }

    test('default is rust when no value is persisted', () async {
      final service = await loadWithPrefs({});
      expect(service.epubEngine, rustEpubEngineId);
    });

    test('a stale persisted dart value is normalized to rust', () async {
      final service = await loadWithPrefs({
        'burrow.epub.engine.v1': 'dart',
      });
      expect(service.epubEngine, rustEpubEngineId);
    });
  });
}
