import 'package:burrow/db/database.dart' as db;
import 'package:burrow/models/reader_settings.dart';
import 'package:burrow/widgets/highlight_actions_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final theme = ReaderTheme.byMode(ReaderThemeMode.sepia);

  db.HighlightRow row({String note = ''}) => db.HighlightRow(
    id: 'h1',
    bookId: 'b1',
    quote: 'quoted words',
    note: note,
    color: 0,
    chapter: 0,
    startOffset: 10,
    endChapter: 0,
    endOffset: 20,
    createdAt: 1700000000000,
  );

  Future<void> open(
    WidgetTester tester, {
    String note = '',
    VoidCallback? onOpenNote,
    VoidCallback? onEditNote,
    VoidCallback? onChangeColor,
    VoidCallback? onDelete,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showHighlightActions(
                context,
                row: row(note: note),
                theme: theme,
                onOpenNote: onOpenNote ?? () {},
                onEditNote: onEditNote ?? () {},
                onChangeColor: onChangeColor ?? () {},
                onDelete: onDelete ?? () {},
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('shows the quote and the three base actions', (tester) async {
    await open(tester);

    expect(find.text('quoted words'), findsOneWidget);
    expect(find.text('Open note'), findsNothing);
    expect(find.text('Edit note'), findsOneWidget);
    expect(find.text('Change colour'), findsOneWidget);
    expect(find.text('Delete highlight'), findsOneWidget);
  });

  testWidgets('shows Open note only when a note exists', (tester) async {
    await open(tester, note: 'my thought');

    expect(find.text('Open note'), findsOneWidget);
  });

  testWidgets('tapping an action closes the sheet and calls back', (
    tester,
  ) async {
    var deleted = 0;
    await open(tester, onDelete: () => deleted++);

    await tester.tap(find.text('Delete highlight'));
    await tester.pumpAndSettle();

    expect(deleted, 1);
    expect(find.text('Delete highlight'), findsNothing);
  });

  testWidgets('tapping Open note calls its callback', (tester) async {
    var opened = 0;
    await open(tester, note: 'note', onOpenNote: () => opened++);

    await tester.tap(find.text('Open note'));
    await tester.pumpAndSettle();

    expect(opened, 1);
  });

  testWidgets('colour picker returns the chosen index', (tester) async {
    int? chosen;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                chosen = await showHighlightColorPicker(
                  context,
                  current: 0,
                  theme: theme,
                );
              },
              child: const Text('pick'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('pick'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Green'));
    await tester.pumpAndSettle();

    expect(chosen, 1);
  });
}
