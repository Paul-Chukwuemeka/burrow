import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:pdfrx/pdfrx.dart';

/// Renders the first page of a PDF as a small JPEG thumbnail cropped to
/// the centre at exactly 2:3 (the book-cover frame), or `null` when the
/// file can't be read (encrypted, corrupt, empty).
///
/// The caller must be an isolate where pdfrx is already initialized (main.dart
/// does this at startup). The heavy PDFium work is offloaded by pdfrx to its
/// own background worker, so this never blocks the UI thread.
Future<Uint8List?> renderPdfCoverThumbnail(String path) async {
  const targetW = 600;
  const targetH = 900; // 2:3

  try {
    final document = await PdfDocument.openFile(path);
    try {
      if (document.pages.isEmpty) return null;
      final page = document.pages[0];
      final pageRatio = page.width / page.height;
      final targetRatio = targetW / targetH;

      // Render at native aspect ratio, sized to *cover* the 2:3 target.
      int renderW, renderH;
      if (pageRatio >= targetRatio) {
        // Page wider than 2:3 → match target height, crop sides.
        renderH = targetH;
        renderW = (targetH * pageRatio).round();
      } else {
        // Page taller than 2:3 → match target width, crop top/bottom.
        renderW = targetW;
        renderH = (targetW / pageRatio).round();
      }

      final pdfImage = await page.render(
        width: renderW,
        height: renderH,
        annotationRenderingMode: PdfAnnotationRenderingMode.none,
      );
      if (pdfImage == null) return null;
      try {
        final src = pdfImage.createImageNF();
        // Centre-crop to exact 2:3.
        final cropX = ((src.width - targetW) / 2).round().clamp(0, src.width);
        final cropY = ((src.height - targetH) / 2).round().clamp(0, src.height);
        final cropped = img.copyCrop(
          src,
          x: cropX,
          y: cropY,
          width: targetW,
          height: targetH,
        );
        return img.encodeJpg(cropped, quality: 85);
      } finally {
        pdfImage.dispose();
      }
    } finally {
      await document.dispose();
    }
  } catch (_) {
    return null;
  }
}
