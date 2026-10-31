import 'package:burrow/models/book.dart';
import 'package:burrow/widgets/library_filter_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('genre section shows "Show more" when chips exceed three lines', (tester) async {
    _narrowSurface(tester);
    await _pumpSheet(tester, books: _genres(_narrowGenres));

    expect(find.text('Show more'), findsOneWidget);
  });

  testWidgets('genre section hides "Show more" when chips fit within three lines', (tester) async {
    // Wide surface: all chips fit in two lines under the count-based rule, so
    // "Show more" would reveal nothing. It must not appear.
    await _pumpSheet(tester, books: _genres([for (var i = 0; i < 8; i++) _shortGenres[i]]));

    expect(find.text('Show more'), findsNothing);
  });

  testWidgets('genre section collapses chips to exactly three lines', (tester) async {
    _narrowSurface(tester);
    await _pumpSheet(tester, books: _genres(_narrowGenres));

    expect(
      tester.getSize(_sectionClip('Genre')).height,
      _threeLines,
      reason: 'Collapsed chip wrap must show three full chip lines, not a clipped partial row',
    );
  });

  testWidgets('genre section reveals chips beyond three lines via "Show more"', (tester) async {
    _narrowSurface(tester);
    String? picked;
    await _pumpSheet(tester, books: _genres(_narrowGenres), onGenreChanged: (g) => picked = g);

    expect(find.text('Show more'), findsOneWidget);
    await tester.tap(find.text('Show more'));
    await tester.pumpAndSettle();

    expect(find.text('Show less'), findsOneWidget);

    await tester.tap(find.text('Fictional Worlds V'));
    await tester.pumpAndSettle();

    expect(picked, 'Fictional Worlds V');
  });

  testWidgets('series section collapses to exactly three lines with "Show more"', (tester) async {
    _narrowSurface(tester);
    await _pumpSheet(tester, books: _series(_narrowSeries));

    expect(find.text('Show more'), findsOneWidget);
    expect(tester.getSize(_sectionClip('Series')).height, _threeLines);
  });

  testWidgets('very long single-token series label does not overflow its pill', (tester) async {
    _narrowSurface(tester);
    const hugeLabel = 'com3d2-yamato-nadesiko-gp0ffb (opens in a new tab)';
    await _pumpSheet(tester, books: _series([hugeLabel]));

    expect(tester.takeException(), isNull);

    // The label must wrap inside the chip rather than painting past it,
    // so its width stays within the sheet's content width (400 - 24*2).
    final labelSize = tester.getSize(find.text(hugeLabel));
    expect(labelSize.width, lessThanOrEqualTo(352));
  });

  testWidgets('series section reveals chips beyond three lines via "Show more"', (tester) async {
    _narrowSurface(tester);
    String? picked;
    await _pumpSheet(tester, books: _series(_narrowSeries), onSeriesChanged: (s) => picked = s);

    expect(find.text('Show more'), findsOneWidget);
    await tester.tap(find.text('Show more'));
    await tester.pumpAndSettle();

    expect(find.text('Show less'), findsOneWidget);

    await tester.tap(find.text('Deep Space Saga V'));
    await tester.pumpAndSettle();

    expect(picked, 'Deep Space Saga V');
  });
}

/// Three chip lines: three 48px chips plus two 8px gaps between them.
const double _threeLines = 3 * 48 + 2 * 8;

/// The ClipRect that clamps a section's chip wrap, scoped through the
/// section's label so the viewport's own ClipRect is not matched.
Finder _sectionClip(String label) =>
    find
        .descendant(of: find.widgetWithText(FilterSection, label), matching: find.byType(ClipRect))
        .first;

// Long names so narrow-surface chips wrap to one per line, forcing > 3 lines.
// Kept under ~19 chars so the square Ahem test glyph metrics (13dp/char) keep
// each chip on a single line instead of wrapping inside the chip.
const List<String> _narrowGenres = [
  'Fictional Worlds I',
  'Fictional Worlds II',
  'Fictional Worlds III',
  'Fictional Worlds IV',
  'Fictional Worlds V',
  'Fictional Worlds VI',
];

const _shortGenres = ['Fantasy', 'Poetry', 'Drama', 'Horror', 'Sci-Fi', 'Mystery', 'Romance', 'History'];

// Series names in their own shape, same one-per-line sizing constraint.
const List<String> _narrowSeries = [
  'Deep Space Saga I',
  'Deep Space Saga II',
  'Deep Space Saga III',
  'Deep Space Saga IV',
  'Deep Space Saga V',
  'Deep Space Saga VI',
];

void _narrowSurface(WidgetTester tester) {
  // 400dp-wide window: ~352dp of content width, long chip names fit one per line.
  tester.view.physicalSize = const Size(400, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _pumpSheet(
  WidgetTester tester, {
  required List<Book> books,
  ValueChanged<String?>? onGenreChanged,
  ValueChanged<String?>? onSeriesChanged,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: FilterSheet(
          statusFilter: ReadingStatus.all,
          genreFilter: null,
          seriesFilter: null,
          formatFilters: const <BookFormat>{},
          books: books,
          onStatusChanged: (_) {},
          onGenreChanged: onGenreChanged ?? (_) {},
          onSeriesChanged: onSeriesChanged ?? (_) {},
          onFormatsChanged: (_) {},
          onClearAll: () {},
        ),
      ),
    ),
  );
  // One extra frame: the collapsed/expanded state resolves after first layout.
  await tester.pumpAndSettle();
}

List<Book> _genres(List<String> genres) => [
  for (var i = 0; i < genres.length; i++)
    _book('g$i', genres[i], null),
];

List<Book> _series(List<String> names) => [
  for (var i = 0; i < names.length; i++)
    _book('s$i', null, names[i]),
];

Book _book(String id, String? genre, String? seriesName) => Book(
  id: id,
  title: 'T $id',
  author: 'A $id',
  path: '/books/$id.epub',
  format: BookFormat.epub,
  addedAt: 0,
  genre: genre,
  seriesName: seriesName,
);
