import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'css_style.dart';
import 'reader_settings.dart';

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
    this.sourceKey,
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

  /// EPUB archive entry this image was read from, when known.
  ///
  /// The content cache stores this instead of the raw bytes, and hydration
  /// re-reads the entry from the source file on load. Null for images that
  /// have no backing archive entry (e.g. comics, or legacy data).
  final String? sourceKey;

  ImageRun copyWith({
    int? offset,
    Uint8List? bytes,
    int? intrinsicWidth,
    int? intrinsicHeight,
    String? alt,
    bool? fullWidth,
    VoidCallback? onTap,
    CssStyle? css,
    String? elementId,
    double? htmlWidth,
    double? htmlHeight,
    String? sourceKey,
  }) {
    return ImageRun(
      offset: offset ?? this.offset,
      bytes: bytes ?? this.bytes,
      intrinsicWidth: intrinsicWidth ?? this.intrinsicWidth,
      intrinsicHeight: intrinsicHeight ?? this.intrinsicHeight,
      alt: alt ?? this.alt,
      fullWidth: fullWidth ?? this.fullWidth,
      onTap: onTap ?? this.onTap,
      css: css ?? this.css,
      elementId: elementId ?? this.elementId,
      htmlWidth: htmlWidth ?? this.htmlWidth,
      htmlHeight: htmlHeight ?? this.htmlHeight,
      sourceKey: sourceKey ?? this.sourceKey,
    );
  }

  /// Maximum pixel height for inline images regardless of page size.
  /// Set to [double.infinity] to disable.
  static const double maxInlineImageHeight = 150;

  /// Vertical gap the page renderer puts above and below an inline image.
  /// Pagination measurement must add this too so page heights stay in sync.
  static const double verticalPadding = 8;

  /// Fallback height for an image whose dimensions cannot be determined.
  static const double _unknownImageHeight = 160;

  /// Hard ceiling for full-width images when no page height is known.
  static const double _absoluteMaxHeight = 800;

  /// Capped (width, height) that fits the image within [renderWidth] and
  /// [maxHeight] while preserving aspect ratio.
  ///
  /// Percentages are resolved against the available width (horizontal lengths)
  /// or height (vertical lengths). Inline images are additionally capped at
  /// [maxInlineImageHeight] unless [fullWidth]; full-width/cover images are
  /// capped to [maxHeight] so a full-page illustration never overflows.
  Size renderedSize(double renderWidth, {double maxHeight = double.infinity}) {
    final (naturalW, naturalH) = _naturalSize(renderWidth, maxHeight);
    if (naturalW <= 0 || naturalH <= 0) {
      return Size(renderWidth, _unknownImageHeight);
    }

    // Accumulate every cap as a single scale factor so width and height are
    // never clamped independently (which would distort the aspect ratio).
    var scale = 1.0;
    if (!fullWidth && naturalH > maxInlineImageHeight) {
      scale = math.min(scale, maxInlineImageHeight / naturalH);
    }
    final heightCeiling = maxHeight.isFinite && maxHeight > 0
        ? maxHeight
        : _absoluteMaxHeight;
    if (naturalH > heightCeiling) {
      scale = math.min(scale, heightCeiling / naturalH);
    }
    if (naturalW > renderWidth) {
      scale = math.min(scale, renderWidth / naturalW);
    }

    return Size(naturalW * scale, naturalH * scale);
  }

  /// The image's uncapped (width, height) in logical pixels: CSS dimensions
  /// first, then HTML attributes, then intrinsic pixels, scaled to
  /// [renderWidth] when no explicit width is given.
  (double, double) _naturalSize(double renderWidth, double maxHeight) {
    final heightBasis = maxHeight.isFinite && maxHeight > 0
        ? maxHeight
        : renderWidth;
    final style = css;
    if (style != null) {
      var w = style.width?.resolve(renderWidth);
      var h = style.height?.resolve(heightBasis);
      if (w != null && w <= 0) w = null;
      if (h != null && h <= 0) h = null;

      // Derive the missing axis from the intrinsic aspect ratio, first from
      // the CSS dimension, then from the HTML attribute.
      (double?, double?) derive(double? width, double? height) {
        if (width != null &&
            height == null &&
            intrinsicWidth > 0 &&
            intrinsicHeight > 0) {
          height = width * intrinsicHeight / intrinsicWidth;
        } else if (height != null &&
            width == null &&
            intrinsicWidth > 0 &&
            intrinsicHeight > 0) {
          width = height * intrinsicWidth / intrinsicHeight;
        }
        return (width, height);
      }

      (w, h) = derive(w, h);
      w ??= htmlWidth;
      h ??= htmlHeight;
      (w, h) = derive(w, h);
      w ??= intrinsicWidth.toDouble();
      h ??= intrinsicHeight.toDouble();

      // Compose both caps as the minimum of the independently required
      // scales against the ORIGINAL size: overwriting (instead of min-ing)
      // lets the second cap violate the first (1000x1000 capped at 500x250
      // yielded 500x500).
      var cssScale = 1.0;
      final maxW = style.maxWidth?.resolve(renderWidth);
      if (maxW != null && maxW > 0 && w > 0 && w * cssScale > maxW) {
        cssScale = math.min(cssScale, maxW / w);
      }
      final maxH = style.maxHeight?.resolve(heightBasis);
      if (maxH != null && maxH > 0 && h > 0 && h * cssScale > maxH) {
        cssScale = math.min(cssScale, maxH / h);
      }
      return (w * cssScale, h * cssScale);
    }

    var w = htmlWidth;
    var h = htmlHeight;
    if (w != null || h != null) {
      w ??= (h != null && intrinsicWidth > 0 && intrinsicHeight > 0)
          ? h * intrinsicWidth / intrinsicHeight
          : intrinsicWidth.toDouble();
      h ??= (intrinsicWidth > 0 && intrinsicHeight > 0)
          ? w * intrinsicHeight / intrinsicWidth
          : intrinsicHeight.toDouble();
      return (w, h);
    }

    if (intrinsicWidth <= 0 || intrinsicHeight <= 0) return (0, 0);
    return (
      renderWidth.toDouble(),
      intrinsicHeight * renderWidth / intrinsicWidth,
    );
  }

  /// Rendered width at [renderWidth], optionally capped by [maxHeight].
  double renderedWidth(
    double renderWidth, {
    double maxHeight = double.infinity,
  }) => renderedSize(renderWidth, maxHeight: maxHeight).width;

  /// Rendered height at [renderWidth], optionally capped by [maxHeight].
  double renderedHeight(
    double renderWidth, {
    double maxHeight = double.infinity,
  }) => renderedSize(renderWidth, maxHeight: maxHeight).height;
}

