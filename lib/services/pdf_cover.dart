import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:pdfrx/pdfrx.dart';

/// The book-cover frame the thumbnail is cropped to, at exactly 2:3.
const _coverTargetW = 600;
const _coverTargetH = 900; // 2:3

/// Renders the first page of a PDF as a small JPEG thumbnail cropped to
/// the centre at exactly 2:3 (the book-cover frame), or `null` when the
/// file can't be read (encrypted, corrupt, empty).
///
/// The caller must be an isolate where pdfrx is already initialized (main.dart
/// does this at startup). PDFium's render runs on pdfrx's own background
/// worker; the centre-crop and JPEG encode are pure-Dart CPU work and run on a
/// separate worker isolate, so neither blocks the caller's isolate.
Future<Uint8List?> renderPdfCoverThumbnail(String path) async {
  try {
    final document = await PdfDocument.openFile(path);
    try {
      if (document.pages.isEmpty) return null;
      final page = document.pages[0];
      final pageRatio = page.width / page.height;
      final targetRatio = _coverTargetW / _coverTargetH;

      // Render at native aspect ratio, sized to *cover* the 2:3 target.
      int renderW, renderH;
      if (pageRatio >= targetRatio) {
        // Page wider than 2:3 → match target height, crop sides.
        renderH = _coverTargetH;
        renderW = (_coverTargetH * pageRatio).round();
      } else {
        // Page taller than 2:3 → match target width, crop top/bottom.
        renderW = _coverTargetW;
        renderH = (_coverTargetW / pageRatio).round();
      }

      final pdfImage = await page.render(
        width: renderW,
        height: renderH,
        annotationRenderingMode: PdfAnnotationRenderingMode.none,
      );
      if (pdfImage == null) return null;
      try {
        // Copy the pixels before handing them to the worker: the copy is
        // Dart-owned, so `dispose` cannot invalidate the bytes mid-flight.
        final frame = _CoverFrame(
          pixels: Uint8List.fromList(pdfImage.pixels),
          width: pdfImage.width,
          height: pdfImage.height,
        );
        return await Isolate.run(() => _cropAndEncode(frame));
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

/// A page's raw BGRA pixels, small enough to send to a worker isolate.
class _CoverFrame {
  const _CoverFrame({
    required this.pixels,
    required this.width,
    required this.height,
  });

  final Uint8List pixels;
  final int width;
  final int height;
}

/// Centre-crops [_CoverFrame] to the 2:3 cover frame and encodes JPEG.
///
/// Runs on a worker isolate. The pixel buffer is reinterpreted exactly as
/// pdfrx's own `createImageNF` does (BGRA8888, 4 channels), so the output
/// bytes are unchanged by the move off the caller's isolate.
Uint8List? _cropAndEncode(_CoverFrame frame) {
  final source = img.Image.fromBytes(
    width: frame.width,
    height: frame.height,
    bytes: frame.pixels.buffer,
    numChannels: 4,
    order: img.ChannelOrder.bgra,
  );
  final cropX = ((source.width - _coverTargetW) / 2).round().clamp(
    0,
    source.width,
  );
  final cropY = ((source.height - _coverTargetH) / 2).round().clamp(
    0,
    source.height,
  );
  final cropped = img.copyCrop(
    source,
    x: cropX,
    y: cropY,
    width: _coverTargetW,
    height: _coverTargetH,
  );
  return Uint8List.fromList(img.encodeJpg(cropped, quality: 85));
}
