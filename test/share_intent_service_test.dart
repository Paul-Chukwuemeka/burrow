import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:burrow/services/share_intent_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('burrow/share_in');
  List<Object?>? nextPayload;
  bool throwMissingPlugin = false;

  setUp(() {
    nextPayload = null;
    throwMissingPlugin = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (throwMissingPlugin) throw MissingPluginException();
          if (call.method != 'getSharedFiles') return null;
          return nextPayload;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('splits supported books from rejected files', () async {
    nextPayload = [
      '/data/a.epub',
      '/data/b.PDF',
      '/data/c.cbz',
      '/data/photo.jpg',
      '/data/note',
      '',
      null,
      42,
    ];

    final result = await ShareIntentService.drainSharedFiles();

    expect(result.supported, ['/data/a.epub', '/data/b.PDF', '/data/c.cbz']);
    expect(result.unsupported, 2);
  });

  test('empty share drains quietly', () async {
    nextPayload = [];

    final result = await ShareIntentService.drainSharedFiles();

    expect(result.supported, isEmpty);
    expect(result.unsupported, 0);
  });

  test('missing bridge drains as nothing shared', () async {
    throwMissingPlugin = true;

    final result = await ShareIntentService.drainSharedFiles();

    expect(result.supported, isEmpty);
    expect(result.unsupported, 0);
  });

  test('define word drains once, then nothing', () async {
    final seen = <String>[];
    String? word = 'serendipity';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (throwMissingPlugin) throw MissingPluginException();
          if (call.method != 'getDefineWord') return null;
          seen.add(call.method);
          final pending = word;
          word = null;
          return pending;
        });

    expect(await ShareIntentService.drainDefineWord(), 'serendipity');
    expect(await ShareIntentService.drainDefineWord(), isNull);
    expect(seen, ['getDefineWord', 'getDefineWord']);
  });

  test('missing bridge drains no define word and never throws', () async {
    throwMissingPlugin = true;

    expect(await ShareIntentService.drainDefineWord(), isNull);
  });

  test('isSupported matches the five book extensions', () {
    expect(ShareIntentService.isSupported('a.epub'), isTrue);
    expect(ShareIntentService.isSupported('a.EPUB'), isTrue);
    expect(ShareIntentService.isSupported('a.pdf'), isTrue);
    expect(ShareIntentService.isSupported('a.txt'), isTrue);
    expect(ShareIntentService.isSupported('a.cbz'), isTrue);
    expect(ShareIntentService.isSupported('a.cbr'), isTrue);
    expect(ShareIntentService.isSupported('a.zip'), isFalse);
    expect(ShareIntentService.isSupported('a.jpg'), isFalse);
    expect(ShareIntentService.isSupported('noextension'), isFalse);
  });
}
