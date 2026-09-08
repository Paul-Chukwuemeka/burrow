import 'dart:typed_data';
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
  EpubCssParser._({
    required this.chapterStyles,
    required this.fontFaces,
  });

  /// Per-chapter CSS rules. Keyed by chapter path.
  final Map<String, List<ResolvedCssRule>> chapterStyles;

  /// Extracted @font-face declarations. Keyed by font-family name.
  final Map<String, FontFaceInfo> fontFaces;

  /// Parses CSS from an EPUB archive.
  static EpubCssParser parse({
    required List<String> spinePaths,
    required Map<String, String> manifest,
    required Uint8List Function(String) readEntry,
  }) {
    final allRules = <String, List<ResolvedCssRule>>{};
    final fontFaces = <String, FontFaceInfo>{};

    // Collect CSS file contents from the manifest.
    final cssFiles = <String, String>{};
    for (final entry in manifest.entries) {
      final href = entry.value;
      if (href.toLowerCase().endsWith('.css')) {
        try {
          final bytes = readEntry(entry.key);
          cssFiles[href] = String.fromCharCodes(bytes);
        } catch (_) {}
      }
    }

    for (final chapterPath in spinePaths) {
      final rules = <ResolvedCssRule>[];

      dom.Document? doc;
      try {
        final xhtmlBytes = readEntry(chapterPath);
        final xhtml = String.fromCharCodes(xhtmlBytes);
        doc = html_parser.parse(xhtml);
      } catch (_) {
        allRules[chapterPath] = rules;
        continue;
      }

      final cssTexts = <String>[];
      for (final cssContent in cssFiles.values) {
        cssTexts.add(cssContent);
      }

      final styleElements = doc.querySelectorAll('style');
      for (final styleEl in styleElements) {
        cssTexts.add(styleEl.text);
      }

      final combinedCss = cssTexts.join('\n');
      if (combinedCss.isNotEmpty) {
        _extractFontFacesFromCss(combinedCss, fontFaces, readEntry);
        final stylesheet = css.compile(combinedCss);
        rules.addAll(_resolveRules(stylesheet, doc, fontFaces));
      }

      _resolveInlineStyles(doc, rules);

      allRules[chapterPath] = rules;
    }

    return EpubCssParser._(
      chapterStyles: allRules,
      fontFaces: fontFaces,
    );
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

          final properties = _extractProperties(rule.declarationGroup.declarations);
          if (properties.isEmpty) continue;

          final matchedElements = cas.queryAll(doc, selectorText);

          for (final element in matchedElements) {
            rules.add(ResolvedCssRule(
              selector: selectorText,
              properties: properties,
              element: element,
            ));
          }
        }
      }
    }

    return rules;
  }

  static void _extractFontFacesFromCss(
    String cssText,
    Map<String, FontFaceInfo> fontFaces,
    Uint8List Function(String) readEntry,
  ) {
    final ffPattern = RegExp(r'@font-face\s*\{([^}]+)\}', dotAll: true);
    final familyPattern = RegExp(r'font-family\s*:\s*([^;]+)');
    final srcPattern = RegExp(r'url\(\s*["\u2018\u2019]?([^"\u2018\u2019\)]+)["\u2018\u2019]?\s*\)');

    for (final match in ffPattern.allMatches(cssText)) {
      final block = match.group(1)!;
      final familyMatch = familyPattern.firstMatch(block);
      final srcMatch = srcPattern.firstMatch(block);

      if (familyMatch != null && srcMatch != null) {
        final family = familyMatch.group(1)!.replaceAll(RegExp(r"['\u201C\u201D]"), '').trim();
        var src = srcMatch.group(1)!;
        if (family.isNotEmpty && src.isNotEmpty) {
          // Resolve relative paths against archive root.
          if (src.startsWith('../')) {
            src = src.substring(3);
          }
          Uint8List? bytes;
          try {
            bytes = readEntry(src);
          } catch (_) {}
          fontFaces[family] = FontFaceInfo(family: family, src: src, bytes: bytes);
        }
      }
    }
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

      rules.add(ResolvedCssRule(
        selector: '[inline]',
        properties: properties,
        element: element,
      ));
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
      final value = decl.expression?.toString().trim();
      if (value == null || value.isEmpty) continue;
      props[name.toLowerCase()] = value;
    }
    return props;
  }

  /// Returns the resolved [CssStyle] for a DOM element in a given chapter.
  CssStyle resolveStyle(String chapterPath, dom.Element element) {
    final rules = chapterStyles[chapterPath];
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
      fontFamily: props['font-family']?.replaceAll(RegExp(r"['\u201C\u201D]"), '').trim(),
      lineHeight: _parseLineHeight(props['line-height']),
      letterSpacing: _parseLength(props['letter-spacing']),
      wordSpacing: _parseLength(props['word-spacing']),
      textTransform: props['text-transform'],
      whiteSpace: props['white-space'],
    );
  }

  static double? _parseFontSize(String? value) {
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

    final hexMatch = RegExp(r'^#([0-9a-f]{3,8})$', caseSensitive: false).firstMatch(v);
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

    final rgbMatch = RegExp(r'rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*(?:,\s*([\d.]+))?\s*\)').firstMatch(v);
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
    final loaded = <String>[];
    for (final entry in fontFaces.entries) {
      final info = entry.value;
      if (info.bytes == null || info.bytes!.isEmpty) continue;
      try {
        final fontLoader = FontLoader(info.family)
          ..addFont(Future.value(ByteData.view(info.bytes!.buffer)));
        await fontLoader.load();
        loaded.add(info.family);
      } catch (_) {}
    }
    return loaded;
  }

  static double? _parseLineHeight(String? value) {
    if (value == null) return null;
    final v = value.trim().toLowerCase();
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
