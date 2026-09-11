import 'dart:ui';

/// A CSS length that is either absolute (already resolved to pixels) or a
/// percentage of the containing block.
///
/// Percentages must stay symbolic until render time: EPUBs overwhelmingly use
/// `max-width: 100%` to make images fit, and resolving that to `100px` at parse
/// time would shrink every illustration to a thumbnail.
class CssLength {
  const CssLength.px(this.value) : isPercent = false;
  const CssLength.percent(this.value) : isPercent = true;

  final double value;
  final bool isPercent;

  /// Pixel size against [basis] (container width for horizontal lengths,
  /// container height for vertical ones).
  double resolve(double basis) => isPercent ? basis * value / 100 : value;

  @override
  bool operator ==(Object other) =>
      other is CssLength && other.value == value && other.isPercent == isPercent;

  @override
  int get hashCode => Object.hash(value, isPercent);

  @override
  String toString() => isPercent ? '$value%' : '${value}px';

  Map<String, dynamic> toJson() => {'v': value, 'p': isPercent};

  static CssLength? fromJson(Object? json) {
    if (json is! Map) return null;
    final v = (json['v'] as num?)?.toDouble();
    if (v == null) return null;
    return json['p'] == true ? CssLength.percent(v) : CssLength.px(v);
  }
}

/// CSS-derived style properties extracted from EPUB stylesheets.
class CssStyle {
  const CssStyle({
    this.fontSize,
    this.color,
    this.textAlign,
    this.textIndent,
    this.marginLeft,
    this.marginRight,
    this.marginTop,
    this.marginBottom,
    this.fontWeight,
    this.fontStyle,
    this.textDecoration,
    this.fontFamily,
    this.lineHeight,
    this.letterSpacing,
    this.wordSpacing,
    this.textTransform,
    this.whiteSpace,
    this.width,
    this.height,
    this.maxWidth,
    this.maxHeight,
  });

  final double? fontSize;
  final Color? color;
  final TextAlign? textAlign;
  final double? textIndent;
  final double? marginLeft;
  final double? marginRight;
  final double? marginTop;
  final double? marginBottom;
  final FontWeight? fontWeight;
  final FontStyle? fontStyle;
  final TextDecoration? textDecoration;
  final String? fontFamily;
  final double? lineHeight;
  final double? letterSpacing;
  final double? wordSpacing;
  final String? textTransform;
  final String? whiteSpace;
  final CssLength? width;
  final CssLength? height;
  final CssLength? maxWidth;
  final CssLength? maxHeight;

  CssStyle merge(CssStyle other) => CssStyle(
        fontSize: other.fontSize ?? fontSize,
        color: other.color ?? color,
        textAlign: other.textAlign ?? textAlign,
        textIndent: other.textIndent ?? textIndent,
        marginLeft: other.marginLeft ?? marginLeft,
        marginRight: other.marginRight ?? marginRight,
        marginTop: other.marginTop ?? marginTop,
        marginBottom: other.marginBottom ?? marginBottom,
        fontWeight: other.fontWeight ?? fontWeight,
        fontStyle: other.fontStyle ?? fontStyle,
        textDecoration: other.textDecoration ?? textDecoration,
        fontFamily: other.fontFamily ?? fontFamily,
        lineHeight: other.lineHeight ?? lineHeight,
        letterSpacing: other.letterSpacing ?? letterSpacing,
        wordSpacing: other.wordSpacing ?? wordSpacing,
        textTransform: other.textTransform ?? textTransform,
        whiteSpace: other.whiteSpace ?? whiteSpace,
        width: other.width ?? width,
        height: other.height ?? height,
        maxWidth: other.maxWidth ?? maxWidth,
        maxHeight: other.maxHeight ?? maxHeight,
      );

  bool get isEmpty =>
      fontSize == null &&
      color == null &&
      textAlign == null &&
      textIndent == null &&
      marginLeft == null &&
      marginRight == null &&
      marginTop == null &&
      marginBottom == null &&
      fontWeight == null &&
      fontStyle == null &&
      textDecoration == null &&
      fontFamily == null &&
      lineHeight == null &&
      letterSpacing == null &&
      wordSpacing == null &&
      textTransform == null &&
      whiteSpace == null &&
      width == null &&
      height == null &&
      maxWidth == null &&
      maxHeight == null;

