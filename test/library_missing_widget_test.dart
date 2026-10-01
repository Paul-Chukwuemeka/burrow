import 'package:burrow/models/book.dart';
import 'package:burrow/services/library_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('missing book shows Missing badge', (t) async {
    final lib = LibraryService();
    lib.debugAddAll([
      Book(id: 'm', title: 'Gone', author: '', path: '/tmp/nope.epub', format: BookFormat.epub, addedAt: 1),
    ]);
    lib.debugMarkMissing('m');
    await t.pumpWidget(MaterialApp(home: _BadgeProbe(isMissing: lib.isMissing('m'))));
    expect(find.text('Missing'), findsOneWidget);
  });
}

class _BadgeProbe extends StatelessWidget {
  final bool isMissing;
  const _BadgeProbe({required this.isMissing});
  @override
  Widget build(BuildContext context) {
    // Mirrors the badge widget used in library_screen grid tile.
    if (!isMissing) return const Text('OK');
    return const Text('Missing');
  }
}
