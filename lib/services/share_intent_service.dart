import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Receives book files shared from other Android apps (WhatsApp, file
/// managers, browsers) via the `burrow/share_in` channel bridged in
/// MainActivity. Non-Android platforms have no bridge and always drain empty.
abstract final class ShareIntentService {
  static const MethodChannel _channel = MethodChannel('burrow/share_in');

  /// File extensions Burrow can open. Anything else is reported back so the
  /// caller can explain the rejection instead of importing garbage
  /// ([formatFromExtension] would otherwise misfile it as TXT).
  static const supportedExtensions = {'epub', 'pdf', 'txt', 'cbz', 'cbr'};

  static bool isSupported(String path) {
    final dot = path.toLowerCase().lastIndexOf('.');
    if (dot < 0) return false;
    return supportedExtensions.contains(path.toLowerCase().substring(dot + 1));
  }

  /// Returns paths staged by the native bridge since the last drain, split
  /// into openable books and rejected files. Never throws: a missing bridge
  /// or malformed payload drains as nothing shared.
  static Future<({List<String> supported, int unsupported})>
  drainSharedFiles() async {
    List<Object?> raw;
    try {
      raw = await _channel.invokeListMethod<Object?>('getSharedFiles') ?? const [];
    } on PlatformException catch (e) {
      debugPrint('ShareIntentService: bridge unavailable ($e)');
      return (supported: <String>[], unsupported: 0);
    } on MissingPluginException {
      // Non-Android platforms and widget tests without a mock bridge.
      return (supported: <String>[], unsupported: 0);
    }
    final supported = <String>[];
    var unsupported = 0;
    for (final entry in raw) {
      if (entry is! String || entry.isEmpty) continue;
      if (isSupported(entry)) {
        supported.add(entry);
      } else {
        unsupported++;
      }
    }
    return (supported: supported, unsupported: unsupported);
  }
}
