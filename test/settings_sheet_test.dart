import 'package:burrow/models/reader_settings.dart';
import 'package:burrow/services/brightness_controller.dart';
import 'package:burrow/widgets/settings_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Slider order inside the sheet.
const _fontSize = 0;
const _lineHeight = 1;
const _brightness = 2;

Future<void> _pumpSheet(
  WidgetTester tester, {
  required ReaderSettings settings,
  required VoidCallback onChanged,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => SettingsSheet.show(
              context,
              settings: settings,
              onChanged: onChanged,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

/// Drag a slider across many divisions without lifting the finger.
Future<TestGesture> _startDrag(
  WidgetTester tester,
  int index, {
  double dx = 30,
  int steps = 20,
}) async {
  final slider = find.byType(Slider).at(index);
  final gesture = await tester.startGesture(tester.getCenter(slider));
  for (var i = 0; i < steps; i++) {
    await gesture.moveBy(Offset(dx, 0));
    await tester.pump();
  }
  return gesture;
}

void main() {
  setUp(() {
    // Keep the plugin out of widget tests.
    BrightnessController.instance = BrightnessController(
      getCurrent: () async => 0.5,
      setBrightness: (_) async {},
      resetBrightness: () async {},
    );
  });

  tearDown(() {
    BrightnessController.instance = BrightnessController();
  });

  group('SettingsSheet slider commits', () {
    testWidgets('font-size drag notifies once, not once per division',
        (tester) async {
      final settings = ReaderSettings(fontSize: 13);
      var notifications = 0;

      await _pumpSheet(
        tester,
        settings: settings,
        onChanged: () => notifications++,
      );

      final gesture = await _startDrag(tester, _fontSize);

      // Nothing committed while the finger is down.
      expect(notifications, 0);
      // ...but the value tracks the thumb so the label stays live.
      expect(settings.fontSize, greaterThan(13));

      await gesture.up();
      await tester.pumpAndSettle();

      // Crossing this many divisions would have fired repeatedly before.
      expect(settings.fontSize - 13, greaterThan(1.0));
      expect(notifications, 1);
    });

    testWidgets('line-height drag notifies once', (tester) async {
      final settings = ReaderSettings(lineHeight: 1.2);
      var notifications = 0;

      await _pumpSheet(
        tester,
        settings: settings,
        onChanged: () => notifications++,
      );

      final gesture = await _startDrag(tester, _lineHeight);
      expect(notifications, 0);

      await gesture.up();
      await tester.pumpAndSettle();

      expect(settings.lineHeight, greaterThan(1.3));
      expect(notifications, 1);
    });

    testWidgets('brightness drag notifies once and stays live', (tester) async {
      final settings = ReaderSettings(fontSize: 18)..brightness = kMinBrightness;
      var notifications = 0;

      await _pumpSheet(
        tester,
        settings: settings,
        onChanged: () => notifications++,
      );

      final gesture = await _startDrag(tester, _brightness);
      expect(notifications, 0);
      expect(settings.brightness, greaterThan(kMinBrightness));

      await gesture.up();
      await tester.pumpAndSettle();
      expect(notifications, 1);
    });

    testWidgets('debounce commits when onChangeEnd never arrives',
        (tester) async {
      final settings = ReaderSettings(fontSize: 13);
      var notifications = 0;

      await _pumpSheet(
        tester,
        settings: settings,
        onChanged: () => notifications++,
      );

      final gesture = await _startDrag(tester, _fontSize);
      expect(notifications, 0);

      // Finger still down, but the value has settled: the net fires.
      await tester.pump(SettingsSheet.commitDebounce + const Duration(milliseconds: 50));
      expect(notifications, 1);

      // Releasing still commits the final value exactly once more.
      await gesture.up();
      await tester.pumpAndSettle();
      expect(notifications, 2);
    });

    testWidgets('release cancels the pending debounce (no double notify)',
        (tester) async {
      final settings = ReaderSettings(fontSize: 13);
      var notifications = 0;

      await _pumpSheet(
        tester,
        settings: settings,
        onChanged: () => notifications++,
      );

      final gesture = await _startDrag(tester, _fontSize);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(notifications, 1);

      // Well past the debounce window: the timer must have been cancelled.
      await tester.pump(SettingsSheet.commitDebounce * 3);
      expect(notifications, 1);
    });

    testWidgets('dismissing mid-drag leaves no pending timer', (tester) async {
      final settings = ReaderSettings(fontSize: 13);
      var notifications = 0;

      await _pumpSheet(
        tester,
        settings: settings,
        onChanged: () => notifications++,
      );

      final gesture = await _startDrag(tester, _fontSize);
      await gesture.up();
      await tester.pumpAndSettle();

      // Close the sheet; State.dispose must cancel the debounce.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      final afterClose = notifications;

      await tester.pump(SettingsSheet.commitDebounce * 3);
      expect(notifications, afterClose);
    });
  });

  group('SettingsSheet discrete controls', () {
    testWidgets('font-family dropdown notifies once', (tester) async {
      final settings = ReaderSettings();
      var notifications = 0;

      await _pumpSheet(
        tester,
        settings: settings,
        onChanged: () => notifications++,
      );

      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Literata').last);
      await tester.pumpAndSettle();

      expect(settings.fontFamily, 'Literata');
      expect(notifications, 1);
    });

    testWidgets('theme dot notifies once', (tester) async {
      final settings = ReaderSettings(readerTheme: ReaderThemeMode.sepia);
      var notifications = 0;

      await _pumpSheet(
        tester,
        settings: settings,
        onChanged: () => notifications++,
      );

      await tester.tap(find.byIcon(Icons.dark_mode_outlined));
      await tester.pumpAndSettle();

      expect(settings.readerTheme, ReaderThemeMode.dark);
      expect(notifications, 1);
    });

    testWidgets('keep-screen-on and volume-key switches notify once each',
        (tester) async {
      final settings = ReaderSettings();
      var notifications = 0;

      await _pumpSheet(
        tester,
        settings: settings,
        onChanged: () => notifications++,
      );

      // Switch order: system brightness, keep screen on, volume keys.
      await tester.tap(find.byType(Switch).at(1));
      await tester.pumpAndSettle();
      expect(settings.keepScreenOn, isTrue);
      expect(notifications, 1);

      await tester.tap(find.byType(Switch).at(2));
      await tester.pumpAndSettle();
      expect(settings.volumeKeyTurns, isTrue);
      expect(notifications, 2);
    });

    testWidgets('turning system brightness off seeds the level then notifies',
        (tester) async {
      final settings = ReaderSettings(); // brightness: null
      var notifications = 0;

      await _pumpSheet(
        tester,
        settings: settings,
        onChanged: () => notifications++,
      );

      await tester.tap(find.byType(Switch).at(0));
      await tester.pumpAndSettle();

      // Seeded from the controller, and notified exactly once (not twice).
      expect(settings.brightness, 0.5);
      expect(notifications, 1);
    });

    testWidgets('turning system brightness back on notifies once',
        (tester) async {
      final settings = ReaderSettings()..brightness = 0.4;
      var notifications = 0;

      await _pumpSheet(
        tester,
        settings: settings,
        onChanged: () => notifications++,
      );

      await tester.tap(find.byType(Switch).at(0));
      await tester.pumpAndSettle();

      expect(settings.brightness, isNull);
      expect(notifications, 1);
    });
  });
}
