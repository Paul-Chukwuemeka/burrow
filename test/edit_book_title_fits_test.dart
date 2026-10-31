import 'package:burrow/db/database.dart';
import 'package:burrow/models/book.dart';
import 'package:burrow/screens/edit_book_screen.dart';
import 'package:burrow/services/library_service.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Book _book() => Book(
  id: 'edit-title-fits',
  title: 'Notes on the Analytical Engine',
  author: 'Ada Lovelace',
  path: '/tmp/edit-title-fits.epub',
  format: BookFormat.epub,
  addedAt: 1,
);

Future<LibraryService> _seed() async {
  SharedPreferences.setMockInitialValues({});
  final lib = LibraryService();
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  lib.debugAttachDatabase(db);
  await db.insertBook(bookToCompanion(_book()));
  lib.debugAddAll([_book()]);
  addTearDown(() async {
    await db.close();
    lib.dispose();
  });
  return lib;
}

void main() {
  testWidgets('app bar title is not ellipsized on a narrow window', (t) async {
    final lib = await _seed();
    t.view.devicePixelRatio = 1.0;
    // Matches the narrow pane width where 'Edit book' used to render as 'Edi…'.
    t.view.physicalSize = const Size(380, 800);
    addTearDown(t.view.reset);

    await t.pumpWidget(
      MaterialApp(
        home: EditBookScreen(book: _book(), library: lib),
      ),
    );
    await t.pumpAndSettle();

    final titleBox = t.renderObject<RenderBox>(find.text('Edit book'));
    final intrinsicWidth = titleBox.getMinIntrinsicWidth(double.infinity);
    expect(
      titleBox.size.width,
      greaterThanOrEqualTo(intrinsicWidth),
      reason: "'Edit book' must not be ellipsized in the app bar",
    );
  });
}
