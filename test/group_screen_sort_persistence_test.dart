// Regression: the grouping screens (author/series/genre/smartGroup) cycled
// their sort via setState only — the choice never reached SharedPreferences
// and reset after an app restart. Each screen now writes through to
// LibraryService.saveGroupSort under its own scope and restores on mount.
import 'package:burrow/models/book.dart';
import 'package:burrow/screens/author_screen.dart';
import 'package:burrow/screens/genre_screen.dart';
import 'package:burrow/screens/series_screen.dart';
import 'package:burrow/screens/smart_group_screen.dart';
import 'package:burrow/services/library_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Book _fakeBook(
  String id, {
  String author = 'Best Author',
  String? genre,
  String? seriesName,
}) => Book(
      id: id,
      title: 'Book $id',
      author: author,
      path: '/tmp/group-sort-$id.epub',
      format: BookFormat.epub,
      addedAt: 1,
      genre: genre,
      seriesName: seriesName,
    );

Future<void> _pumpScreen(WidgetTester t, Widget screen) async {
  t.view.devicePixelRatio = 1.0;
  t.view.physicalSize = const Size(412, 915);
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(home: screen));
  await t.pump();
  await t.pump(const Duration(seconds: 1)); // Let entrance animations finish.
  await t.pump(); // Let async sort-restore loads settle.
  expect(t.takeException(), isNull);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('author screen sort persists and survives restart', (t) async {
    final lib = LibraryService()
      ..debugAddAll([_fakeBook('a'), _fakeBook('b')]);
    addTearDown(lib.dispose);

    // Default is A–Z; cycle it → Recent.
    await _pumpScreen(t, AuthorScreen(author: 'Best Author', library: lib));
    expect(find.text('A–Z'), findsOneWidget);
    await t.tap(find.text('A–Z'));
    await t.pump();
    expect(find.text('Recent'), findsOneWidget);

    expect((await lib.loadGroupSorts())['author'], 'recent');

    // Restart: fresh screen restores the sort.
    await _pumpScreen(t, AuthorScreen(author: 'Best Author', library: lib));
    expect(find.text('Recent'), findsOneWidget);
    expect(find.text('A–Z'), findsNothing);
  });

  testWidgets('series screen sort persists and survives restart', (t) async {
    final lib = LibraryService()
      ..debugAddAll([
        _fakeBook('a', seriesName: 'The Long Saga', genre: null),
      ]);
    addTearDown(lib.dispose);

    // Default is Order; cycle it → A–Z.
    await _pumpScreen(t, SeriesScreen(series: 'The Long Saga', library: lib));
    expect(find.text('Order'), findsOneWidget);
    await t.tap(find.text('Order'));
    await t.pump();
    expect(find.text('A–Z'), findsOneWidget);

    expect((await lib.loadGroupSorts())['series'], 'title');

    await _pumpScreen(t, SeriesScreen(series: 'The Long Saga', library: lib));
    expect(find.text('A–Z'), findsOneWidget);
    expect(find.text('Order'), findsNothing);
  });

  testWidgets('genre screen sort persists and survives restart', (t) async {
    final lib = LibraryService()
      ..debugAddAll([_fakeBook('a', genre: 'Fantasy'), _fakeBook('b')]);
    addTearDown(lib.dispose);

    await _pumpScreen(t, GenreScreen(genre: 'Fantasy', library: lib));
    expect(find.text('A–Z'), findsOneWidget);
    await t.tap(find.text('A–Z'));
    await t.pump();
    expect(find.text('Recent'), findsOneWidget);

    expect((await lib.loadGroupSorts())['genre'], 'recent');

    await _pumpScreen(t, GenreScreen(genre: 'Fantasy', library: lib));
    expect(find.text('Recent'), findsOneWidget);
    expect(find.text('A–Z'), findsNothing);
  });

  testWidgets('smart group screen sort persists and survives restart', (
    t,
  ) async {
    final lib = LibraryService()
      ..debugAddAll([_fakeBook('a'), _fakeBook('b')]);
    addTearDown(lib.dispose);

    await _pumpScreen(
      t,
      SmartGroupScreen(title: 'Fresh Finds', books: lib.books, library: lib),
    );
    expect(find.text('A–Z'), findsOneWidget);
    await t.tap(find.text('A–Z'));
    await t.pump();
    expect(find.text('Recent'), findsOneWidget);

    expect((await lib.loadGroupSorts())['smartGroup'], 'recent');

    await _pumpScreen(
      t,
      SmartGroupScreen(title: 'Fresh Finds', books: lib.books, library: lib),
    );
    expect(find.text('Recent'), findsOneWidget);
    expect(find.text('A–Z'), findsNothing);
  });
}
