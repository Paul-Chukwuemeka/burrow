import 'package:burrow/models/reader_settings.dart';
import 'package:burrow/services/brightness_controller.dart';
import 'package:burrow/widgets/settings_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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

/// The nearest ancestor [Row] of the control labelled [label].
Finder _rowWithText(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(Row)).first;

/// A +/- stepper button inside the row labelled [label].
Finder _stepper(String label, IconData icon) => find.descendant(
      of: _rowWithText(label),
      matching: find.widgetWithIcon(IconButton, icon),
    );

/// The [Switch] inside the row labelled [label].
Finder _switchFor(String label) => find.descendant(
      of: _rowWithText(label),
      matching: find.byType(Switch),
    );

/// Scroll [finder] into view, tap it, and settle.
Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// Drag the slider across many divisions without lifting the finger.
Future<TestGesture> _startDrag(
  WidgetTester tester,
  Finder slider, {
  double dx = 30,
  int steps = 20,
}) async {
  await tester.ensureVisible(slider);
  await tester.pumpAndSettle();
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

  group('SettingsSheet steppers', () {
    testWidgets('font-size stepper steps and notifies once per tap',
        (tester) async {
      final settings = ReaderSettings(fontSize: 13);
      var notifications = 0;

      await _pumpSheet(
        tester,
        settings: settings,
        onChanged: () => notifications++,
      );

      await _tap(tester, _stepper('Font size', Icons.add_circle_outline));
      expect(settings.fontSize, 14);
      expect(notifications, 1);

      await _tap(tester, _stepper('Font size', Icons.add_circle_outline));
      expect(settings.fontSize, 15);
      expect(notifications, 2);

      await _tap(tester, _stepper('Font size', Icons.remove_circle_outline));
      expect(settings.fontSize, 14);
      expect(notifications, 3);
    });

    testWidgets('line-height stepper steps by 0.1 and notifies once per tap',
        (tester) async {
      final settings = ReaderSettings(lineHeight: 1.2);
      var notifications = 0;

      await _pumpSheet(
        tester,
        settings: settings,
        onChanged: () => notifications++,
      );

      await _tap(tester, _stepper('Line height', Icons.add_circle_outline));
      expect(settings.lineHeight, closeTo(1.3, 1e-9));
      expect(notifications, 1);

      await _tap(tester, _stepper('Line height', Icons.remove_circle_outline));
      expect(settings.lineHeight, closeTo(1.2, 1e-9));
      expect(notifications, 2);
    });

    testWidgets('margin stepper steps by 2 and notifies once per tap',
        (tester) async {
      final settings = ReaderSettings(horizontalMargin: 20);
      var notifications = 0;

      await _pumpSheet(
        tester,
        settings: settings,
        onChanged: () => notifications++,
      );

      await _tap(tester, _stepper('Margin', Icons.add_circle_outline));
      expect(settings.horizontalMargin, 22);
      expect(notifications, 1);

      await _tap(tester, _stepper('Margin', Icons.remove_circle_outline));
      expect(settings.horizontalMargin, 20);
      expect(notifications, 2);
    });

    testWidgets('brightness slider notifies once on release', (tester) async {
      final settings = ReaderSettings(fontSize: 18)
        ..brightness = kMinBrightness;
      var notifications = 0;

      await _pumpSheet(
        tester,
        settings: settings,
        onChanged: () => notifications++,
      );

      final gesture = await _startDrag(tester, find.byType(Slider));
      expect(notifications, 0);
      expect(settings.brightness, greaterThan(kMinBrightness));

      await gesture.up();
      await tester.pumpAndSettle();
      expect(notifications, 1);
    });

    testWidgets('brightness debounce commits if the finger never lifts',
        (tester) async {
      final settings = ReaderSettings()..brightness = kMinBrightness;
      var notifications = 0;

      await _pumpSheet(
        tester,
        settings: settings,
        onChanged: () => notifications++,
      );

      final gesture = await _startDrag(tester, find.byType(Slider));
      expect(notifications, 0);

      // Finger still down, but the value has settled: the net fires.
      await tester.pump(
          SettingsSheet.commitDebounce + const Duration(milliseconds: 50));
      expect(notifications, 1);

      // Releasing still commits the final value exactly once more.
      await gesture.up();
      await tester.pumpAndSettle();
      expect(notifications, 2);
    });

    testWidgets('dismissing after a drag leaves no pending timer',
        (tester) async {
      final settings = ReaderSettings()..brightness = kMinBrightness;
      var notifications = 0;

      await _pumpSheet(
        tester,
        settings: settings,
        onChanged: () => notifications++,
      );

      final gesture = await _startDrag(tester, find.byType(Slider));
      await gesture.up();
      await tester.pumpAndSettle();

      // Close the sheet; State.dispose must cancel any debounce.
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

      await _tap(tester, _switchFor('Keep screen on'));
      expect(settings.keepScreenOn, isTrue);
      expect(notifications, 1);

      await _tap(tester, _switchFor('Volume keys turn pages'));
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

      await _tap(tester, _switchFor('System brightness'));

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

      await _tap(tester, _switchFor('System brightness'));

      expect(settings.brightness, isNull);
      expect(notifications, 1);
    });
  });
}
