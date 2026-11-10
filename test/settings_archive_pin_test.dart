import 'package:burrow/screens/settings_screen.dart';
import 'package:burrow/services/library_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('settings opens the hidden archive PIN setup', (tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final service = LibraryService();
    await tester.pumpWidget(
      MaterialApp(home: SettingsScreen(library: service)),
    );
    await tester.pumpAndSettle();

    final tile = find.text('Hidden archive PIN');
    for (var i = 0; i < 12 && tester.widgetList(tile).isEmpty; i++) {
      await tester.drag(find.byType(ListView).first, const Offset(0, -250));
      await tester.pumpAndSettle();
    }
    expect(tile, findsOneWidget);
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    await tester.tap(tile);
    await tester.pumpAndSettle();

    expect(find.text('Set a new hidden archive PIN'), findsOneWidget);
  });
}
