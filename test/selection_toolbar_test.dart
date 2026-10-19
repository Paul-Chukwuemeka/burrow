import 'package:burrow/models/reader_settings.dart';
import 'package:burrow/widgets/selection_toolbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final theme = ReaderTheme.byMode(ReaderThemeMode.sepia);

  testWidgets('single word shows Define, Copy, Share', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SelectionToolbar(
            singleWord: true,
            theme: theme,
            onDefine: () {},
            onCopy: () {},
            onShare: () {},
          ),
        ),
      ),
    );
    expect(find.text('Define'), findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Share'), findsOneWidget);
  });

  testWidgets('multi word hides Define', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SelectionToolbar(
            singleWord: false,
            theme: theme,
            onDefine: () {},
            onCopy: () {},
            onShare: () {},
          ),
        ),
      ),
    );
    expect(find.text('Define'), findsNothing);
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Share'), findsOneWidget);
  });
}
