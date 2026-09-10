import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'css_style.dart';

/// A styled range of a chapter's plain text.
///
/// Runs use the same character offsets as the chapter body, so pagination
/// (which works on plain text) and rich rendering share one coordinate space.
/// [quote] marks blockquote text: rendered italic in the theme's muted color.
@immutable
class StyleRun {
  const StyleRun(
    this.start,
    this.end, {
    this.bold = false,
    this.italic = false,
    this.quote = false,
    this.css,
  });

  final int start;
  final int end;
  final bool bold;
  final bool italic;
  final bool quote;
  final CssStyle? css;

  @override
  bool operator ==(Object other) =>
      other is StyleRun &&
      other.start == start &&
      other.end == end &&
      other.bold == bold &&
      other.italic == italic &&
      other.quote == quote &&
      other.css == css;

  @override
  int get hashCode => Object.hash(start, end, bold, italic, quote, css);
}

/// An inline image embedded in the chapter text at [offset].
///
/// The image occupies a single `\uFFFC` placeholder character at [offset] in
/// the chapter body, so it shares the same coordinate space as [StyleRun]s.
@immutable
class ImageRun {
  const ImageRun({
    required this.offset,
    required this.bytes,
    required this.intrinsicWidth,
    required this.intrinsicHeight,
    this.alt = '',
    this.fullWidth = false,
    this.onTap,
    this.css,
    this.elementId = '',
    this.htmlWidth,
    this.htmlHeight,
  });

  /// Character offset in the chapter body where the `\uFFFC` placeholder lives.
  final int offset;

  /// Raw image bytes (PNG, JPEG, GIF, etc.).
  final Uint8List bytes;

  /// Intrinsic pixel dimensions of the source image.
  final int intrinsicWidth;
  final int intrinsicHeight;
  final String alt;

  /// When true, the image renders at full content width without the
  /// [maxInlineImageHeight] cap. Use for cover/decorative page images.
  final bool fullWidth;

  /// Optional tap callback for inline images (e.g., to show a full-screen
  /// popup). If null, no tap gesture is attached.
  final VoidCallback? onTap;

  /// CSS-derived sizing rules matched to this image element.
  final CssStyle? css;

  /// HTML element id of the `<img>` tag, used for CSS rule matching.
  final String elementId;

  /// HTML `width` attribute value (pixels), used as fallback sizing.
  final double? htmlWidth;

  /// HTML `height` attribute value (pixels), used as fallback sizing.
  final double? htmlHeight;

  /// Maximum pixel height for inline images regardless of page size.
  /// Set to [double.infinity] to disable.
  static const double maxInlineImageHeight = 150;

