import 'package:flutter/foundation.dart';
import 'package:screen_brightness/screen_brightness.dart';

import '../models/reader_settings.dart';

/// Thin wrapper around [ScreenBrightness] so the plugin isn't sprayed across
/// the UI and tests have a seam.
class BrightnessController {
  BrightnessController({
    Future<double> Function()? getCurrent,
    Future<void> Function(double)? setBrightness,
    Future<void> Function()? resetBrightness,
  }) : _getCurrent = getCurrent ?? _defaultGet,
       _setBrightness = setBrightness ?? _defaultSet,
       _resetBrightness = resetBrightness ?? _defaultReset;

  final Future<double> Function() _getCurrent;
  final Future<void> Function(double) _setBrightness;
  final Future<void> Function() _resetBrightness;

  static BrightnessController instance = BrightnessController();

  /// Apply a saved brightness level. [null] means follow system; any other
  /// value is clamped to [kMinBrightness]..1.0 before being set.
  Future<void> apply(double? level) async {
    try {
      if (level == null) {
        await _resetBrightness();
      } else {
        await _setBrightness(level.clamp(kMinBrightness, 1.0));
      }
    } catch (e) {
      debugPrint('BrightnessController.apply failed: $e');
    }
  }

  /// Reset to system brightness (same as `apply(null)` but more explicit at
  /// call sites that don't carry a saved value).
  Future<void> reset() => apply(null);

  /// Read the current application brightness for seeding the slider.
  /// Falls back to system brightness, then 1.0.
  Future<double> current() async {
    try {
      return await _getCurrent();
    } catch (_) {
      return 1.0;
    }
  }
}

// Default implementations that call the real plugin.
Future<double> _defaultGet() async {
  try {
    return await ScreenBrightness.instance.application;
  } catch (_) {
    try {
      return await ScreenBrightness.instance.system;
    } catch (_) {
      return 1.0;
    }
  }
}

Future<void> _defaultSet(double v) =>
    ScreenBrightness.instance.setApplicationScreenBrightness(v);

Future<void> _defaultReset() =>
    ScreenBrightness.instance.resetApplicationScreenBrightness();
