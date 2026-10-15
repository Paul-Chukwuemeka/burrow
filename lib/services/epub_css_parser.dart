import 'dart:convert';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:csslib/parser.dart' as css;
import 'package:csslib/visitor.dart' as css_visitor;
import 'package:cascadia/cascadia.dart' as cas;
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as dom;

import '../models/css_style.dart';

/// Parses CSS from EPUB archives and resolves styles per HTML element.
///
/// Handles three sources of CSS:
/// 1. External CSS files referenced in the OPF manifest
/// 2. Inline `<style>` blocks in XHTML
/// 3. Inline `style=""` attributes on elements
class EpubCssParser {
  EpubCssParser._({required this.chapterStyles, required this.fontFaces});

  /// Per-chapter CSS rules. Keyed by chapter path.
  final Map<String, List<ResolvedCssRule>> chapterStyles;

  /// Extracted @font-face declarations. Keyed by font-family name.
  final Map<String, FontFaceInfo> fontFaces;

  /// Parses CSS from an EPUB archive.
  ///
  /// If [chapterDom] is provided (keyed by chapter path), the parser reuses
  /// those pre-built DOMs instead of reading and parsing HTML from the archive
  /// a second time.
  static EpubCssParser parse({
    required List<String> spinePaths,
    required Map<String, String> manifest,
    required Uint8List Function(String) readEntry,
    Map<String, dom.Document>? chapterDom,
  }) {
    final allRules = <String, List<ResolvedCssRule>>{};
    final fontFaces = <String, FontFaceInfo>{};

    // Collect CSS file contents from the manifest.
    // NOTE: `manifest` is id -> href (archive path). `readEntry` resolves
    // archive paths, so look up by href — not by manifest id (entry.key).
    final cssFiles = <String, String>{};
    for (final entry in manifest.entries) {
      final href = entry.value;
      if (href.toLowerCase().endsWith('.css')) {
        try {
          final bytes = readEntry(href);
          cssFiles[href] = utf8.decode(bytes, allowMalformed: true);
        } catch (_) {}
      }
    }

    // Compile external CSS once — shared across all chapters.
    // Extract @font-face per CSS file so relative font URLs resolve against
    // that file's directory, not the archive root.
    final externalCss = cssFiles.values.join('\n');
    css_visitor.StyleSheet? externalStylesheet;
    if (externalCss.isNotEmpty) {
      for (final cssEntry in cssFiles.entries) {
        _extractFontFacesFromCss(cssEntry.value, fontFaces, readEntry,
            cssPath: cssEntry.key);
      }
      externalStylesheet = css.compile(externalCss);
    }

    for (final chapterPath in spinePaths) {
      final rules = <ResolvedCssRule>[];
      // Normalize so uppercase / percent-encoded spine paths match the
      // `_normalizeKey`-keyed maps on the document_parser side.
      final key = _normalizeKey(chapterPath);

      // Reuse pre-built DOM if available, otherwise parse from archive.
      // Accept both raw and normalized keys for backward compatibility.
      dom.Document? doc = chapterDom?[chapterPath] ?? chapterDom?[key];
      if (doc == null) {
        try {
          final xhtmlBytes = readEntry(chapterPath);
          final xhtml = utf8.decode(xhtmlBytes, allowMalformed: true);
          doc = html_parser.parse(xhtml);
        } catch (_) {
          allRules[key] = rules;
          continue;
        }
      }

      // Query external CSS rules against this chapter's DOM.
      if (externalStylesheet != null) {
        rules.addAll(_resolveRules(externalStylesheet, doc, fontFaces));
      }

      // Compile and query inline <style> elements per chapter.
      final styleElements = doc.querySelectorAll('style');
      if (styleElements.isNotEmpty) {
        final inlineCss = styleElements.map((e) => e.text).join('\n');
        if (inlineCss.isNotEmpty) {
          final inlineStylesheet = css.compile(inlineCss);
          rules.addAll(_resolveRules(inlineStylesheet, doc, fontFaces));
        }
      }

      _resolveInlineStyles(doc, rules);

      allRules[key] = rules;
    }

    return EpubCssParser._(chapterStyles: allRules, fontFaces: fontFaces);
  }

