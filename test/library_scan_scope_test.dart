// Folder scan type scopes the library: only books inside the remembered
// folder are shown, and scans/refreshes use that folder without re-picking.
import 'package:burrow/models/book.dart';
import 'package:burrow/models/reader_settings.dart';
import 'package:burrow/screens/library_screen.dart';
import 'package:burrow/services/library_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  SharedPreferences.setMockInitialValues({});
  Book bookIn(String path, String title) => Book(
    id: path,
    title: title,
    author: 'Author',
    path: path,
    format: BookFormat.epub,
    addedAt: 1,
    lastReadAt: 0,
    progress: 0,
  );

  Future<void> pumpLibrary(
    WidgetTester tester,
    LibraryService library, {
    List<String?>? pickCalls,
    Future<List<String>> Function(String folder, {Set<String> knownPaths})?
    onScanFolder,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(412, 915);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: LibraryScreen(
          library: library,
          pickScanFolder: () async {
            pickCalls?.add('/storage/books');
            return '/storage/books';
          },
          scanFolder:
              onScanFolder ??
              (folder, {knownPaths = const {}}) async => const <String>[],
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  LibraryService scopedService() {
    final service = LibraryService()
      ..debugAddAll([
        bookIn('/storage/books/alpha.epub', 'Alpha'),
        bookIn('/storage/elsewhere/zeta.epub', 'Zeta'),
      ]);
    service.settings.scanMode = ScanMode.folder;
    service.settings.scanFolder = '/storage/books';
    return service;
  }

  testWidgets('folder mode hides books outside the scoped folder', (tester) async {
    await pumpLibrary(tester, scopedService());

    expect(find.text('Alpha'), findsWidgets);
    expect(find.text('Zeta'), findsNothing);
  });

  testWidgets('header shows the scoped folder name', (tester) async {
    await pumpLibrary(tester, scopedService());

    expect(find.text('books only'), findsWidgets);
  });

  testWidgets('device mode shows every book again', (tester) async {
    final service = scopedService()..settings.scanMode = ScanMode.device;
    await pumpLibrary(tester, service);

    expect(find.text('Alpha'), findsWidgets);
    expect(find.text('Zeta'), findsWidgets);
  });

  testWidgets('refresh in folder mode scans the remembered folder without re-picking', (
    tester,
  ) async {
    final pickCalls = <String?>[];
    final scanned = <String>[];
    final service = scopedService();
    await pumpLibrary(
      tester,
      service,
      pickCalls: pickCalls,
      onScanFolder: (folder, {knownPaths = const {}}) async {
        scanned.add(folder);
        return const [];
      },
    );

    // Pull-to-refresh: overscroll from the top triggers the refresh.
    await tester.fling(find.byType(CustomScrollView).first, const Offset(0, 500), 600);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    // Completion banner appears once the refresh (stub scan) resolves...
    await tester.pump();

    expect(pickCalls, isEmpty, reason: 'no picker for a remembered folder');
    expect(scanned, ['/storage/books'],
        reason: 'refresh scans the remembered folder');
    expect(find.text('No new books found'), findsWidgets,
        reason: 'refresh completed with a scan banner');
    // ...and the banner auto-clears.
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('No new books found'), findsNothing);
  });

  testWidgets('scan action in folder mode uses the remembered folder without re-picking', (
    tester,
  ) async {
    final pickCalls = <String?>[];
    final scanned = <String>[];
    final service = scopedService();
    await pumpLibrary(
      tester,
      service,
      pickCalls: pickCalls,
      onScanFolder: (folder, {knownPaths = const {}}) async {
        scanned.add(folder);
        return const [];
      },
    );

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Scan folder…'));
    await tester.pumpAndSettle();
    // Completion banner appears immediately after the scan returns...
    await tester.pump();
    expect(pickCalls, isEmpty, reason: 'no picker for a remembered folder');
    expect(scanned, ['/storage/books'],
        reason: 'scan action targets the remembered folder');
    expect(find.text('No new books found'), findsWidgets,
        reason: 'scan completed with a banner');
    // ...and auto-clears.
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('No new books found'), findsNothing);
  });
}
