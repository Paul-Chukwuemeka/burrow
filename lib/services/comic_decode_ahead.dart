import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

/// How much sharper than strictly display-fit a comic page decodes, so mild
/// pinch-zoom stays crisp. Decodes are still capped at native resolution.
const comicDecodeHeadroom = 1.5;

/// A page decode never exceeds a 2048 px dimension (defensive: the codec's
/// sweet spot for giant scans).
const comicMaxDecodeDimension = 2048;

/// A page decode never uses more than 4 M pixels (~16 MB RGBA), bounding the
/// image-cache working set for the decode-ahead window.
const comicMaxDecodePixels = 4 * 1024 * 1024;

/// Pixel dimensions to decode a comic page at, or null when the page has no
/// usable intrinsic size (the reader then decodes at natural resolution,
/// matching the pre-decode-ahead behavior).
///
/// The scale is computed from how the page actually fits the viewport
/// ([fit]), scaled up by the device's pixel ratio and [comicDecodeHeadroom],
/// then clamped to the native size so nothing is upsampled. Potential gap:
/// `Image.memory(cacheWidth:, cacheHeight:)` resizes to *exactly* the two
/// given dimensions, so these must preserve the intrinsic aspect ratio —
/// hence the single shared [displayScale] for both axes.
(int, int)? comicPageDecodeBounds({
  required BoxFit fit,
  required Size viewport,
  required double devicePixelRatio,
  required (int, int)? intrinsic,
}) {
  final (naturalWidth, naturalHeight) = intrinsic ?? (0, 0);
  if (naturalWidth <= 0 ||
      naturalHeight <= 0 ||
      viewport.width <= 0 ||
      viewport.height <= 0 ||
      devicePixelRatio <= 0) {
    return null;
  }
  final displayScale = switch (fit) {
    BoxFit.fitWidth => viewport.width / naturalWidth,
    BoxFit.fitHeight => viewport.height / naturalHeight,
    BoxFit.contain =>
      math.min(
        viewport.width / naturalWidth,
        viewport.height / naturalHeight,
      ),
    // BoxFit.fill/cover/none are not offered by the reader's fit mode; treat
    // them like contain so the switch stays exhaustive.
    _ => math.min(
        viewport.width / naturalWidth,
        viewport.height / naturalHeight,
      ),
  };
  if (displayScale <= 0 || displayScale.isNaN) return null;
  final decodeScale = math.min(
    displayScale * devicePixelRatio * comicDecodeHeadroom,
    1.0, // never decode above the page's native resolution
  );
  var width = (naturalWidth * decodeScale).floor();
  var height = (naturalHeight * decodeScale).floor();
  // Aspect-preserving caps: dimension overflow and the pixel budget both
  // shrink both axes together — the resize codec distorts when both target
  // dimensions are given, so these must stay aspect-correct.
  const maxDimension = comicMaxDecodeDimension;
  if (width > maxDimension || height > maxDimension) {
    final shrink = math.max(
      width / maxDimension,
      height / maxDimension,
    );
    width = (width / shrink).floor();
    height = (height / shrink).floor();
  }
  if (width * height > comicMaxDecodePixels) {
    final shrink = math.sqrt(comicMaxDecodePixels / (width * height));
    width = (width * shrink).floor();
    height = (height * shrink).floor();
  }
  return (width.clamp(1, maxDimension), height.clamp(1, maxDimension));
}

/// The exact extended-image provider used for a comic page render and its
/// decode-ahead warmup.
///
/// Both call sites must build this through [comicPageImageProvider]: the
/// image cache keys on the provider value, and `Image.memory(cacheWidth:)`
/// would construct its own `ResizeImage` with a different upscaling flag,
/// which can miss the warmed entry. Building it here — once — keeps the key
/// reliable and lets `ResizeImage(…, allowUpscaling: false)` cap decodes at
/// native resolution.
ImageProvider comicPageImageProvider(
  Uint8List bytes,
  (int, int) bounds,
) => ResizeImage(
      MemoryImage(bytes),
      width: bounds.$1,
      height: bounds.$2,
      allowUpscaling: false,
    );

