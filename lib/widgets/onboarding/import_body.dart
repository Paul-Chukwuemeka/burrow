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
          return _PermissionDeniedHint(scheme: scheme);
        }
        return const SizedBox.shrink();
    }
  }
}

class _PermissionDeniedHint extends StatelessWidget {
  const _PermissionDeniedHint({required this.scheme});

  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: scheme.errorContainer,
            shape: BoxShape.circle,
          ),
          child: Icon(
            Icons.folder_off_rounded,
            size: 30,
            color: scheme.onErrorContainer,
          ),
        ),
        const SizedBox(height: 14),
        Text(
          'storage access denied',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'you can still add books one at a time, or pick a folder instead.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            color: scheme.onSurfaceVariant,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 12),
        TextButton.icon(
          onPressed: () {
            // In a real app, this would open app settings via
            // permission_handler's openAppSettings().
          },
          icon: const Icon(Icons.settings_rounded, size: 16),
          label: const Text('Open settings'),
          style: TextButton.styleFrom(
            foregroundColor: scheme.primary,
            textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}
