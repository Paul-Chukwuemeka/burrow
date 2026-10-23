import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:burrow/services/external_dictionary_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('burrow/dictionary_out');
  List<Object?>? nextApps;
  bool launchResult = true;
  bool throwMissingPlugin = false;
  Object? defineArgs;

  setUp(() {
    nextApps = null;
    launchResult = true;
    throwMissingPlugin = false;
    defineArgs = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (throwMissingPlugin) throw MissingPluginException();
          switch (call.method) {
            case 'listDefineApps':
              return nextApps;
            case 'defineWith':
              defineArgs = call.arguments;
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

  test('parses apps and drops malformed entries', () async {
    nextApps = [
      {'packageName': 'a', 'label': 'A Dict'},
      {'nope': 1},
      42,
      null,
    ];

    final apps = await ExternalDictionaryService.listApps();

    expect(apps, hasLength(1));
    expect(apps.single.packageName, 'a');
    expect(apps.single.label, 'A Dict');
  });

  test('missing bridge drains to empty list', () async {
    throwMissingPlugin = true;

    expect(await ExternalDictionaryService.listApps(), isEmpty);
  });

  test('reports launch truthfully', () async {
    launchResult = false;
    expect(await ExternalDictionaryService.launch('a', 'x'), isFalse);

    launchResult = true;
    expect(await ExternalDictionaryService.launch('a', 'x'), isTrue);
  });

  test('launch falsifies when bridge missing', () async {
    throwMissingPlugin = true;

    expect(await ExternalDictionaryService.launch('a', 'x'), isFalse);
  });

  test('sends exact argument map with trimmed word', () async {
    await ExternalDictionaryService.launch('net.guten.cpp', '  example  ');

    expect(
      defineArgs,
      {'packageName': 'net.guten.cpp', 'word': 'example'},
    );
  });
}
