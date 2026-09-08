import 'dart:ui';

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
      whiteSpace == null;
}
