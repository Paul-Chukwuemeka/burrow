import 'package:burrow/db/database.dart';
import 'package:burrow/main.dart';
import 'package:burrow/models/book.dart';
import 'package:burrow/models/reader_settings.dart';
import 'package:burrow/screens/library_screen.dart';
import 'package:burrow/screens/onboarding_screen.dart';
import 'package:burrow/services/onboarding_flow_controller.dart';
import 'package:burrow/services/library_service.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _pumpOnboarding(
  WidgetTester tester,
  LibraryService library, {
  PermissionFn? permission,
  Future<String?> Function()? pickFolder,
  ScanFn? scanDevice,
  ScanFn? scanFolder,
  PickFilesFn? pickFile,
  void Function(BuildContext context)? onDone,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: OnboardingScreen(
        library: library,
        onDone: onDone ?? (_) {},
        requestPermission: permission ?? () async => true,
        pickFolder: pickFolder,
        scanDevice: scanDevice ?? () async => <String>[],
        scanFolder: scanFolder ?? () async => <String>[],
        pickFile: pickFile ?? () async => <String>[],
      ),
    ),
  );
  await tester.pumpAndSettle();
}

LibraryService _library() => LibraryService()..debugAddAll(const []);

/// Library whose [importFile] never touches the disk/isolates, so scans in
/// widget tests complete under the fake-async test zone.
class _StubLibrary extends LibraryService {
  @override
  Future<Book?> importFile(String path) async => Book(
    id: 'stub-${path.hashCode}',
    title: 'Stub',
    author: 'Author',
    path: path,
    format: BookFormat.epub,
    addedAt: 0,
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('OnboardingScreen', () {
    testWidgets('welcome page shows wordmark and primary CTA', (tester) async {
      await _pumpOnboarding(tester, _library());

      expect(find.text('Tuck in'), findsOneWidget);
      expect(find.text('a cozy den for all your books.'), findsOneWidget);
      // Skip and no back arrow on the first page.
      expect(find.text('Skip'), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back_rounded), findsNothing);
    });

    testWidgets('Tuck in advances to the permission page', (tester) async {
      await _pumpOnboarding(tester, _library());

      await tester.tap(find.text('Tuck in'));
      await tester.pumpAndSettle();

      expect(find.text('let burrow find your books'), findsOneWidget);
      expect(find.text('Find my books'), findsOneWidget);
    });

    testWidgets('Skip on welcome lands on the import empty state', (
      tester,
    ) async {
      await _pumpOnboarding(tester, _library());

      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();

      expect(find.text('your den is waiting'), findsOneWidget);
      expect(find.text('Add your first book'), findsOneWidget);
    });

    testWidgets('theme and typeface selections seed reader settings', (
      tester,
    ) async {
      final library = _library();
      await _pumpOnboarding(tester, library);

      await tester.tap(find.text('Tuck in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Find my books'));
      await tester.pumpAndSettle();
      // Theme preferences page.
      expect(find.text('make it yours'), findsOneWidget);

      // App theme cards are on the preferences page.
      await tester.ensureVisible(find.text('OLED'));
      await tester.tap(find.text('OLED'));
      await tester.pumpAndSettle();
      expect(library.settings.appThemeMode, AppThemeMode.oled);
    });

    testWidgets(
      'granted permission defers the device scan to the import page',
      (tester) async {
        var scanned = false;
        final library = _library();
        await _pumpOnboarding(
          tester,
          library,
          scanDevice: () async {
            scanned = true;
            return <String>[];
          },
        );

        await tester.tap(find.text('Tuck in'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Find my books'));
        await tester.pumpAndSettle();
        // Theme preferences page — scan not yet run.
        expect(find.text('make it yours'), findsOneWidget);
        expect(scanned, isFalse);

        await tester.tap(find.text('Next'));
        await tester.pumpAndSettle();
        expect(scanned, isTrue);
        expect(find.text('no new books found'), findsOneWidget);
      },
    );

    testWidgets('full happy path runs the scan and reaches the ready screen', (
      tester,
    ) async {
      var done = false;
      final library = _StubLibrary();
      await _pumpOnboarding(
        tester,
        library,
        scanDevice: () async => ['/books/a.epub'],
        onDone: (_) => done = true,
      );

      await tester.tap(find.text('Tuck in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Find my books'));
      await tester.pumpAndSettle();
      // Theme preferences page.
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      // Import page — scan runs and completes.

      expect(find.text('found 1 books'), findsOneWidget);
      await tester.tap(find.text('Open your burrow'));
      await tester.pumpAndSettle();
      expect(done, isTrue);
    });

    testWidgets('denied permission keeps the import screen in empty state', (
      tester,
    ) async {
      final library = _library();
      await _pumpOnboarding(tester, library, permission: () async => false);

      await tester.tap(find.text('Tuck in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Find my books'));
      await tester.pumpAndSettle();
      // Theme preferences page.
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();

      expect(find.text('your den is waiting'), findsOneWidget);
      expect(find.text('Add your first book'), findsOneWidget);
    });

    testWidgets('back arrow returns to the previous page', (tester) async {
      await _pumpOnboarding(tester, _library());

      await tester.tap(find.text('Tuck in'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back_rounded));
      await tester.pumpAndSettle();

      expect(find.text('a cozy den for all your books.'), findsOneWidget);
    });

    testWidgets('choosing a folder scans immediately and skips preferences', (
      tester,
    ) async {
      final library = _StubLibrary();
      await _pumpOnboarding(
        tester,
        library,
        pickFolder: () async => '/storage/books',
        scanFolder: () async => ['/folder/b.epub'],
      );

      await tester.tap(find.text('Tuck in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose a folder instead'));
      await tester.pumpAndSettle();

      expect(find.text('found 1 books'), findsOneWidget);
      // Onboarding's choice carries into the library settings.
      expect(library.settings.scanMode, ScanMode.folder);
      expect(library.settings.scanFolder, '/storage/books');
    });
  });

  group('First-launch gate', () {
    testWidgets('BurrowApp shows onboarding when the flow is not complete', (
      tester,
    ) async {
      final library = _library();
      await tester.pumpWidget(BurrowApp(library: library));
      await tester.pumpAndSettle();

      expect(find.byType(OnboardingScreen), findsOneWidget);
      expect(find.byType(LibraryScreen).evaluate(), isEmpty);
    });

    testWidgets('BurrowApp shows the library once onboarding is complete', (
      tester,
    ) async {
      final library = _library()..onboardingComplete = true;
      await tester.pumpWidget(BurrowApp(library: library));
      await tester.pumpAndSettle();

      expect(find.byType(OnboardingScreen), findsNothing);
      expect(find.byType(LibraryScreen), findsOneWidget);
    });

    test('markOnboardingComplete persists the flag across reloads', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final library = LibraryService()..debugAttachDatabase(db);
      await library.load();
      expect(library.onboardingComplete, isFalse);

      await library.markOnboardingComplete();

      final reloaded = LibraryService()..debugAttachDatabase(db);
      await reloaded.load();
      expect(reloaded.onboardingComplete, isTrue);
    });
  });

  group('OnboardingFlowController scan choices', () {
    test('choosing folder scan remembers the folder and scan type', () async {
      final library = LibraryService();
      final flow = OnboardingFlowController(
        library: library,
        pickFolder: () async => '/storage/books',
        scanFolder: () async => const <String>[],
      );

      await flow.startFolderScan();

      expect(library.settings.scanMode, ScanMode.folder);
      expect(library.settings.scanFolder, '/storage/books');
    });

    test('cancelling the folder picker keeps the default scan type', () async {
      final library = LibraryService();
      final flow = OnboardingFlowController(
        library: library,
        pickFolder: () async => null,
        scanFolder: () async => const <String>[],
      );

      await flow.startFolderScan();

      expect(library.settings.scanMode, ScanMode.device);
      expect(library.settings.scanFolder, isEmpty);
    });
  });
}
