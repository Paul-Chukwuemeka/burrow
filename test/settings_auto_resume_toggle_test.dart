// The Settings "Resume last book on launch" toggle drives auto-resume on
// relaunch: with it on, a cold start opens the most recent unfinished book
// (see test/launch_resume_test.dart); off keeps the library as the landing
// screen.
import 'package:burrow/screens/settings_screen.dart';
import 'package:burrow/services/library_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Finder _switchFor(String label) {
  final tile = find
      .ancestor(of: find.text(label), matching: find.byType(ListTile))
      .first;
  return find.descendant(of: tile, matching: find.byType(Switch));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('toggle flips autoResumeOnRelaunch on and off', (tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final service = LibraryService();
    await tester.pumpWidget(
      MaterialApp(home: SettingsScreen(library: service)),
    );
    await tester.pumpAndSettle();

    expect(service.settings.autoResumeOnRelaunch, isFalse);

    await tester.tap(_switchFor('Resume last book on launch'));
    await tester.pump();
    expect(service.settings.autoResumeOnRelaunch, isTrue);

    await tester.tap(_switchFor('Resume last book on launch'));
    await tester.pump();
    expect(service.settings.autoResumeOnRelaunch, isFalse);
  });
}
