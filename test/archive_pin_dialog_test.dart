import 'package:burrow/services/archive_pin_service.dart';
import 'package:burrow/widgets/archive_pin_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('first use asks to create and confirm a PIN', (tester) async {
    bool? result;
    await tester.pumpWidget(
      _Harness(
        onOpen: (context) async =>
            result = await ensureHiddenArchiveUnlocked(context),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Create hidden archive PIN'), findsOneWidget);

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '1234');
    await tester.enterText(fields.at(1), '1234');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(result, isTrue);
    expect(await ArchivePinService.hasPin(), isTrue);
    expect(await ArchivePinService.verifyPin('1234'), isTrue);
  });

  testWidgets('setup rejects mismatched confirmation', (tester) async {
    bool? result;
    await tester.pumpWidget(
      _Harness(
        onOpen: (context) async =>
            result = await ensureHiddenArchiveUnlocked(context),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '1234');
    await tester.enterText(fields.at(1), '0000');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(find.text('PINs do not match'), findsOneWidget);
    expect(result, isNull);
    expect(await ArchivePinService.hasPin(), isFalse);
  });

  testWidgets('existing PIN must be entered correctly', (tester) async {
    await ArchivePinService.setPin('1234');
    bool? result;
    await tester.pumpWidget(
      _Harness(
        onOpen: (context) async =>
            result = await ensureHiddenArchiveUnlocked(context),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Enter your 4-digit PIN'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '9999');
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();

    expect(find.text('Incorrect PIN'), findsOneWidget);
    expect(result, isNull);

    await tester.enterText(find.byType(TextField), '1234');
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();

    expect(result, isTrue);
  });
}

class _Harness extends StatelessWidget {
  const _Harness({required this.onOpen});

  final Future<void> Function(BuildContext) onOpen;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => onOpen(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
  }
}
