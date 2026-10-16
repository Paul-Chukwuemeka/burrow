import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'comic_archive.dart' show decodeImageDimensions;

/// Whether [prepareCover] would decode and re-encode [bytes] instead of
/// returning them untouched.
///
/// Cheap (image-header parse only) and mirrors the decision [prepareCover]
/// makes before its full decode; [prepareCoverAsync] uses it to decide whether
/// a worker isolate is worth spawning.
bool coverNeedsDownscale(
  Uint8List bytes, {
  int maxDimension = 480,
  int skipDecodeUnderBytes = 120 * 1024,
}) {
  if (bytes.isEmpty) return false;
  final (w, h) = decodeImageDimensions(bytes);
  if (w > 0 && h > 0) return w > maxDimension || h > maxDimension;
  // Dimensions unknown: only a payload big enough to be worth decoding is
  // worth an isolate.
  return bytes.length > skipDecodeUnderBytes;
}

/// Shrinks a cover to at most [maxDimension] px on its long edge so the
/// library does not decode (or store) multi-megapixel originals. Returns the
/// original bytes when decoding fails or the image is already small.
///
/// Moved verbatim out of the retired Dart parser (`prepareCover`/
/// `_downscaleCover`) so callers no longer depend on the Dart parse engine.
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

/// [prepareCover] off the caller's isolate.
///
/// The decode/resize/re-encode it may perform is hundreds of milliseconds of
/// pure-Dart CPU work; run on the UI isolate that stalls frames one cover at a
/// time. The retired Dart parser did this inside `compute`, and the Rust path
/// must do the same or bulk metadata extraction freezes the UI. Covers that
/// [coverNeedsDownscale] reports are already fine short-circuit before any
/// isolate is spawned.
///
/// Byte-for-byte identical to [prepareCover]: the same function runs, just on
/// a worker isolate.
Future<Uint8List?> prepareCoverAsync(
  List<int>? bytes, {
  int maxDimension = 480,
  int skipDecodeUnderBytes = 120 * 1024,
}) async {
  if (bytes == null || bytes.isEmpty) return null;
  final original = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  if (!coverNeedsDownscale(
    original,
    maxDimension: maxDimension,
    skipDecodeUnderBytes: skipDecodeUnderBytes,
  )) {
    return original;
  }
  return Isolate.run(
    () => prepareCover(
      original,
      maxDimension: maxDimension,
      skipDecodeUnderBytes: skipDecodeUnderBytes,
    ),
  );
}
