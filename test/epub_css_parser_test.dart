import 'package:burrow/models/css_style.dart';
import 'package:burrow/services/epub_css_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('propsToCssStyle lengths', () {
    test('percent widths are preserved symbolically', () {
      final css = EpubCssParser.propsToCssStyle({
        'width': '100%',
        'max-width': '80%',
      });
      expect(css.width, const CssLength.percent(100));
      expect(css.maxWidth, const CssLength.percent(80));
      expect(css.width!.resolve(370), 370);
      expect(css.maxWidth!.resolve(370), closeTo(296, 0.01));
    });

    test('absolute lengths resolve to pixels', () {
      final css = EpubCssParser.propsToCssStyle({
        'width': '120px',
        'max-height': '2em',
        'height': '10pt',
      });
      expect(css.width, const CssLength.px(120));
      expect(css.maxHeight, const CssLength.px(32));
      expect(css.height!.value, closeTo(13.33, 0.01));
    });

    test('auto and none are treated as unset', () {
      final css = EpubCssParser.propsToCssStyle({
        'width': 'auto',
        'max-height': 'none',
      });
      expect(css.width, isNull);
      expect(css.maxHeight, isNull);
    });

    test('percentage font-size is relative to the 16px default', () {
      final css = EpubCssParser.propsToCssStyle({'font-size': '150%'});
      expect(css.fontSize, closeTo(24, 0.01));
    });

    test('percentage line-height becomes a unitless multiplier', () {
      final css = EpubCssParser.propsToCssStyle({'line-height': '150%'});
      expect(css.lineHeight, closeTo(1.5, 0.01));
    });
  });
}
