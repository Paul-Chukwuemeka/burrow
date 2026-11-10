import 'package:burrow/services/archive_pin_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('no PIN is configured initially', () async {
    expect(await ArchivePinService.hasPin(), isFalse);
    expect(await ArchivePinService.verifyPin('1234'), isFalse);
  });

  test('setPin stores a verifiable four-digit PIN', () async {
    await ArchivePinService.setPin('1234');

    expect(await ArchivePinService.hasPin(), isTrue);
    expect(await ArchivePinService.verifyPin('1234'), isTrue);
    expect(await ArchivePinService.verifyPin('4321'), isFalse);
    expect(await ArchivePinService.verifyPin('12345'), isFalse);
  });

  test('setPin replaces an existing PIN', () async {
    await ArchivePinService.setPin('1234');
    await ArchivePinService.setPin('5678');

    expect(await ArchivePinService.verifyPin('1234'), isFalse);
    expect(await ArchivePinService.verifyPin('5678'), isTrue);
  });

  test('setPin rejects anything that is not exactly four digits', () async {
    for (final invalid in ['', '123', '12345', '12a4', ' 123', '123 ']) {
      expect(
        () => ArchivePinService.setPin(invalid),
        throwsArgumentError,
        reason: 'accepted "$invalid"',
      );
    }
  });

  test('the stored value is not the raw PIN', () async {
    await ArchivePinService.setPin('1234');
    final prefs = await SharedPreferences.getInstance();

    final stored = prefs.getString(ArchivePinService.pinPreferenceKey);
    expect(stored, isNotNull);
    expect(stored, isNot(contains('1234')));
  });

  test('clearPin removes the configured PIN', () async {
    await ArchivePinService.setPin('1234');

    await ArchivePinService.clearPin();

    expect(await ArchivePinService.hasPin(), isFalse);
    expect(await ArchivePinService.verifyPin('1234'), isFalse);
  });
}
