import 'package:burrow/models/book.dart';
import 'package:burrow/screens/author_screen.dart';
import 'package:burrow/services/library_service.dart';
import 'package:burrow/widgets/book_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Book _fakeBook(String id) => Book(
  id: id,
  title: 'Book $id',
  author: 'Author X',
  path: '/tmp/author-sel-$id.epub',
  format: BookFormat.epub,
  addedAt: 1,
);

Future<void> _pumpAuthor(WidgetTester t, LibraryService lib) async {
  t.view.devicePixelRatio = 1.0;
  t.view.physicalSize = const Size(412, 915);
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      home: AuthorScreen(author: 'Author X', library: lib),
    ),
  );
  await t.pump();
  await t.pump(const Duration(seconds: 1));
  expect(t.takeException(), isNull);
}

void main() {
  testWidgets('long-press enters selection, tap adds, delete removes', (
    t,
  ) async {
    final lib = LibraryService()
      ..debugAddAll([_fakeBook('a'), _fakeBook('b'), _fakeBook('c')]);
    addTearDown(lib.dispose);
    await _pumpAuthor(t, lib);
    expect(find.byType(BookCard), findsNWidgets(3));

    // Long-press first tile → selection mode with count "1 selected".
    await t.longPress(find.byType(BookCard).first);
    await t.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    expect(find.byIcon(Icons.check_box_rounded), findsWidgets);

    // Tap second tile → count "2 selected".
    await t.tap(find.byType(BookCard).at(1));
    await t.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
    expect(find.byIcon(Icons.check_box_rounded), findsNWidgets(2));

    // Tap Delete → confirm sheet → Remove → selected tiles gone.
    await t.tap(find.byTooltip('Delete'));
    await t.pumpAndSettle();
    expect(find.text('Remove'), findsWidgets);
    await t.tap(find.widgetWithText(FilledButton, 'Remove'));
    await t.pumpAndSettle();
    expect(find.text('Deleted 2 books'), findsOneWidget);
    expect(find.byType(BookCard), findsOneWidget);
    expect(find.text('1 selected'), findsNothing);
  });
}
