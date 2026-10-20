// Folder scan type in Settings must immediately prompt for a folder, remember
// the choice, and revert cleanly when the picker is cancelled.
import 'package:burrow/models/reader_settings.dart';
import 'package:burrow/screens/settings_screen.dart';
import 'package:burrow/services/library_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('choosing Single folder prompts the picker and saves it', (
    tester,
  ) async {
    final pickCalls = <String?>[];
    Future<String?> pickFolder() async {
      pickCalls.add('/storage/Downloads');
      return '/storage/Downloads';
    }

    final service = LibraryService()..settings.scanMode = ScanMode.device;
    await _pumpSettings(tester, library: service, pickFolder: pickFolder);

    await _selectScanMode(tester, 'Single folder');
    await tester.pumpAndSettle();

    expect(pickCalls, hasLength(1), reason: 'picker opens on selection');
    expect(service.settings.scanMode, ScanMode.folder);
    expect(service.settings.scanFolder, '/storage/Downloads');
    // Dropdown shows the new type; subtitle remembers the folder (basename).
    expect(find.text('Single folder'), findsOneWidget);
    expect(find.text('Scanning: Downloads'), findsOneWidget);
  });

  testWidgets('cancelling the folder picker keeps the previous scan type', (
    tester,
  ) async {
    Future<String?> pickFolder() async => null; // user backed out

    await _pumpSettings(tester, pickFolder: pickFolder);

    await _selectScanMode(tester, 'Single folder');
    await tester.pumpAndSettle();

    // Dropdown snaps back: its closed value is still 'Full device' and the
    // subtitle still describes the previous mode.
    expect(find.text('Full device'), findsOneWidget);
    expect(find.text('Walk the whole device for new books'), findsOneWidget);
  });

  testWidgets('mode is saved after picker confirmation (not before)', (
    tester,
  ) async {
    final service = LibraryService()..settings.scanMode = ScanMode.device;
    Future<String?> pickFolder() => Future.value('/storage/Downloads');
    await _pumpSettings(tester, library: service, pickFolder: pickFolder);

    await _selectScanMode(tester, 'Single folder');
    await tester.pumpAndSettle();

    expect(service.settings.scanMode, ScanMode.folder);
    expect(service.settings.scanFolder, '/storage/Downloads');
  });
}

Future<void> _pumpSettings(
  WidgetTester tester, {
  LibraryService? library,
  required Future<String?> Function() pickFolder,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(412, 915);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: SettingsScreen(library: library ?? LibraryService(), pickFolder: pickFolder),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _selectScanMode(WidgetTester tester, String label) async {
  await tester.tap(find.text('Full device'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}
