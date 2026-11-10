import 'package:burrow/models/reader_settings.dart';
import 'package:burrow/widgets/selection_toolbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final theme = ReaderTheme.byMode(ReaderThemeMode.sepia);

  Widget toolbar({
    required bool singleWord,
    VoidCallback? onHighlight,
    VoidCallback? onNote,
  }) => SelectionToolbar(
    singleWord: singleWord,
    theme: theme,
    onDefine: () {},
    onCopy: () {},
    onShare: () {},
    onHighlight: onHighlight ?? () {},
    onNote: onNote ?? () {},
  );

  testWidgets('single word shows Define, Copy, Share, Highlight, Note', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: toolbar(singleWord: true))),
    );
    expect(find.text('Define'), findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Share'), findsOneWidget);
    expect(find.text('Highlight'), findsOneWidget);
    expect(find.text('Note'), findsOneWidget);
  });

  testWidgets('multi word hides Define', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: toolbar(singleWord: false))),
    );
    expect(find.text('Define'), findsNothing);
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Share'), findsOneWidget);
    expect(find.text('Highlight'), findsOneWidget);
    expect(find.text('Note'), findsOneWidget);
  });

  testWidgets('tapping Highlight calls its callback', (tester) async {
    var tapped = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: toolbar(singleWord: true, onHighlight: () => tapped++),
        ),
      ),
    );

    await tester.tap(find.text('Highlight'));

    expect(tapped, 1);
  });

  testWidgets('all five actions fit and tap at 320 dp', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    var noted = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: toolbar(singleWord: true, onNote: () => noted++),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    for (final label in ['Define', 'Copy', 'Share', 'Highlight', 'Note']) {
      final rect = tester.getRect(find.text(label));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(
        rect.right,
        lessThanOrEqualTo(320),
        reason: '$label is off screen',
      );
    }

    await tester.tap(find.text('Note'));
    expect(noted, 1);
  });
}
