import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stores the four-digit PIN that gates the Hidden Archive.
///
/// The PIN is never stored in clear text: a random salt and a SHA-256 digest
/// are persisted in SharedPreferences. There is deliberately no in-app
/// recovery flow; forgetting the PIN means the hidden tier cannot be opened.
class ArchivePinService {
  ArchivePinService._();

  /// Preference key holding `salt:hash`. Public for tests and diagnostics.
  static const pinPreferenceKey = 'burrow.archive.pin.v1';

  static final _fourDigits = RegExp(r'^\d{4}$');

  static Future<bool> hasPin() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(pinPreferenceKey);
    return stored != null && stored.isNotEmpty;
  }

  static Future<void> setPin(String pin) async {
    if (!_fourDigits.hasMatch(pin)) {
      throw ArgumentError.value(pin, 'pin', 'must be exactly four digits');
    }
    final salt = _randomSalt();
    final hash = _hash(salt, pin);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(pinPreferenceKey, '$salt:$hash');
  }

  static Future<bool> verifyPin(String pin) async {
    if (!_fourDigits.hasMatch(pin)) return false;
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(pinPreferenceKey);
    if (stored == null) return false;
    final separator = stored.indexOf(':');
    if (separator <= 0) return false;
    final salt = stored.substring(0, separator);
    final expected = stored.substring(separator + 1);
    return _hash(salt, pin) == expected;
  }

  /// Removes the PIN. Only used by tests and by a future explicit reset flow;
  /// the product has no recovery path.
  static Future<void> clearPin() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(pinPreferenceKey);
  }

  static String _randomSalt() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static String _hash(String salt, String pin) =>
      sha256.convert(utf8.encode('$salt:$pin')).toString();
}
