// Reversal test (Task 11): the engine flag stays reversible after the
// default flips to `rust`. `createEpubEngine(dartEpubEngineId)` must keep
// working with no revert — the Dart engine remains a usable fallback behind
// the flag. A persisted `dart` value must survive `load` after the flip.
import 'dart:io';

import 'package:drift/native.dart';
import 'package:burrow/db/database.dart';
import 'package:burrow/services/document_parser.dart';
import 'package:burrow/services/epub/epub_engine_factory.dart';
import 'package:burrow/services/library_service.dart';
import 'package:flutter_test/flutter_test.dart';
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

  test('switching back to dart needs no revert', () async {
    final engine = createEpubEngine(dartEpubEngineId);
    expect(
      await engine.parse('test/fixtures/epub/minimal.epub'),
      isA<ParsedDocument>(),
    );
  });

  test('rust engine falls back to Dart for non-EPUB books', () async {
    // The reader opens every reflowable format through the engine seam, so a
    // TXT book must parse under the `rust` default without touching FFI.
    final tmp = await Directory.systemTemp.createTemp('burrow_engine_txt');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final book = File('${tmp.path}/notes.txt');
    await book.writeAsString('Hello.\n\nSecond paragraph.\n');
    final doc = await createEpubEngine(rustEpubEngineId).parse(book.path);
    expect(doc.chapters, isNotEmpty);
    expect(doc.chapters.first.body, contains('Hello.'));
  });

  group('engine flag persistence after the rust flip', () {
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

    test('a persisted dart value is honoured by load', () async {
      final service = await loadWithPrefs({
        'burrow.epub.engine.v1': dartEpubEngineId,
      });
      expect(service.epubEngine, dartEpubEngineId);
    });

    test('saveEpubEngine round-trips dart then rust', () async {
      final service = await loadWithPrefs({});
      await service.saveEpubEngine(dartEpubEngineId);
      expect(service.epubEngine, dartEpubEngineId);
      await service.saveEpubEngine(rustEpubEngineId);
      expect(service.epubEngine, rustEpubEngineId);
    });
  });
}
