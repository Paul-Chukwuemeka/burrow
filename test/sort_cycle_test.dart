// Confirms the sort types and full cycle order of every library screen.
// The chips cycle SortMode.values in enum-declaration order and wrap;
// this test taps through the entire loop on each screen and asserts the
// label sequence, including wrap-around back to the first mode.
import 'package:burrow/models/book.dart';
import 'package:burrow/screens/author_screen.dart';
import 'package:burrow/screens/library_screen.dart';
import 'package:burrow/screens/series_screen.dart';
import 'package:burrow/services/library_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Book _fakeBook(String id, {String? author, String? seriesName}) => Book(
      id: id,
      title: 'Book $id',
      author: author ?? 'Author',
      path: '/tmp/sort-cycle-$id.epub',
      format: BookFormat.epub,
      addedAt: 1,
      seriesIndex: seriesName != null ? 1.0 : null,
    );

Future<void> _pump(WidgetTester t, Widget screen) async {
  t.view.devicePixelRatio = 1.0;
  t.view.physicalSize = const Size(412, 915);
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(home: screen));
  await t.pump();
  await t.pump(const Duration(seconds: 1));
  await t.pump();
  expect(t.takeException(), isNull);
}

/// Taps the sort chip through [labels] and expects each label in order,
/// wrapping from the last job back to the first.
Future<void> _cycle(WidgetTester t, List<String> labels) async {
  expect(find.text(labels.first), findsOneWidget);
  for (var i = 1; i <= labels.length; i++) {
    final from = labels[i - 1];
    final to = labels[i % labels.length];
    await t.tap(find.text(from));
    await t.pump();
    expect(find.text(to), findsOneWidget, reason: 'after tapping $from');
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('library cycles Recent → Added → A–Z → (wrap) Recent', (
    t,
  ) async {
    final lib = LibraryService()..debugAddAll([_fakeBook('a'), _fakeBook('b')]);
    addTearDown(lib.dispose);
    await _pump(t, LibraryScreen(library: lib));
    await _cycle(t, ['Recent', 'Added', 'A–Z']);
  });

  testWidgets('author cycles A–Z → Recent → Added → (wrap) A–Z', (t) async {
    final lib = LibraryService()
      ..debugAddAll([_fakeBook('a', author: 'Best Author')]);
    addTearDown(lib.dispose);
    await _pump(t, AuthorScreen(author: 'Best Author', library: lib));
    await _cycle(t, ['A–Z', 'Recent', 'Added']);
  });

  testWidgets('series cycles Order → A–Z → Recent → Added → (wrap) Order', (
    t,
  ) async {
    final lib = LibraryService()
      ..debugAddAll([_fakeBook('a', seriesName: 'The Long Saga')]);
    addTearDown(lib.dispose);
    await _pump(t, SeriesScreen(series: 'The Long Saga', library: lib));
    await _cycle(t, ['Order', 'A–Z', 'Recent', 'Added']);
  });
}