  Map<String, dynamic> toJson() => {
        if (fontSize != null) 'fontSize': fontSize,
        if (color != null) 'color': color!.toARGB32(),
        if (textAlign != null) 'textAlign': textAlign!.name,
        if (textIndent != null) 'textIndent': textIndent,
        if (marginLeft != null) 'marginLeft': marginLeft,
        if (marginRight != null) 'marginRight': marginRight,
        if (marginTop != null) 'marginTop': marginTop,
        if (marginBottom != null) 'marginBottom': marginBottom,
        if (fontWeight != null) 'fontWeight': fontWeight!.value,
        if (fontStyle != null) 'fontStyle': fontStyle!.name,
        if (textDecoration != null) 'textDecoration': _decorationName(textDecoration!),
        if (fontFamily != null) 'fontFamily': fontFamily,
        if (lineHeight != null) 'lineHeight': lineHeight,
        if (letterSpacing != null) 'letterSpacing': letterSpacing,
        if (wordSpacing != null) 'wordSpacing': wordSpacing,
        if (textTransform != null) 'textTransform': textTransform,
        if (whiteSpace != null) 'whiteSpace': whiteSpace,
        if (width != null) 'width': width!.toJson(),
        if (height != null) 'height': height!.toJson(),
        if (maxWidth != null) 'maxWidth': maxWidth!.toJson(),
        if (maxHeight != null) 'maxHeight': maxHeight!.toJson(),
      };

  static CssStyle fromJson(Map<String, dynamic> json) => CssStyle(
        fontSize: (json['fontSize'] as num?)?.toDouble(),
        color: json['color'] != null ? Color(json['color'] as int) : null,
        textAlign: _enumByName(TextAlign.values, json['textAlign']),
        textIndent: (json['textIndent'] as num?)?.toDouble(),
        marginLeft: (json['marginLeft'] as num?)?.toDouble(),
        marginRight: (json['marginRight'] as num?)?.toDouble(),
        marginTop: (json['marginTop'] as num?)?.toDouble(),
        marginBottom: (json['marginBottom'] as num?)?.toDouble(),
        fontWeight: _fontWeightFromValue(json['fontWeight']),
        fontStyle: _enumByName(FontStyle.values, json['fontStyle']),
        textDecoration:
            _decorationByName(json['textDecoration']),
        fontFamily: json['fontFamily'] as String?,
        lineHeight: (json['lineHeight'] as num?)?.toDouble(),
        letterSpacing: (json['letterSpacing'] as num?)?.toDouble(),
        wordSpacing: (json['wordSpacing'] as num?)?.toDouble(),
        textTransform: json['textTransform'] as String?,
        whiteSpace: json['whiteSpace'] as String?,
        width: CssLength.fromJson(json['width']),
        height: CssLength.fromJson(json['height']),
        maxWidth: CssLength.fromJson(json['maxWidth']),
        maxHeight: CssLength.fromJson(json['maxHeight']),
      );

  static T? _enumByName<T extends Enum>(List<T> values, Object? name) {
    if (name is! String) return null;
    for (final v in values) {
      if (v.name == name) return v;
    }
    return null;
  }

  static FontWeight? _fontWeightFromValue(Object? value) {
    if (value is! num) return null;
    for (final w in FontWeight.values) {
      if (w.value == value) return w;
    }
    return null;
  }

  static String _decorationName(TextDecoration d) {
    if (d == TextDecoration.underline) return 'underline';
    if (d == TextDecoration.overline) return 'overline';
    if (d == TextDecoration.lineThrough) return 'lineThrough';
    return 'none';
  }

  static TextDecoration? _decorationByName(Object? name) => switch (name) {
        'underline' => TextDecoration.underline,
        'overline' => TextDecoration.overline,
        'lineThrough' => TextDecoration.lineThrough,
        _ => null,
      };
}
