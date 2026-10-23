import 'package:burrow/models/reader_settings.dart';
import 'package:burrow/services/external_dictionary_service.dart';
import 'package:burrow/widgets/dictionary_picker_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(
  WidgetTester tester, {
  String? word,
  required List<ExternalDictionaryApp> apps,
  required void Function(String?) onSetDefault,
  required void Function(ExternalDictionaryApp, bool) onUse,
}) async {
  final theme = ReaderTheme.byMode(ReaderThemeMode.sepia);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => DictionaryPickerSheet.show(
              context,
              word: word,
              theme: theme,
              apps: apps,
              onSetDefault: onSetDefault,
              onUse: onUse,
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

Future<void> _tapRow(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

Future<void> _tapPin(WidgetTester tester, String rowLabel) async {
  final tile = find.ancestor(
    of: find.text(rowLabel),
    matching: find.byType(ListTile),
  );
  final pin = find.descendant(
    of: tile,
    matching: find.byTooltip('Always'),
  );
  await tester.tap(pin);
  await tester.pumpAndSettle();
}

void main() {
  const app = ExternalDictionaryApp(
    packageName: 'net.guten.cpp',
    label: 'Guten Dict',
  );

  testWidgets('lookup: app row uses once, without setting default', (
    tester,
  ) async {
    final setDefaults = <String?>[];
    final used = <(ExternalDictionaryApp, bool)>[];

    await _pump(
      tester,
      word: 'example',
      apps: [app],
      onSetDefault: setDefaults.add,
      onUse: (a, b) => used.add((a, b)),
    );

    expect(find.text('Define with Burrow'), findsOneWidget);
    expect(find.text('Guten Dict'), findsOneWidget);

    await _tapRow(tester, 'Guten Dict');

    expect(used, [equals((app, false))]);
    expect(setDefaults, isEmpty);
  });

  testWidgets('lookup: pin on app row sets default AND uses it', (
    tester,
  ) async {
    final setDefaults = <String?>[];
    final used = <(ExternalDictionaryApp, bool)>[];

    await _pump(
      tester,
      word: 'example',
      apps: [app],
      onSetDefault: setDefaults.add,
      onUse: (a, b) => used.add((a, b)),
    );

    await _tapPin(tester, 'Guten Dict');

    expect(setDefaults, ['net.guten.cpp']);
    expect(used, [equals((app, false))]);
  });

  testWidgets('lookup: Burrow row uses built-in, pin sets burrow default and uses it', (
    tester,
  ) async {
    final setDefaults = <String?>[];
    final used = <(ExternalDictionaryApp, bool)>[];

    await _pump(
      tester,
      word: 'example',
      apps: [
        const ExternalDictionaryApp(
          packageName: 'net.guten.cpp',
          label: 'Guten Dict',
        ),
      ],
      onSetDefault: setDefaults.add,
      onUse: (a, b) => used.add((a, b)),
    );

    await _tapRow(tester, 'Define with Burrow');
    expect(used, hasLength(1));
    expect(used.single.$2, isTrue, reason: 'Burrow use passes isBurrow=true');
    expect(used.single.$1.packageName, burrowDefaultDictionary);
    expect(setDefaults, isEmpty);

    // Reopen for the pin case.
    await _pump(
      tester,
      word: 'example',
      apps: [
        const ExternalDictionaryApp(
          packageName: 'net.guten.cpp',
          label: 'Guten Dict',
        ),
      ],
      onSetDefault: setDefaults.add,
      onUse: (a, b) => used.add((a, b)),
    );
    expect(used, hasLength(1));
    await _tapPin(tester, 'Define with Burrow');
    expect(used, hasLength(2), reason: 'pin in lookup mode also defines');
    expect(used.last.$2, isTrue);
    expect(setDefaults, [burrowDefaultDictionary]);
  });

  testWidgets('many apps overflow into a scrollable sheet, not clipped', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(412, 480);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final apps = [
      for (var i = 0; i < 6; i++)
        ExternalDictionaryApp(
          packageName: 'net.app$i',
          label: 'App $i',
        ),
    ];
    await _pump(
      tester,
      word: 'example',
      apps: apps,
      onSetDefault: (_, __) {},
      onUse: (_, ___) {},
    );

    expect(find.text('Define with Burrow'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // The last row exists below the fold but is reachable by scrolling.
    expect(find.text('App 5'), findsOneWidget);
    final scrollable = find.byType(Scrollable).last;
    await tester.scrollUntilVisible(
      find.text('App 5'),
      100,
      scrollable: scrollable,
    );
    await tester.pumpAndSettle();
    expect(find.text('App 5'), findsOneWidget);
  });

  testWidgets('management mode: ask row, taps set defaults, no pins', (
    tester,
  ) async {
    final setDefaults = <String?>[];
    final used = <(ExternalDictionaryApp, bool)>[];

    await _pump(
      tester,
      word: null,
      apps: [app],
      onSetDefault: setDefaults.add,
      onUse: (a, b) => used.add((a, b)),
    );

    expect(find.byTooltip('Always'), findsNothing);
    expect(find.text('Ask every time'), findsOneWidget);

    // Each action closes the sheet; reopen for each row under test.
    await _tapRow(tester, 'Ask every time');
    await tester.pumpAndSettle();
    expect(setDefaults, [isNull]);

    await _pump(
      tester,
      word: null,
      apps: [app],
      onSetDefault: setDefaults.add,
      onUse: (a, b) => used.add((a, b)),
    );
    await _tapRow(tester, 'Define with Burrow');
    await tester.pumpAndSettle();
    expect(setDefaults, [isNull, burrowDefaultDictionary]);

    await _pump(
      tester,
      word: null,
      apps: [app],
      onSetDefault: setDefaults.add,
      onUse: (a, b) => used.add((a, b)),
    );
    await _tapRow(tester, 'Guten Dict');
    await tester.pumpAndSettle();
    expect(setDefaults, [isNull, burrowDefaultDictionary, 'net.guten.cpp']);
    expect(used, isEmpty);
  });
}
