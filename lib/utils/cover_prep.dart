import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'comic_archive.dart' show decodeImageDimensions;

/// Shrinks a cover to at most [maxDimension] px on its long edge so the
/// library does not decode (or store) multi-megapixel originals. Returns the
/// original bytes when decoding fails or the image is already small.
///
/// Moved verbatim out of `DocumentParser.prepareCover`/`_downscaleCover` so
/// callers no longer depend on the Dart parse engine (which is being retired).
/// Odd, oversized, or unreadable inputs degrade to the raw bytes; this never
/// throws.
Uint8List? prepareCover(
  List<int>? bytes, {
  int maxDimension = 480,
  int skipDecodeUnderBytes = 120 * 1024,
}) {
  if (bytes == null || bytes.isEmpty) return null;
  final original = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  try {
    // Cheap header parse first: if the image already fits, skip the full
    // decode + re-encode entirely.
    final (w, h) = decodeImageDimensions(original);
    if (w > 0 && h > 0) {
      if (w <= maxDimension && h <= maxDimension) return original;
    } else if (original.length <= skipDecodeUnderBytes) {
      // Dimensions unknown but the payload is tiny; decoding isn't worth it.
      return original;
    }

    final decoded = img.decodeImage(original);
    if (decoded == null) return original;
    if (decoded.width <= maxDimension && decoded.height <= maxDimension) {
      return original;
    }
    final resized = decoded.width >= decoded.height
        ? img.copyResize(decoded, width: maxDimension)
        : img.copyResize(decoded, height: maxDimension);
    return Uint8List.fromList(img.encodeJpg(resized, quality: 78));
  } catch (_) {
    return original;
  }
}
