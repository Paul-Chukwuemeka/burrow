import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/reader_settings.dart';

/// One external dictionary app registered on the device for word
/// definitions.
class ExternalDictionaryApp {
  final String packageName;
  final String label;

  const ExternalDictionaryApp({
    required this.packageName,
    required this.label,
  });
}

/// Queries and launches external dictionary apps via the
/// `burrow/dictionary_out` channel bridged in MainActivity. Non-Android
/// platforms and tests without a mock bridge drain empty / launch false.
abstract final class ExternalDictionaryService {
  static const MethodChannel _channel = MethodChannel(
    'burrow/dictionary_out',
  );

  /// Marker stored in [ReaderSettings.defaultDictionary] for the built-in
  /// dictionary.
  static const String burrowChoice = burrowDefaultDictionary;

  /// Apps registered for android.intent.action.DEFINE — apps the device
  /// treats as definition handlers. Our own package is excluded natively.
  /// Never throws: a missing bridge or malformed payload drains as no apps.
  static Future<List<ExternalDictionaryApp>> listApps() async {
    List<Object?> raw;
    try {
      raw = await _channel.invokeListMethod<Object?>('listDefineApps') ??
          const [];
    } on PlatformException catch (e) {
      debugPrint('ExternalDictionaryService: bridge unavailable ($e)');
      return const [];
    } on MissingPluginException {
      return const [];
    }
    final apps = <ExternalDictionaryApp>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final pkg = entry['packageName'];
      final label = entry['label'];
      if (pkg is String && pkg.isNotEmpty) {
        apps.add(
          ExternalDictionaryApp(
            packageName: pkg,
            label: label is String && label.isNotEmpty ? label : pkg,
          ),
        );
      }
    }
    return apps;
  }

  /// Launches the external dictionary app [packageName] on [word].
  ///
  /// Returns true only when the launch was handed to the OS; false when the
  /// package no longer resolves, the launch throws, or the bridge is
  /// missing.
  static Future<bool> launch(String packageName, String word) async {
    try {
      final sent = await _channel.invokeMethod<bool>('defineWith', {
        'packageName': packageName,
        'word': word.trim(),
      });
      return sent ?? false;
    } on PlatformException catch (e) {
      debugPrint('ExternalDictionaryService: launch failed ($e)');
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
