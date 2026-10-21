// Regression: the collection screen restored its sort from
// collection.sortType on mount, but the chip tap only updated widget
// state — the choice was never written back, so a collection's sort
// reset after an app restart. The tap must persist sortType through
// LibraryService.setCollectionSortType.
import 'package:burrow/db/database.dart' as db;
import 'package:burrow/models/book.dart';
import 'package:burrow/screens/collection_screen.dart';
import 'package:burrow/services/library_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Book _fakeBook(String id) => Book(
      id: id,
      title: 'Book $id',
      author: 'Author',
      path: '/tmp/coll-sort-$id.epub',
      format: BookFormat.epub,
      addedAt: 1,
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

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('collection sort chip persists sortType and survives restart', (
    t,
  ) async {
    final lib = LibraryService()
      ..debugAddAll([_fakeBook('a'), _fakeBook('b')])
      ..debugAddCollection(
        db.Collection(
          id: 'c1',
          name: 'Space Books',
          sortType: 0, // 0 = manual, the stored default
          createdAt: 1,
        ),
      );
    addTearDown(lib.dispose);

    await _pump(
      t,
      CollectionScreen(collection: lib.collections.first, library: lib),
    );
    expect(find.text('Manual'), findsOneWidget);

    // Cycle Manual → A–Z.
    await t.tap(find.text('Manual'));
    await t.pump();
    expect(find.text('A–Z'), findsOneWidget);

    // The choice must be written through to the service immediately.
    expect(lib.collections.first.sortType, 1);

    // Restart: a fresh screen seeds from the persisted sortType.
    await _pump(
      t,
      CollectionScreen(collection: lib.collections.first, library: lib),
    );
    expect(find.text('A–Z'), findsOneWidget);
    expect(find.text('Manual'), findsNothing);
  });

  test('unknown collection id is a no-op', () async {
    final lib = LibraryService();
    addTearDown(lib.dispose);
    await lib.setCollectionSortType('nope', 2);
    expect(lib.collections, isEmpty);
  });
}
