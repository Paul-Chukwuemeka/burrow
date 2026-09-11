import 'package:flutter/material.dart';

enum ScanStatus { none, running, done, error }

class ImportBody extends StatelessWidget {
  const ImportBody({
    super.key,
    required this.scanStatus,
    required this.permissionDenied,
  });

  final ScanStatus scanStatus;
  final bool permissionDenied;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    switch (scanStatus) {
      case ScanStatus.running:
        return const SizedBox.shrink();
      case ScanStatus.done:
        return const SizedBox.shrink();
      case ScanStatus.error:
      case ScanStatus.none:
        if (permissionDenied) {
          return Text(
            'no storage access? you can still add books one at a time, '
            'or pick a folder instead.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              color: scheme.onSurfaceVariant,
              fontStyle: FontStyle.italic,
            ),
          );
        }
        return const SizedBox.shrink();
    }
  }
}
