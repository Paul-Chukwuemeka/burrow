import 'package:burrow/models/reader_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ReaderSettings', () {
    test('default brightness is null (follow system)', () {
      final s = ReaderSettings();
      expect(s.brightness, isNull);
    });

    test('toJson/fromJson round-trip with null brightness', () {
      final s = ReaderSettings()..brightness = null;
      final j = s.toJson();
      final r = ReaderSettings.fromJson(j);
      expect(r.brightness, isNull);
    });

    test('toJson/fromJson round-trip with explicit brightness', () {
      final s = ReaderSettings()..brightness = 0.75;
      final j = s.toJson();
      final r = ReaderSettings.fromJson(j);
      expect(r.brightness, 0.75);
    });

    test('fromJson clamps brightness to [kMinBrightness, 1.0]', () {
      expect(ReaderSettings.fromJson({'brightness': 2.0}).brightness, 1.0);
      expect(
        ReaderSettings.fromJson({'brightness': 0.0}).brightness,
        kMinBrightness,
      );
      expect(
        ReaderSettings.fromJson({'brightness': -0.5}).brightness,
        kMinBrightness,
      );
    });

    test('fromJson clamps fontSize to the slider range', () {
      expect(ReaderSettings.fromJson({'fontSize': 4}).fontSize, 13);
      expect(ReaderSettings.fromJson({'fontSize': 99}).fontSize, 30);
      expect(ReaderSettings.fromJson({'fontSize': 21.5}).fontSize, 21.5);
    });

    test('fromJson clamps lineHeight to the slider range', () {
      expect(ReaderSettings.fromJson({'lineHeight': 0.5}).lineHeight, 1.2);
      expect(ReaderSettings.fromJson({'lineHeight': 5}).lineHeight, 2.2);
      expect(ReaderSettings.fromJson({'lineHeight': 1.75}).lineHeight, 1.75);
    });

    test('fromJson rejects non-finite layout values', () {
      final nan = ReaderSettings.fromJson({
        'fontSize': double.nan,
        'lineHeight': double.infinity,
      });
      expect(nan.fontSize, 18);
      expect(nan.lineHeight, 1.6);
    });

    test('fromJson falls back to sepia on unknown theme name', () {
      final r = ReaderSettings.fromJson({'readerTheme': 'electric-boogaloo'});
      expect(r.readerTheme, ReaderThemeMode.sepia);
    });

    test('oled theme round-trips and renders pure black', () {
      final s = ReaderSettings(readerTheme: ReaderThemeMode.oled);
      final r = ReaderSettings.fromJson(s.toJson());
      expect(r.readerTheme, ReaderThemeMode.oled);
      expect(
        ReaderTheme.byMode(ReaderThemeMode.oled).background,
        const Color(0xFF000000),
      );
      expect(
        ReaderTheme.byMode(ReaderThemeMode.oled).brightness,
        Brightness.dark,
      );
    });

    test('fromJson restores a saved oled theme name', () {
      final r = ReaderSettings.fromJson({'readerTheme': 'oled'});
      expect(r.readerTheme, ReaderThemeMode.oled);
    });

    test('migrates legacy dimmer: 1.0 becomes null', () {
      final r = ReaderSettings.fromJson({'dimmer': 1.0});
      expect(r.brightness, isNull);
    });

    test('migrates legacy dimmer: 0.7 stays 0.7', () {
      final r = ReaderSettings.fromJson({'dimmer': 0.7});
      expect(r.brightness, 0.7);
    });

    test('migrates legacy dimmer: 0.3 stays 0.3', () {
      final r = ReaderSettings.fromJson({'dimmer': 0.3});
      expect(r.brightness, 0.3);
    });

    test('migrates legacy dimmer: absent key yields null', () {
      final r = ReaderSettings.fromJson({});
      expect(r.brightness, isNull);
    });

    test('migrates legacy dimmer: clamps > 1.0 down', () {
      final r = ReaderSettings.fromJson({'dimmer': 1.5});
      expect(r.brightness, isNull);
    });

    test('toJson does not write legacy dimmer key', () {
      final j = ReaderSettings().toJson();
      expect(j.containsKey('dimmer'), isFalse);
      expect(j.containsKey('brightness'), isTrue);
    });

    test('scanMode defaults to device and round-trips', () {
      expect(ReaderSettings().scanMode, ScanMode.device);
      final s = ReaderSettings()..scanMode = ScanMode.quick;
      final r = ReaderSettings.fromJson(s.toJson());
      expect(r.scanMode, ScanMode.quick);
    });

    test('scanMode falls back to device on unknown name', () {
      expect(
        ReaderSettings.fromJson({'scanMode': 'telepathy'}).scanMode,
        ScanMode.device,
      );
      expect(ReaderSettings.fromJson({}).scanMode, ScanMode.device);
    });

    test('scanFolder defaults to empty and round-trips', () {
      expect(ReaderSettings().scanFolder, '');
      final s = ReaderSettings()..scanFolder = '/storage/books';
      final r = ReaderSettings.fromJson(s.toJson());
      expect(r.scanFolder, '/storage/books');
    });

    test('autoResumeOnRelaunch defaults to false and round-trips', () {
      expect(ReaderSettings().autoResumeOnRelaunch, isFalse);
      final s = ReaderSettings()..autoResumeOnRelaunch = true;
      final r = ReaderSettings.fromJson(s.toJson());
      expect(r.autoResumeOnRelaunch, isTrue);
    });

    test('autoResumeOnRelaunch falls back to false on absent key', () {
      expect(ReaderSettings.fromJson({}).autoResumeOnRelaunch, isFalse);
    });

    test('readerOpenAtLastExit defaults to false and round-trips', () {
      expect(ReaderSettings().readerOpenAtLastExit, isFalse);
      final s = ReaderSettings()..readerOpenAtLastExit = true;
      final r = ReaderSettings.fromJson(s.toJson());
      expect(r.readerOpenAtLastExit, isTrue);
    });

    test('readerOpenAtLastExit falls back to false on absent key', () {
      expect(ReaderSettings.fromJson({}).readerOpenAtLastExit, isFalse);
    });
  });

  group('ReaderTheme selection contrast', () {
    double contrast(Color a, Color b) {
      final la = a.computeLuminance();
      final lb = b.computeLuminance();
      final hi = la > lb ? la : lb;
      final lo = la > lb ? lb : la;
      return (hi + 0.05) / (lo + 0.05);
    }

    for (final mode in ReaderThemeMode.values) {
      test('${mode.name} selection reads clearly without hurting text', () {
        final theme = ReaderTheme.byMode(mode);
        expect(
          contrast(theme.selection, theme.background),
          greaterThanOrEqualTo(2.0),
        );
        expect(
          contrast(theme.text, theme.selection),
          greaterThanOrEqualTo(5.0),
        );
      });
    }
  });

  test('defaultDictionary round-trips through JSON', () {
    final ask = ReaderSettings();
    expect(ask.defaultDictionary, isNull);
    final burrow = ReaderSettings(defaultDictionary: burrowDefaultDictionary);
    final app = ReaderSettings(defaultDictionary: 'net.guten.cpp');

    final askJson = ReaderSettings.fromJson(
      Map<String, dynamic>.from(ask.toJson()),
    );
    final burrowJson = ReaderSettings.fromJson(
      Map<String, dynamic>.of(burrow.toJson()),
    );
    final appJson = ReaderSettings.fromJson(
      Map<String, dynamic>.of(app.toJson()),
    );

    expect(askJson.defaultDictionary, isNull);
    expect(burrowJson.defaultDictionary, 'burrow');
    expect(appJson.defaultDictionary, 'net.guten.cpp');
  });

  test('default highlight colour is amber', () {
    expect(ReaderSettings().highlightColorIndex, 0);
  });

  test('highlight colour round-trips through JSON', () {
    final s = ReaderSettings()..highlightColorIndex = 3;
    final r = ReaderSettings.fromJson(Map<String, dynamic>.of(s.toJson()));
    expect(r.highlightColorIndex, 3);
  });

  test('highlight colour is clamped to the palette', () {
    expect(
      ReaderSettings.fromJson({'highlightColorIndex': 99}).highlightColorIndex,
      4,
    );
    expect(
      ReaderSettings.fromJson({'highlightColorIndex': -4}).highlightColorIndex,
      0,
    );
  });
}