  /// Capped (width, height) that fits the image within [renderWidth] while
  /// never exceeding [maxInlineImageHeight] vertically, preserving aspect
  /// ratio.
  Size renderedSize(double renderWidth, {double maxHeight = double.infinity}) {
    // Use CSS dimensions as primary source when available.
    if (css != null) {
      var w = css!.width;
      var h = css!.height;

      // Resolve percentage values relative to renderWidth.
      if (w != null && w <= 0) w = null;
      if (h != null && h <= 0) h = null;

      // If only one dimension is set, derive the other from aspect ratio.
      if (w != null && h == null && intrinsicWidth > 0 && intrinsicHeight > 0) {
        h = w * (intrinsicHeight / intrinsicWidth);
      } else if (h != null && w == null && intrinsicWidth > 0 && intrinsicHeight > 0) {
        w = h * (intrinsicWidth / intrinsicHeight);
      }

      // Fall back to HTML attributes, then intrinsic dimensions.
      w ??= htmlWidth;
      h ??= htmlHeight;
      w ??= intrinsicWidth.toDouble();
      h ??= intrinsicHeight.toDouble();

      // Apply max-width / max-height caps.
      if (css!.maxWidth != null && w > css!.maxWidth!) {
        final scale = css!.maxWidth! / w;
        w = css!.maxWidth!;
        h *= scale;
      }
      if (css!.maxHeight != null && h > css!.maxHeight!) {
        final scale = css!.maxHeight! / h;
        h = css!.maxHeight!;
        w *= scale;
      }

      // Apply inline image height cap (unless fullWidth).
      if (!fullWidth && h > maxInlineImageHeight) {
        final scale = maxInlineImageHeight / h;
        h = maxInlineImageHeight;
        w *= scale;
      }

      return Size(
        w.clamp(40.0, renderWidth),
        h.clamp(40.0, 800.0),
      );
    }

    // HTML attribute fallback (no CSS).
    var w = htmlWidth;
    var h = htmlHeight;
    if (w != null || h != null) {
      w ??= (h != null && intrinsicWidth > 0 && intrinsicHeight > 0)
          ? h * (intrinsicWidth / intrinsicHeight)
          : intrinsicWidth.toDouble();
      h ??= (intrinsicWidth > 0 && intrinsicHeight > 0)
          ? w * (intrinsicHeight / intrinsicWidth)
          : intrinsicHeight.toDouble();

      if (!fullWidth && h > maxInlineImageHeight) {
        final scale = maxInlineImageHeight / h;
        h = maxInlineImageHeight;
        w *= scale;
      }

      return Size(
        w.clamp(40.0, renderWidth),
        h.clamp(40.0, 800.0),
      );
    }

    // Original intrinsic-based sizing.
    if (intrinsicWidth <= 0 || intrinsicHeight <= 0) {
      return Size(renderWidth, 160);
    }
    final scale = renderWidth / intrinsicWidth;
    var w2 = renderWidth;
    var h2 = intrinsicHeight * scale;

    // Cap height so decorative art does not dominate the page,
    // unless this is a cover/full-width image.
    if (!fullWidth && h2 > maxInlineImageHeight) {
      h2 = maxInlineImageHeight;
      w2 = intrinsicWidth * (h2 / intrinsicHeight);
    }

    return Size(
      w2.clamp(40.0, renderWidth),
      h2.clamp(40.0, 800.0),
    );
  }

  /// Rendered width at [renderWidth], optionally capped by [maxHeight].
  double renderedWidth(double renderWidth, {double maxHeight = double.infinity}) =>
      renderedSize(renderWidth, maxHeight: maxHeight).width;

  /// Rendered height at [renderWidth], optionally capped by [maxHeight].
  double renderedHeight(double renderWidth, {double maxHeight = double.infinity}) =>
      renderedSize(renderWidth, maxHeight: maxHeight).height;
}

/// Builds the [TextSpan] children covering `text[start:end)`, applying every
/// style run that intersects the range.
///
/// Segments outside any run inherit the parent span's [base] style. Color has
/// no effect on layout, so measurement may omit [quoteColor] while rendering
/// supplies it — both produce identical line breaking.
List<TextSpan> buildStyledSpans(
  String text,
  List<StyleRun> runs,
  TextStyle base,
  int start,
  int end, {
  Color? quoteColor,
}) {
  if (runs.isEmpty || start >= end) {
    return [TextSpan(text: text.substring(start, math.max(start, end)))];
  }

  final spans = <TextSpan>[];
  var cursor = start;
  for (final run in runs) {
    final rs = math.max(run.start, start);
    final re = math.min(run.end, end);
    if (re <= rs) continue;
    if (cursor < rs) {
      spans.add(TextSpan(text: text.substring(cursor, rs)));
    }
    spans.add(TextSpan(
      text: text.substring(rs, re),
      style: base.copyWith(
        fontWeight: run.bold ? FontWeight.w700 : null,
        fontStyle:
            run.italic || run.quote ? FontStyle.italic : null,
        color: run.quote ? (quoteColor ?? base.color) : null,
      ),
    ));
    cursor = re;
  }
  if (cursor < end) {
    spans.add(TextSpan(text: text.substring(cursor, end)));
  }
  return spans;
}
