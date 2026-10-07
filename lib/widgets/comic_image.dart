import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Renders one decoded comic page, degrading to a quiet placeholder when the
/// bytes are corrupt or an unsupported format instead of throwing.
class ComicImage extends StatelessWidget {
  const ComicImage({
    super.key,
    required this.bytes,
    required this.fit,
    this.cacheWidth,
    this.cacheHeight,
  });

  final Uint8List bytes;
  final BoxFit fit;
  final int? cacheWidth;
  final int? cacheHeight;

  @override
  Widget build(BuildContext context) {
    return Image.memory(
      bytes,
      fit: fit,
      gaplessPlayback: true,
      cacheWidth: cacheWidth,
      cacheHeight: cacheHeight,
      errorBuilder: (context, error, stack) => const _ComicImageError(),
    );
  }
}

class _ComicImageError extends StatelessWidget {
  const _ComicImageError();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('comic-image-error'),
      alignment: Alignment.center,
      color: scheme.surfaceContainerHighest,
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.broken_image_outlined, color: scheme.onSurfaceVariant),
          const SizedBox(height: 8),
          Text(
            'Page could not be displayed',
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