  static List<ResolvedCssRule> _resolveRules(
    css_visitor.StyleSheet stylesheet,
    dom.Document doc,
    Map<String, FontFaceInfo> fontFaces,
  ) {
    final rules = <ResolvedCssRule>[];

    for (final rule in stylesheet.topLevels) {
      if (rule is css_visitor.RuleSet) {
        final selectorGroups = rule.selectorGroup;
        if (selectorGroups == null) continue;

        for (final sel in selectorGroups.selectors) {
          final selectorText = sel.span?.text ?? sel.toString();
          if (selectorText.isEmpty) continue;
          if (selectorText.startsWith('@')) continue;

          final properties = _extractProperties(
            rule.declarationGroup.declarations,
          );
          if (properties.isEmpty) continue;

          // One unsupported selector (e.g. `p::first-letter`, `::-webkit-*`,
          // common in commercial EPUBs) must not kill the whole chapter.
          try {
            final matchedElements = cas.queryAll(doc, selectorText);

            for (final element in matchedElements) {
              rules.add(
                ResolvedCssRule(
                  selector: selectorText,
                  properties: properties,
                  element: element,
                ),
              );
            }
          } catch (_) {
            continue;
          }
        }
      }
    }

    return rules;
  }

  static void _extractFontFacesFromCss(
    String cssText,
    Map<String, FontFaceInfo> fontFaces,
    Uint8List Function(String) readEntry, {
    String? cssPath,
  }) {
    final ffPattern = RegExp(r'@font-face\s*\{([^}]+)\}', dotAll: true);
    final familyPattern = RegExp(r'font-family\s*:\s*([^;]+)');
    final srcPattern = RegExp(
      r'url\(\s*["\u2018\u2019]?([^"\u2018\u2019\)]+)["\u2018\u2019]?\s*\)',
    );

    for (final match in ffPattern.allMatches(cssText)) {
      final block = match.group(1)!;
      final familyMatch = familyPattern.firstMatch(block);
      final srcMatch = srcPattern.firstMatch(block);

      if (familyMatch != null && srcMatch != null) {
        final family = familyMatch
            .group(1)!
            .replaceAll(RegExp(r"['\u201C\u201D]"), '')
            .trim();
        var rawSrc = srcMatch.group(1)!.trim();
        // Strip query/fragment, ignore absolute/data URLs.
        rawSrc = rawSrc.split('?').first.split('#').first.trim();
        if (family.isNotEmpty && rawSrc.isNotEmpty) {
          if (rawSrc.startsWith('data:') ||
              rawSrc.startsWith('http://') ||
              rawSrc.startsWith('https://') ||
              rawSrc.startsWith('/')) {
            continue;
          }
          // Resolve relative font URLs against the CSS file's directory.
          final src = _resolveFontHref(cssPath, rawSrc);
          Uint8List? bytes;
          try {
            bytes = readEntry(src);
          } catch (_) {}
          fontFaces[family] = FontFaceInfo(
            family: family,
            src: src,
            bytes: bytes,
          );
        }
      }
    }
  }

