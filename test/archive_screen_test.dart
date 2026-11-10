import 'package:burrow/models/book.dart';
import 'package:burrow/models/library_enums.dart';
import 'package:burrow/screens/archive_screen.dart';
import 'package:burrow/services/library_service.dart';
import 'package:burrow/widgets/book_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Book _book(String id, String title) => Book(
  id: id,
  title: title,
  author: 'Author',
  path: '/tmp/$id.epub',
  format: BookFormat.epub,
  addedAt: 1000,
);

void main() {
  late LibraryService library;

  setUp(() {
    library = LibraryService();
  });

  testWidgets('archive screen shows only its tier and restores a book', (
    tester,
  ) async {
    final active = _book('active', 'Active Book');
    final archived = _book('archived', 'Archived Book');
    library.debugAddAll([active, archived]);
    await library.archiveBooks(['archived']);

    await tester.pumpWidget(
      MaterialApp(
        home: ArchiveScreen(library: library, tier: ArchiveTier.archive),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Archive'), findsOneWidget);
    expect(find.text('Archived Book'), findsWidgets);
    expect(find.text('Active Book'), findsNothing);

    await tester.tap(find.byType(BookListCard));
    await tester.pumpAndSettle();
    expect(find.text('Restore'), findsOneWidget);

    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();

    expect(find.text('No archived books'), findsOneWidget);
    expect(library.activeBooks.map((b) => b.id), contains('archived'));
  });

  testWidgets('archived books can be moved to the hidden tier', (tester) async {
    final archived = _book('archived', 'Archived Book');
    library.debugAddAll([archived]);
    await library.archiveBooks(['archived']);

    await tester.pumpWidget(
      MaterialApp(
        home: ArchiveScreen(library: library, tier: ArchiveTier.archive),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(BookListCard));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move to hidden archive'));
    await tester.pumpAndSettle();

    expect(library.archivedBooks, isEmpty);
    expect(library.hiddenArchiveBooks.map((b) => b.id), ['archived']);
    expect(find.text('No archived books'), findsOneWidget);
  });

  testWidgets('hidden archive screen hides the move-to-hidden action', (
    tester,
  ) async {
    final hidden = _book('hidden', 'Hidden Book');
    library.debugAddAll([hidden]);
    await library.archiveBooks(['hidden'], tier: ArchiveTier.hidden);

    await tester.pumpWidget(
      MaterialApp(
        home: ArchiveScreen(library: library, tier: ArchiveTier.hidden),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Hidden archive'), findsOneWidget);
    await tester.tap(find.byType(BookListCard));
    await tester.pumpAndSettle();

    expect(find.text('Restore'), findsOneWidget);
    expect(find.text('Move to archive'), findsOneWidget);
    expect(find.text('Move to hidden archive'), findsNothing);
  });

  testWidgets('long-press selection restores multiple books', (tester) async {
    final one = _book('one', 'One');
    final two = _book('two', 'Two');
    library.debugAddAll([one, two]);
    await library.archiveBooks(['one', 'two']);

    await tester.pumpWidget(
      MaterialApp(
        home: ArchiveScreen(library: library, tier: ArchiveTier.archive),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.byType(BookListCard).first);
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.restore_rounded));
    await tester.pumpAndSettle();

    expect(library.activeBooks.map((b) => b.id), contains('one'));
    expect(library.archivedBooks.map((b) => b.id), ['two']);
  });
}
