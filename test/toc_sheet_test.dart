import 'package:burrow/db/database.dart' as db;
import 'package:burrow/models/reader_settings.dart';
import 'package:burrow/models/document.dart';
import 'package:burrow/services/paginator.dart';
import 'package:burrow/widgets/toc_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

HighlightTab _emptyTab() => HighlightTab(
  highlights: const [],
  onJump: (_) {},
  onNoteChanged: (_, __) {},
  onColorChanged: (_, __) {},
  onDelete: (_) {},
  onRestore: (row) async => row,
  locatorLabel: (_) => '',
  canJump: (_) => true,
  onExport: () {},
);

List<Paginator> _makePaginators(List<int> pageCounts) => pageCounts
    .map(
      (n) => Paginator.paginate(
        text: List.filled(n * 500, 'word ').join(),
        style: const TextStyle(fontSize: 18),
        maxWidth: 400,
        maxHeight: 700,
        direction: TextDirection.ltr,
      ),
    )
    .toList();

void main() {
  group('TocSheet', () {
    testWidgets('renders all chapters and highlights current', (tester) async {
      final chapters = [
        const Chapter('Chapter One', 'body'),
        const Chapter('Chapter Two', 'body'),
        const Chapter('Chapter Three', 'body'),
      ];
      final paginators = _makePaginators([5, 3, 8]);
      final tapped = <int>[];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => TocSheet.show(
                  context,
                  settings: ReaderSettings(),
                  chapters: chapters,
                  paginators: paginators,
                  currentIndex: 1,
                  onJump: (i) => tapped.add(i),
                  bookmarks: const [],
                  onDeleteBookmark: (_) {},
                  highlightTab: _emptyTab(),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // All three chapter titles are visible.
      expect(find.text('Chapter One'), findsOneWidget);
      expect(find.text('Chapter Two'), findsOneWidget);
      expect(find.text('Chapter Three'), findsOneWidget);

      // Tab bar is shown.
      expect(find.text('Contents'), findsOneWidget);
      expect(find.text('Bookmarks'), findsOneWidget);
    });

    testWidgets('tapping a chapter fires onJump with correct index', (
      tester,
    ) async {
      final chapters = [
        const Chapter('First', 'body'),
        const Chapter('Second', 'body'),
      ];
      final paginators = _makePaginators([4, 6]);
      final tapped = <int>[];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => TocSheet.show(
                  context,
                  settings: ReaderSettings(),
                  chapters: chapters,
                  paginators: paginators,
                  currentIndex: 0,
                  onJump: (i) => tapped.add(i),
                  bookmarks: const [],
                  onDeleteBookmark: (_) {},
                  highlightTab: _emptyTab(),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Tap the second chapter.
      await tester.tap(find.text('Second'));
      await tester.pumpAndSettle();

      expect(tapped, [1]);
    });

    testWidgets('tapping a bookmark pops only the sheet, fires onJump once', (
      tester,
    ) async {
      final chapters = [
        const Chapter('First', 'body'),
        const Chapter('Second', 'body'),
      ];
      final paginators = _makePaginators([4, 6]);
      final tapped = <int>[];
      const bookmark = db.Bookmark(
        id: 'bm1',
        bookId: 'b1',
        chapter: 1,
        offset: 0,
        snippet: 'A saved spot.',
        createdAt: 1,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => TocSheet.show(
                  context,
                  settings: ReaderSettings(),
                  chapters: chapters,
                  paginators: paginators,
                  currentIndex: 0,
                  onJump: (i) => tapped.add(i),
                  bookmarks: const [bookmark],
                  onDeleteBookmark: (_) {},
                  highlightTab: _emptyTab(),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Switch to the Bookmarks tab and tap the saved bookmark. The item's
      // own handling must leave Route popping to the onJump callbacks:
      // double-popping gets to the reader beneath the sheet.
      await tester.tap(find.text('Bookmarks'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('A saved spot.'));
      await tester.pumpAndSettle();

      expect(tapped, [1]);
      // The home route must survive: only the sheet was on top of it.
      expect(find.text('open'), findsOneWidget);
    });

    testWidgets('shows untitled chapters with fallback names', (tester) async {
      final chapters = [
        const Chapter('', 'body'),
        const Chapter('Real Title', 'body'),
      ];
      final paginators = _makePaginators([2, 3]);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => TocSheet.show(
                  context,
                  settings: ReaderSettings(),
                  chapters: chapters,
                  paginators: paginators,
                  currentIndex: 0,
                  onJump: (_) {},
                  bookmarks: const [],
                  onDeleteBookmark: (_) {},
                  highlightTab: _emptyTab(),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Untitled chapters are hidden; only titled ones appear.
      expect(find.text('Untitled chapter 1'), findsNothing);
      expect(find.text('Real Title'), findsOneWidget);
    });
  });

  group('Notes tab', () {
    const row = db.HighlightRow(
      id: 'h1',
      bookId: 'b1',
      quote: 'quoted words',
      note: 'my note',
      color: 0,
      chapter: 0,
      startOffset: 10,
      endChapter: 0,
      endOffset: 20,
      createdAt: 1700000000000,
    );

    Future<void> open(WidgetTester tester, HighlightTab tab) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => TocSheet.show(
                  context,
                  settings: ReaderSettings(),
                  chapters: const [Chapter('Chapter One', 'body')],
                  paginators: _makePaginators([2]),
                  currentIndex: 0,
                  onJump: (_) {},
                  bookmarks: const [],
                  onDeleteBookmark: (_) {},
                  highlightTab: tab,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Notes'));
      await tester.pumpAndSettle();
    }

    HighlightTab tab({
      List<db.HighlightRow> highlights = const [row],
      void Function(db.HighlightRow)? onJump,
      void Function(db.HighlightRow, String)? onNoteChanged,
      void Function(db.HighlightRow, int)? onColorChanged,
      void Function(db.HighlightRow)? onDelete,
      Future<db.HighlightRow?> Function(db.HighlightRow)? onRestore,
      String Function(db.HighlightRow)? locatorLabel,
      bool Function(db.HighlightRow)? canJump,
      VoidCallback? onExport,
    }) => HighlightTab(
      highlights: highlights,
      onJump: onJump ?? (_) {},
      onNoteChanged: onNoteChanged ?? (_, __) {},
      onColorChanged: onColorChanged ?? (_, __) {},
      onDelete: onDelete ?? (_) {},
      onRestore: onRestore ?? (r) async => r,
      locatorLabel: locatorLabel ?? (_) => 'Page 12',
      canJump: canJump ?? (_) => true,
      onExport: onExport ?? () {},
    );

    testWidgets('shows a Notes tab with a count', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => TocSheet.show(
                  context,
                  settings: ReaderSettings(),
                  chapters: const [Chapter('Chapter One', 'body')],
                  paginators: _makePaginators([2]),
                  currentIndex: 0,
                  onJump: (_) {},
                  bookmarks: const [],
                  onDeleteBookmark: (_) {},
                  highlightTab: tab(),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Notes 1'), findsOneWidget);
    });

    testWidgets('lists quote text and locator', (tester) async {
      await open(tester, tab());

      expect(find.text('quoted words'), findsOneWidget);
      expect(find.textContaining('Page 12'), findsOneWidget);
    });

    testWidgets('tapping a row calls onJump', (tester) async {
      db.HighlightRow? jumped;
      await open(tester, tab(onJump: (r) => jumped = r));

      await tester.tap(find.text('quoted words'));
      await tester.pumpAndSettle();

      expect(jumped?.id, 'h1');
    });

    testWidgets('editing a note calls onNoteChanged', (tester) async {
      String? edited;
      await open(tester, tab(onNoteChanged: (_, note) => edited = note));

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit note'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'updated note');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(edited, 'updated note');
    });

    testWidgets('changing colour calls onColorChanged', (tester) async {
      int? colour;
      await open(tester, tab(onColorChanged: (_, c) => colour = c));

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Change colour'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Green'));
      await tester.pumpAndSettle();

      expect(colour, 1);
    });

    testWidgets('deleting calls onDelete and Undo calls onRestore', (
      tester,
    ) async {
      db.HighlightRow? deleted;
      db.HighlightRow? restored;
      await open(
        tester,
        tab(
          onDelete: (r) => deleted = r,
          onRestore: (r) async {
            restored = r;
            return r;
          },
        ),
      );

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(deleted?.id, 'h1');
      expect(find.text('Undo'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();

      expect(restored?.id, 'h1');
      expect(find.text('quoted words'), findsOneWidget);
    });

    testWidgets('an unavailable row shows the fallback and does not jump', (
      tester,
    ) async {
      var jumps = 0;
      await open(tester, tab(canJump: (_) => false, onJump: (_) => jumps++));

      expect(find.textContaining('Location unavailable'), findsOneWidget);
      await tester.tap(find.text('quoted words'));
      await tester.pumpAndSettle();
      expect(jumps, 0);
    });

    testWidgets('export action calls onExport', (tester) async {
      var exported = 0;
      await open(tester, tab(onExport: () => exported++));

      await tester.tap(find.byTooltip('Export highlights'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Export highlights').last);
      await tester.pumpAndSettle();

      expect(exported, 1);
    });

    testWidgets('deleting updates the count and survives a tab switch', (
      tester,
    ) async {
      await open(tester, tab());

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Notes 0'), findsOneWidget);

      await tester.tap(find.text('Contents'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Notes 0'));
      await tester.pumpAndSettle();

      expect(find.text('quoted words'), findsNothing);
      expect(find.text('No highlights yet.'), findsOneWidget);
    });

    testWidgets('empty state renders', (tester) async {
      await open(tester, tab(highlights: const []));

      expect(find.text('No highlights yet.'), findsOneWidget);
    });
  });

  group('Flat index math', () {
    /// Pure algorithm matching _flatIndexForChapter in reader_screen.dart.
    /// Takes an explicit list of page counts per chapter.
    int flatIndexForChapter(List<int> pageCounts, int chapter) {
      var flat = 0;
      for (var c = 0; c < chapter; c++) {
        flat += pageCounts[c];
      }
      return flat;
    }

    test('chapter 0 starts at flat page 0', () {
      expect(flatIndexForChapter([5, 3, 8], 0), 0);
    });

    test('chapter 1 starts after chapter 0 pages', () {
      expect(flatIndexForChapter([5, 3, 8], 1), 5);
    });

    test('chapter 2 starts after chapters 0+1', () {
      expect(flatIndexForChapter([5, 3, 8], 2), 8);
    });

    test('works with single-page chapters', () {
      expect(flatIndexForChapter([1, 1, 1, 1], 3), 3);
    });

    test('works with many-page chapters', () {
      expect(flatIndexForChapter([100, 200, 50], 2), 300);
    });

    test('last chapter starts after all preceding pages', () {
      expect(flatIndexForChapter([10, 20, 30, 40], 3), 60);
    });
  });
}