  /// Resolves a font `url()` [src] found in the CSS file at [cssPath] against
  /// that file's directory, normalizing `.`/`..` segments.
  static String _resolveFontHref(String? cssPath, String src) {
    var clean = src.trim();
    // Strip leading ./ segments.
    while (clean.startsWith('./')) {
      clean = clean.substring(2);
    }
    if (cssPath == null || !cssPath.contains('/')) {
      // CSS at archive root: just normalize .. segments.
      final parts = <String>[];
      for (final part in clean.split('/')) {
        if (part.isEmpty || part == '.') continue;
        if (part == '..') {
          if (parts.isNotEmpty) parts.removeLast();
        } else {
          parts.add(part);
        }
      }
      return parts.join('/');
    }
    final cssDir = cssPath.substring(0, cssPath.lastIndexOf('/'));
    final combined = cssDir.isEmpty ? clean : '$cssDir/$clean';
    final parts = <String>[];
    for (final part in combined.split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        if (parts.isNotEmpty) parts.removeLast();
      } else {
        parts.add(part);
      }
    }
    return parts.join('/');
  }

  static void _resolveInlineStyles(
    dom.Document doc,
    List<ResolvedCssRule> rules,
  ) {
    final elements = doc.querySelectorAll('[style]');
    for (final element in elements) {
      final styleAttr = element.attributes['style'];
      if (styleAttr == null || styleAttr.isEmpty) continue;

      final properties = _parseInlineStyle(styleAttr);
      if (properties.isEmpty) continue;

      rules.add(
        ResolvedCssRule(
          selector: '[inline]',
          properties: properties,
          element: element,
        ),
      );
    }
  }

  static Map<String, String> _parseInlineStyle(String styleText) {
    final props = <String, String>{};
    final declarations = css.compile('a { $styleText }');
    for (final rule in declarations.topLevels) {
      if (rule is css_visitor.RuleSet) {
        props.addAll(_extractProperties(rule.declarationGroup.declarations));
      }
    }
    return props;
  }

  static Map<String, String> _extractProperties(List<dynamic>? decls) {
    final props = <String, String>{};
    if (decls == null) return props;

    for (final decl in decls) {
      if (decl is! css_visitor.Declaration) continue;
      final name = decl.property;
      if (name.isEmpty) continue;
      // NOTE: Neither Expression.toString() nor the expression source span
      // is the value text. toString() yields "Instance of 'Expressions'"
      // for values like `100%`, while the expression span covers only the
      // leading term (`70%` -> `70`, `1em` -> `1`), silently dropping the
      // unit and resolving e.g. `font-size:1em` to 1px. The declaration
      // span covers `name: value`, so cut at the first colon instead.
      final value = _declarationValue(decl) ??
          decl.expression?.span?.text.trim();
      if (value == null || value.isEmpty) continue;
      props[name.toLowerCase()] = value;
    }
    return props;
  }

  /// Value text of [decl] from its own source span (`name: value`), keeping
  /// units (`70%`, `1.3em`) and multi-term values (`10px 0px`) intact.
  /// Splits at the first colon (property names never contain one) and strips
  /// a trailing `!important`. Null when the span holds no value.
  static String? _declarationValue(css_visitor.Declaration decl) {
    final span = decl.span.text;
    final colon = span.indexOf(':');
    if (colon < 0) return null;
    var value = span.substring(colon + 1).trim();
    value = value
        .replaceAll(RegExp(r'\s*!important\s*$', caseSensitive: false), '')
        .trim();
    if (value.endsWith(';')) value = value.substring(0, value.length - 1).trim();
    return value.isEmpty ? null : value;
  }

  /// Lowercase + percent-decode [path] for map keys. Falls back to the raw
  /// path when decoding throws (bare `%`).
  static String _normalizeKey(String path) {
    try {
      return Uri.decodeComponent(path).toLowerCase();
    } catch (_) {
      return path.toLowerCase();
    }
  }

  /// Returns the resolved [CssStyle] for a DOM element in a given chapter.
  CssStyle resolveStyle(String chapterPath, dom.Element element) {
    final rules =
        chapterStyles[chapterPath] ?? chapterStyles[_normalizeKey(chapterPath)];
    if (rules == null) return const CssStyle();

    final matchingProps = <String, String>{};
    for (final rule in rules) {
      if (rule.element == element) {
        matchingProps.addAll(rule.properties);
      }
    }

    if (matchingProps.isEmpty) return const CssStyle();
    return propsToCssStyle(matchingProps);
  }

  /// Converts raw CSS property map to a [CssStyle].
  static CssStyle propsToCssStyle(Map<String, String> props) {
    return CssStyle(
      fontSize: _parseFontSize(props['font-size']),
      color: _parseColor(props['color']),
      textAlign: _parseTextAlign(props['text-align']),
      textIndent: _parseLength(props['text-indent']),
      marginLeft: _parseLength(props['margin-left']),
      marginRight: _parseLength(props['margin-right']),
      marginTop: _parseLength(props['margin-top']),
      marginBottom: _parseLength(props['margin-bottom']),
      fontWeight: _parseFontWeight(props['font-weight']),
      fontStyle: _parseFontStyle(props['font-style']),
      textDecoration: _parseTextDecoration(props['text-decoration']),
      fontFamily: props['font-family']
          ?.replaceAll(RegExp(r"['\u201C\u201D]"), '')
          .trim(),
      lineHeight: _parseLineHeight(props['line-height']),
      letterSpacing: _parseLength(props['letter-spacing']),
      wordSpacing: _parseLength(props['word-spacing']),
      textTransform: props['text-transform'],
      whiteSpace: props['white-space'],
      width: _parseCssLength(props['width']),
      height: _parseCssLength(props['height']),
      maxWidth: _parseCssLength(props['max-width']),
      maxHeight: _parseCssLength(props['max-height']),
    );
  }

  /// Parses a box-model length, preserving percentages for resolution at
  /// render time. `auto`/`none` and unparseable values yield null.
  static CssLength? _parseCssLength(String? value) {
    if (value == null) return null;
    final v = value.trim().toLowerCase();
    if (v.isEmpty ||
        v == 'auto' ||
        v == 'none' ||
        v == 'initial' ||
        v == 'inherit' ||
        v == 'unset') {
      return null;
    }
    if (v.endsWith('%')) {
      final num = double.tryParse(v.substring(0, v.length - 1).trim());
      return num == null ? null : CssLength.percent(num);
    }
    // Viewport units are approximated as a percentage of the container basis.
    if (v.endsWith('vw') || v.endsWith('vh')) {
      final num = double.tryParse(v.substring(0, v.length - 2).trim());
      return num == null ? null : CssLength.percent(num);
    }
    final numStr = v.replaceAll(RegExp(r'[a-z]+$'), '').trim();
    final num = double.tryParse(numStr);
    if (num == null) return null;
    if (v.endsWith('em') || v.endsWith('rem')) return CssLength.px(num * 16);
    if (v.endsWith('pt')) return CssLength.px(num * 1.333);
    return CssLength.px(num);
  }

  static double? _parseFontSize(String? value) {
    if (value == null) return null;
    final numStr = value.replaceAll(RegExp(r'[a-zA-Z%]'), '').trim();
    final num = double.tryParse(numStr);
    if (num == null) return null;

    if (value.endsWith('%')) {
      // Percentage font-size is relative to the inherited (default) size.
      return num * 16 / 100;
    } else if (value.endsWith('em') || value.endsWith('rem')) {
      return num * 16;
    } else if (value.endsWith('pt')) {
      return num * 1.333;
    }
    return num;
  }

  static Color? _parseColor(String? value) {
    if (value == null) return null;
    final v = value.trim().toLowerCase();

    const namedColors = {
      'black': Color(0xFF000000),
      'white': Color(0xFFFFFFFF),
      'red': Color(0xFFFF0000),
      'green': Color(0xFF008000),
      'blue': Color(0xFF0000FF),
      'gray': Color(0xFF808080),
      'grey': Color(0xFF808080),
      'silver': Color(0xFFC0C0C0),
      'orange': Color(0xFFFFA500),
      'purple': Color(0xFF800080),
      'navy': Color(0xFF000080),
      'teal': Color(0xFF008080),
      'maroon': Color(0xFF800000),
      'olive': Color(0xFF808000),
      'yellow': Color(0xFFFFFF00),
    };

    if (namedColors.containsKey(v)) return namedColors[v];

    final hexMatch = RegExp(
      r'^#([0-9a-f]{3,8})$',
      caseSensitive: false,
    ).firstMatch(v);
    if (hexMatch != null) {
      final hex = hexMatch.group(1)!;
      if (hex.length == 3) {
        final r = int.parse(hex[0] + hex[0], radix: 16);
        final g = int.parse(hex[1] + hex[1], radix: 16);
        final b = int.parse(hex[2] + hex[2], radix: 16);
        return Color.fromARGB(255, r, g, b);
      } else if (hex.length == 6) {
        final r = int.parse(hex.substring(0, 2), radix: 16);
        final g = int.parse(hex.substring(2, 4), radix: 16);
        final b = int.parse(hex.substring(4, 6), radix: 16);
        return Color.fromARGB(255, r, g, b);
      } else if (hex.length == 8) {
        final a = int.parse(hex.substring(0, 2), radix: 16);
        final r = int.parse(hex.substring(2, 4), radix: 16);
        final g = int.parse(hex.substring(4, 6), radix: 16);
        final b = int.parse(hex.substring(6, 8), radix: 16);
        return Color.fromARGB(a, r, g, b);
      }
    }

    final rgbMatch = RegExp(
      r'rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*(?:,\s*([\d.]+))?\s*\)',
    ).firstMatch(v);
    if (rgbMatch != null) {
      final r = int.parse(rgbMatch.group(1)!);
      final g = int.parse(rgbMatch.group(2)!);
      final b = int.parse(rgbMatch.group(3)!);
      final a = rgbMatch.group(4) != null
          ? (double.parse(rgbMatch.group(4)!) * 255).round()
          : 255;
      return Color.fromARGB(a, r, g, b);
    }

    return null;
  }

  static TextAlign? _parseTextAlign(String? value) {
    if (value == null) return null;
    return switch (value.trim().toLowerCase()) {
      'left' => TextAlign.left,
      'center' => TextAlign.center,
      'right' => TextAlign.right,
      'justify' => TextAlign.justify,
      _ => null,
    };
  }

  static double? _parseLength(String? value) {
    if (value == null) return null;
    final numStr = value.replaceAll(RegExp(r'[a-zA-Z%]'), '').trim();
    final num = double.tryParse(numStr);
    if (num == null) return null;

    if (value.endsWith('em') || value.endsWith('rem')) {
      return num * 16;
    } else if (value.endsWith('pt')) {
      return num * 1.333;
    }
    return num;
  }

  static FontWeight? _parseFontWeight(String? value) {
    if (value == null) return null;
    return switch (value.trim().toLowerCase()) {
      'bold' => FontWeight.w700,
      'bolder' => FontWeight.w800,
      'lighter' => FontWeight.w300,
      '100' => FontWeight.w100,
      '200' => FontWeight.w200,
      '300' => FontWeight.w300,
      '400' => FontWeight.w400,
      '500' => FontWeight.w500,
      '600' => FontWeight.w600,
      '700' => FontWeight.w700,
      '800' => FontWeight.w800,
      '900' => FontWeight.w900,
      _ => null,
    };
  }

  static FontStyle? _parseFontStyle(String? value) {
    if (value == null) return null;
    return switch (value.trim().toLowerCase()) {
      'italic' => FontStyle.italic,
      'oblique' => FontStyle.italic,
      _ => null,
    };
  }

  static TextDecoration? _parseTextDecoration(String? value) {
    if (value == null) return null;
    final v = value.trim().toLowerCase();
    if (v.contains('underline')) return TextDecoration.underline;
    if (v.contains('line-through')) return TextDecoration.lineThrough;
    if (v.contains('overline')) return TextDecoration.overline;
    return null;
  }

  /// Loads all embedded fonts from the EPUB into Flutter's font system.
  ///
  /// Call this once after [parse] to make EPUB-embedded fonts available for
  /// rendering. Returns a list of loaded font family names for debugging.
  static Future<List<String>> loadEmbeddedFonts(
    Map<String, FontFaceInfo> fontFaces,
  ) async {
    final futures = <Future<void>>[];
    final loaded = <String>[];
    for (final entry in fontFaces.entries) {
      final info = entry.value;
      if (info.bytes == null || info.bytes!.isEmpty) continue;
      try {
        final fontLoader = FontLoader(info.family)
          ..addFont(Future.value(ByteData.view(info.bytes!.buffer)));
        futures.add(fontLoader.load().then((_) => loaded.add(info.family)));
      } catch (_) {}
    }
    await Future.wait(futures);
    return loaded;
  }

  static double? _parseLineHeight(String? value) {
    if (value == null) return null;
    final v = value.trim().toLowerCase();
    if (v.endsWith('%')) {
      // Percentage line-height is a multiple of the font size, which Flutter's
      // unitless `height` already models.
      final num = double.tryParse(v.substring(0, v.length - 1).trim());
      return num == null ? null : num / 100;
    }
    if (v.endsWith('em') || v.endsWith('rem')) {
      // `1.3em` line-height MEANS 1.3x by definition — keep the multiplier.
      // (Resolving against px here would newly break what unit truncation
      // previously got right by accident.)
      return double.tryParse(v.substring(0, v.length - 2).trim());
    }
    if (v.endsWith('px')) {
      // No font context here; resolve against the 16px reference the rest of
      // the parser uses (see _parseFontSize).
      final num = double.tryParse(v.substring(0, v.length - 2).trim());
      return num == null ? null : num / 16;
    }
    if (v.endsWith('pt')) {
      final num = double.tryParse(v.substring(0, v.length - 2).trim());
      return num == null ? null : num * 1.333 / 16;
    }
    final num = double.tryParse(v);
    if (num != null) return num;
    return _parseLength(v);
  }
}

class ResolvedCssRule {
  const ResolvedCssRule({
    required this.selector,
    required this.properties,
    required this.element,
  });

  final String selector;
  final Map<String, String> properties;
  final dom.Element element;
}

class FontFaceInfo {
  const FontFaceInfo({required this.family, required this.src, this.bytes});

  final String family;
  final String src;

  /// Raw font file bytes, resolved from the EPUB archive.
  /// Null if the font file could not be found.
  final Uint8List? bytes;
}
