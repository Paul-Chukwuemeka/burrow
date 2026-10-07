import 'dart:typed_data';

import 'package:burrow/widgets/comic_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('invalid bytes show the error fallback without throwing',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: ComicImage(
            bytes: Uint8List.fromList(List.filled(64, 0)),
            fit: BoxFit.contain,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pump();
    expect(find.byKey(const ValueKey('comic-image-error')), findsOneWidget);
  });
}
