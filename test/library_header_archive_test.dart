import 'package:burrow/models/library_enums.dart';
import 'package:burrow/widgets/library_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('header exposes archive entries and invokes them', (
    tester,
  ) async {
    var archiveTapped = 0;
    var hiddenTapped = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: DefaultTabController(
          length: 3,
          child: Scaffold(
            body: CustomScrollView(
              slivers: [
                BurrowHeader(
                  tab: LibraryTab.books,
                  onTabChanged: (_) {},
                  archiveCount: 2,
                  hiddenArchiveCount: 3,
                  onArchive: () => archiveTapped++,
                  onHiddenArchive: () => hiddenTapped++,
                  onSettings: () {},
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();

    expect(find.text('Archive (2)'), findsOneWidget);
    expect(find.text('Hidden archive (3)'), findsOneWidget);

    await tester.tap(find.text('Archive (2)'));
    await tester.pumpAndSettle();
    expect(archiveTapped, 1);

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hidden archive (3)'));
    await tester.pumpAndSettle();
    expect(hiddenTapped, 1);
  });

  testWidgets('header omits counts when the archives are empty', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DefaultTabController(
          length: 3,
          child: Scaffold(
            body: CustomScrollView(
              slivers: [
                BurrowHeader(
                  tab: LibraryTab.books,
                  onTabChanged: (_) {},
                  onArchive: () {},
                  onHiddenArchive: () {},
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();

    expect(find.text('Archive'), findsOneWidget);
    expect(find.text('Hidden archive'), findsOneWidget);
  });
}
