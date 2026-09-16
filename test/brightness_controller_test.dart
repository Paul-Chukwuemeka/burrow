import 'package:burrow/models/reader_settings.dart';
import 'package:burrow/services/brightness_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BrightnessController', () {
    test('apply(null) resets to system brightness', () async {
      final log = <String>[];
      final ctrl = BrightnessController(
        setBrightness: (v) async => log.add('set:$v'),
        resetBrightness: () async => log.add('reset'),
      );
      await ctrl.apply(null);
      expect(log, contains('reset'));
    });

    test('apply(level) sets the brightness', () async {
      final log = <String>[];
      final ctrl = BrightnessController(
        setBrightness: (v) async => log.add('set:$v'),
        resetBrightness: () async => log.add('reset'),
      );
      await ctrl.apply(0.6);
      expect(log, contains('set:0.6'));
    });

    test('apply clamps to kMinBrightness', () async {
      final log = <String>[];
      final ctrl = BrightnessController(
        setBrightness: (v) async => log.add('set:$v'),
        resetBrightness: () async {},
      );
      await ctrl.apply(0.0);
      expect(log, contains('set:$kMinBrightness'));
    });

    test('apply clamps to 1.0', () async {
      final log = <String>[];
      final ctrl = BrightnessController(
        setBrightness: (v) async => log.add('set:$v'),
        resetBrightness: () async {},
      );
      await ctrl.apply(2.0);
      expect(log, contains('set:1.0'));
    });

    test('reset is equivalent to apply(null)', () async {
      final log = <String>[];
      final ctrl = BrightnessController(
        resetBrightness: () async => log.add('reset'),
      );
      await ctrl.reset();
      expect(log, contains('reset'));
    });

    test('current reads brightness via getter', () async {
      final ctrl = BrightnessController(getCurrent: () async => 0.45);
      expect(await ctrl.current(), 0.45);
    });

    test('current returns 1.0 when getter throws', () async {
      final ctrl = BrightnessController(
        getCurrent: () async => throw Exception('not available'),
      );
      expect(await ctrl.current(), 1.0);
    });

    test('apply swallows exceptions from setBrightness', () async {
      final ctrl = BrightnessController(
        setBrightness: (v) async => throw Exception('not available'),
        resetBrightness: () async => throw Exception('not available'),
      );
      // Should not throw.
      await ctrl.apply(0.5);
      await ctrl.reset();
    });

    // Regression tests for #145: an unvalidated plugin seed (0.0/NaN)
    // reached the chrome Slider and tripped its range assertion.
    group('seed clamping (#145)', () {
      test('current clamps a 0.0 seed up to kMinBrightness', () async {
        final ctrl = BrightnessController(getCurrent: () async => 0.0);
        expect(await ctrl.current(), kMinBrightness);
      });

      test('current maps a NaN seed to 1.0', () async {
        final ctrl = BrightnessController(getCurrent: () async => double.nan);
        expect(await ctrl.current(), 1.0);
      });

      test('current clamps a seed above 1.0', () async {
        final ctrl = BrightnessController(getCurrent: () async => 2.0);
        expect(await ctrl.current(), 1.0);
      });

      testWidgets('seeded Slider value stays in range', (tester) async {
        final ctrl = BrightnessController(getCurrent: () async => 0.0);
        final seed = await ctrl.current();
        // What the chrome slider receives after the #145 clamp.
        final sliderValue = seed.clamp(kMinBrightness, 1.0);
        expect(sliderValue, inInclusiveRange(kMinBrightness, 1.0));
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Slider(
                value: sliderValue,
                min: kMinBrightness,
                max: 1.0,
                onChanged: (_) {},
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
      });
    });
  });
}
