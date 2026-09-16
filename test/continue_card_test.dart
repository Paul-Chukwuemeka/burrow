import 'package:burrow/models/book.dart';
import 'package:burrow/widgets/library_state_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Book _longBook() => Book(
  id: 'continue-card-test',
  title:
      'A Very Long Book Title That Will Surely Wrap Onto Two Full Lines Here',
  author: 'An Author With A Remarkably Long Name For Testing Purposes',
  path: '/tmp/book.epub',
  format: BookFormat.epub,
  addedAt: 0,
  lastReadAt: 1,
  progress: 0.42,
);

Future<void> _pumpCard(WidgetTester tester, double textScale) async {
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          textScaler: TextScaler.linear(textScale),
        ),
        child: Scaffold(
          body: SizedBox(
            width: 400,
            child: ContinueCard(book: _longBook(), onTap: () {}),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('ContinueCard text scaling', () {
    for (final scale in [1.0, 1.5, 2.0]) {
      testWidgets('lays out without overflow at textScaler $scale', (
        tester,
      ) async {
        await _pumpCard(tester, scale);
        // RenderFlex overflows surface as FlutterError during pump; the
        // framework fails the test automatically, but assert explicitly too.
        expect(tester.takeException(), isNull);
        // The Semantics label repeats the title, so scope Text lookups to
        // the rendered card subtree.
        final card = find.byType(ContinueCard);
        expect(card, findsOneWidget);
        expect(
          find.descendant(
            of: card,
            matching: find.textContaining('CONTINUE READING'),
          ),
          findsOneWidget,
        );
        // The placeholder cover also renders the title (maxLines 3); the
        // card title is the maxLines-2 Text.
        expect(
          find.descendant(
            of: card,
            matching: find.byWidgetPredicate(
              (w) =>
                  w is Text &&
                  w.maxLines == 2 &&
                  (w.data?.contains('Very Long Book Title') ?? false),
            ),
          ),
          findsOneWidget,
        );
      });
    }
  });
}