/// Applies the layout-affecting typography from [css] to [style], honoring the
/// user's override preferences.
///
/// Shared by pagination measurement and page rendering so the two can never
/// disagree about line breaking: if the renderer honors an EPUB's `font-size`
/// or `line-height`, the paginator must measure with it too.
TextStyle applyCssStyle(
  TextStyle style,
  CssStyle css,
  ReaderSettings settings,
) {
  var result = style;
  if (css.fontSize != null && !settings.overrideCssFontSize) {
    result = result.copyWith(fontSize: css.fontSize);
  }
  if (css.fontFamily != null &&
      css.fontFamily!.isNotEmpty &&
      !settings.overrideCssFontFamily) {
    result = result.copyWith(fontFamily: css.fontFamily);
  }
  if (css.color != null && !settings.overrideCssColor) {
    result = result.copyWith(color: css.color);
  }
  if (css.fontWeight != null) {
    result = result.copyWith(fontWeight: css.fontWeight);
  }
  if (css.fontStyle != null) {
    result = result.copyWith(fontStyle: css.fontStyle);
  }
  if (css.textDecoration != null) {
    result = result.copyWith(decoration: css.textDecoration);
  }
  if (css.lineHeight != null) {
    result = result.copyWith(height: css.lineHeight);
  }
  if (css.letterSpacing != null) {
    result = result.copyWith(letterSpacing: css.letterSpacing);
  }
  return result;
}

/// Resolves the final [TextStyle] for an optional [run] over [base].
///
/// This is the single place emphasis and CSS are turned into a style. Both the
/// paginator (measurement) and the page renderer call it, so their wrapping and
/// line heights match exactly. [quoteColor] only affects color, which has no
/// effect on layout.
TextStyle styleForRun(
  TextStyle base,
  StyleRun? run, {
  required ReaderSettings settings,
  Color? quoteColor,
}) {
  if (run == null) return base;
  var style = base.copyWith(
    fontWeight: run.bold ? FontWeight.w700 : null,
    fontStyle: run.italic || run.quote ? FontStyle.italic : null,
    color: run.quote ? (quoteColor ?? base.color) : null,
  );
  if (settings.respectCssStyles && run.css != null) {
    style = applyCssStyle(style, run.css!, settings);
  }
  return style;
}

/// Builds the [TextSpan] children covering `text[start:end)`, applying every
/// style run that intersects the range.
///
/// Segments outside any run inherit the parent span's [base] style. When
/// [settings] is supplied, CSS-derived typography is applied too (via
/// [styleForRun]) so the spans measure exactly as they will render. Omitting it
/// keeps the emphasis-only behavior used by lightweight callers.
List<TextSpan> buildStyledSpans(
  String text,
  List<StyleRun> runs,
  TextStyle base,
  int start,
  int end, {
  Color? quoteColor,
  ReaderSettings? settings,
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
    spans.add(
      TextSpan(
        text: text.substring(rs, re),
        style: settings == null
            ? base.copyWith(
                fontWeight: run.bold ? FontWeight.w700 : null,
                fontStyle: run.italic || run.quote ? FontStyle.italic : null,
                color: run.quote ? (quoteColor ?? base.color) : null,
              )
            : styleForRun(
                base,
                run,
                settings: settings,
                quoteColor: quoteColor,
              ),
      ),
    );
    cursor = re;
  }
  if (cursor < end) {
    spans.add(TextSpan(text: text.substring(cursor, end)));
  }
  return spans;
}
