// Regression: tapping the sort chip on the library header only updated widget
// state and never wrote the choice to SharedPreferences, so the sort reset to
// "Recent" after an app restart. The layout chip (Grid/List) right next to it
// did persist; sort must behave the same via saveFilters().
import 'package:burrow/models/book.dart';
import 'package:burrow/screens/library_screen.dart';
import 'package:burrow/services/library_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Book _fakeBook(String id) => Book(
      id: id,
      title: 'Book $id',
      author: 'Author $id',
      path: '/tmp/sort-persist-$id.epub',
      format: BookFormat.epub,
      addedAt: 1,
    );

Future<void> _pumpLibrary(WidgetTester t, LibraryService lib) async {
  t.view.devicePixelRatio = 1.0;
  t.view.physicalSize = const Size(412, 915);
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(home: LibraryScreen(library: lib)));
  await t.pump();
  await t.pump(const Duration(seconds: 1)); // Let entrance animations finish.
  await t.pump(); // Let _loadFilters() complete and settle.
  expect(t.takeException(), isNull);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('sort chip choice persists to prefs and survives a restart', (
    t,
  ) async {
    final lib = LibraryService()
      ..debugAddAll([_fakeBook('a'), _fakeBook('b'), _fakeBook('c')]);
    addTearDown(lib.dispose);
    await _pumpLibrary(t, lib);

    // Default sort is Recent.
    expect(find.text('Recent'), findsOneWidget);

    // Cycle the sort chip: Recent → Added.
    await t.tap(find.text('Recent'));
    await t.pump();
    expect(find.text('Added'), findsOneWidget);

    // The chip must write the sort through to prefs immediately.
    final filters = await lib.loadFilters();
    expect(filters?['sort'], 'added');

    // Simulate an app restart: a fresh LibraryScreen must restore the sort.
    await _pumpLibrary(t, lib);
    expect(find.text('Added'), findsOneWidget);
    expect(find.text('Recent'), findsNothing);
  });
}
