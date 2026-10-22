// Deleted/missing files move out of the library view; a snack reports the
// count with a View sheet listing them, and refresh re-checks for them.
import 'package:burrow/models/book.dart';
import 'package:burrow/screens/library_screen.dart';
import 'package:burrow/services/library_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  SharedPreferences.setMockInitialValues({});

  Book fakeBook(String id) => Book(
    id: id,
    title: 'Book $id',
    author: 'Author',
    path: '/tmp/$id.epub',
    format: BookFormat.epub,
    addedAt: 1,
    lastReadAt: 0,
    progress: 0,
  );

  Future<void> pumpLibrary(
    WidgetTester tester,
    LibraryService library, {
    ScanDeviceFn? scanDevice,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(412, 915);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: LibraryScreen(
          library: library,
          scanDevice:
              scanDevice ?? ({knownPaths = const {}}) async => const <String>[],
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('missing books are moved out of the library grid', (tester) async {
    final service = LibraryService()
      ..debugAddAll([fakeBook('a'), fakeBook('b')])
      ..debugMarkMissing('a');

    await pumpLibrary(tester, service);

    expect(find.text('Book a'), findsNothing);
    expect(find.text('Book b'), findsWidgets);
    // Hidden missing books count as filtered results.
    expect(find.text('1 found'), findsOneWidget);
  });

  testWidgets('snack reports one missing document with a View action', (
    tester,
  ) async {
    final service = LibraryService()
      ..debugAddAll([fakeBook('a')])
      ..debugMarkMissing('a');

    await pumpLibrary(tester, service);

    expect(find.text('1 document missing'), findsOneWidget);
    expect(find.text('View'), findsOneWidget);
  });

  testWidgets('snack pluralizes the missing count', (tester) async {
    final service = LibraryService()
      ..debugAddAll([fakeBook('a'), fakeBook('b')])
      ..debugMarkMissing('a')
      ..debugMarkMissing('b');

    await pumpLibrary(tester, service);

    expect(find.text('2 documents missing'), findsOneWidget);
  });

  testWidgets('View opens the missing sheet with the hidden books', (
    tester,
  ) async {
    final service = LibraryService()
      ..debugAddAll([fakeBook('a')])
      ..debugMarkMissing('a');

    await pumpLibrary(tester, service);

    await tester.tap(find.text('View'));
    await tester.pumpAndSettle();

    expect(find.text('Missing documents'), findsOneWidget);
    expect(find.text('Book a'), findsOneWidget);
  });

  testWidgets('refresh re-checks the disk and reports vanished files', (
    tester,
  ) async {
    // Book's file was never on disk; a refresh makes the app notice.
    final service = LibraryService()..debugAddAll([fakeBook('a')]);
    await pumpLibrary(
      tester,
      service,
      scanDevice: ({knownPaths = const {}}) async => const <String>[],
    );

    expect(find.text('1 document missing'), findsNothing);

    await tester.fling(find.byType(CustomScrollView), const Offset(0, 400), 600);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    expect(find.text('1 document missing'), findsOneWidget);
  });
}