/// Loads one page's bytes, or null when [index] is out of range or the page
/// cannot be fetched.
typedef ComicPageBytesLoader = Future<Uint8List?> Function(int index);

/// Decode target for page [index], or null to skip (unknown intrinsic size).
typedef ComicBoundsResolver = (int, int)? Function(int index);

/// Submits [provider] for caching — production wires this to
/// `precacheImage(provider, context)`; tests record instead.
typedef ComicImageWarmer = void Function(ImageProvider provider);

/// Decodes comic pages ahead of the visible one into Flutter's image cache,
/// so flipping paints instantly instead of decoding at press time.
///
/// Dataplane contract: page *bytes* are cheap (the CBZ provider keeps the
/// whole archive decompressed, CBR holds every page from parse), so this
/// cache only adds the expensive half — an async decode per page, evaluated
/// over a window around the reader position. Both the ahead pass and the
/// rendering widget must build the same `ResizeImage(MemoryImage(bytes))`
/// provider; the produced `Uint8List` keeps instance identity in the byte
/// LRU, so the two constructions hit the same image-cache key exactly.
///
/// Triggered from the screen on open and on every page change:
/// advancing does not repaint anything; it only warms.
class ComicDecodeAhead {
  ComicDecodeAhead({
    required this.loadBytes,
    required this.resolveBounds,
    required this.warmup,
    this.window = 3,
    this.onSkip,
  });

  /// Pages prefetched on each side of the reader position.
  int window;

  final ComicPageBytesLoader loadBytes;
  final ComicBoundsResolver resolveBounds;
  final ComicImageWarmer warmup;

  /// Observability hook for the "skipped, decode impossible" case.
  final void Function(int index, Object reason)? onSkip;

  final Map<int, _DecodeTicket> _tickets = {};

  /// Resolves once all currently pending decodes settle (never throws).
  Future<void> get debugIdle =>
      Future.wait(_tickets.values.map((t) => t.done.future)).then<void>((_) {});

  /// Requests decodes for pages in [center − window, center + window].
  ///
  /// Idempotent per page: in-flight and already-warmed pages dedupe.
  /// Finished tickets persist (so repeats skip) but are pruned when they
  /// fall out of the window — revisiting then re-warms, cheap when the
  /// image cache still holds the frame, a fresh decode when it does not.
  void advance(int center) {
    final window = this.window;
    _tickets.removeWhere(
      (index, ticket) => !ticket.waiting && (index - center).abs() > window,
    );
    for (var i = center - window; i <= center + window; i++) {
      if (i < 0) continue;
      if (_tickets.containsKey(i)) continue;
      final ticket = _DecodeTicket();
      _tickets[i] = ticket;
      unawaited(_decode(i, ticket));
    }
  }

  /// Drops all bookkeeping (called when the provider or book changes).
  void reset() {
    for (final ticket in _tickets.values) {
      if (!ticket.done.isCompleted) ticket.done.complete();
    }
    _tickets.clear();
  }

  void dispose() => reset();

  /// Indices either warmed or currently decoding (test/debug observability).
  @visibleForTesting
  Set<int> get debugDecoded => _tickets.keys.toSet();

  Future<void> _decode(int index, _DecodeTicket ticket) async {
    try {
      final bytes = await loadBytes(index);
      if (bytes == null || bytes.isEmpty) {
        onSkip?.call(index, 'no bytes');
        return;
      }
      final bounds = resolveBounds(index);
      if (bounds == null) {
        onSkip?.call(index, 'no bounds');
        return;
      }
      warmup(comicPageImageProvider(bytes, bounds));
    } catch (error) {
      onSkip?.call(index, error);
    } finally {
      if (!ticket.done.isCompleted) ticket.done.complete();
    }
  }
}

/// Track one requested decode; `done` completes when the decode settles
/// (successfully or not), `waiting` is true while work is pending.
class _DecodeTicket {
  _DecodeTicket();

  final Completer<void> done = Completer<void>();
  bool get waiting => !done.isCompleted;
}
