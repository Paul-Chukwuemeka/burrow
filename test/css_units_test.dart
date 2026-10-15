import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:burrow/models/document.dart';
import 'package:burrow/models/style_run.dart';
import 'package:burrow/services/epub/rust_epub_engine.dart';
import 'package:burrow/src/rust/frb_generated.dart';

// Regression: csslib's expression span drops the unit (`70%` -> `70`,
// `1em` -> `1`), which once resolved `font-size:1em` to 1px
// (body text as hairlines) and `font-size:70%` to 70px (giant headings).
//
// The retired Dart parser used to serve these assertions; they now run
// through the Rust engine's own CSS cascade over a generated EPUB.
void main() {
  setUpAll(() async {
    await RustLib.init();
  });

  group('CSS relative units keep their units', () {
    test('relative font-size units resolve against the 16px reference',
        () async {
      final doc = await _parseWithCss(
        'small{font-size:70%} span.big{font-size:280%} p{font-size:1em}',
        '<p>A<small>BC</small></p>'
            '<p><span class="big">D</span>ef</p>',
      );

      double? sizeOf(String text) {
        for (final ch in doc.chapters) {
          final at = ch.body.indexOf(text);
          if (at < 0) continue;
          // Innermost (shortest) run covering the match: the cascade nests
          // element styles (e.g. `p` under `small`), so the first covering
          // run is the outer element, not the winning declaration.
          StyleRun? best;
          for (final r in ch.runs) {
            if (r.start <= at && at < r.end) {
              if (best == null ||
                  (r.end - r.start) < (best.end - best.start)) {
                best = r;
              }
            }
          }
          final size = best?.css?.fontSize;
          if (size != null) return size;
        }
        return null;
      }

      // 70% of 16px reference = 11.2px, not 70px.
      expect(sizeOf('BC'), closeTo(11.2, 0.001));
      // 280% of 16px reference = 44.8px, not 280px.
      expect(sizeOf('D'), closeTo(44.8, 0.001));
      // 1em of 16px reference = 16px, not 1px.
      expect(sizeOf('A'), closeTo(16.0, 0.001));
    });

    test('relative line-height stays a multiplier', () async {
      final doc = await _parseWithCss(
        'p{line-height:1.3em}',
        '<p>some body text here</p>',
      );

      final chapter = doc.chapters.single;
      final run = chapter.runs.firstWhere(
        (r) => chapter.body.substring(r.start, r.end).isNotEmpty,
      );
      // 1.3em line-height means 1.3x, not 20.8x.
      expect(run.css?.lineHeight, closeTo(1.3, 0.001));
    });

    test('pixel line-height resolves against the 16px reference', () async {
      final doc = await _parseWithCss(
        'p{line-height:24px}',
        '<p>some body text here</p>',
      );

      final chapter = doc.chapters.single;
      final run = chapter.runs.firstWhere(
        (r) => chapter.body.substring(r.start, r.end).isNotEmpty,
      );
      // 24px at the 16px reference = 1.5x, not 24x.
      expect(run.css?.lineHeight, closeTo(1.5, 0.001));
    });
  });
}

Future<ParsedDocument> _parseWithCss(String css, String bodyHtml) async {
  final dir = await Directory.systemTemp.createTemp('burrow_css_units');
  try {
    final file = File('${dir.path}/units.epub');
    await file.writeAsBytes(_buildEpubWithCss(bodyHtml, css));
    final doc = await const RustEpubEngine().parse(file.path);
    await dir.delete(recursive: true);
    return doc;
  } catch (_) {
    await dir.delete(recursive: true);
    rethrow;
  }
}

Uint8List _buildEpubWithCss(String bodyHtml, String css) {
  const opf = '''<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0"
         unique-identifier="bookid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>Units Book</dc:title>
    <dc:creator>U. Nits</dc:creator>
    <dc:identifier id="bookid">units</dc:identifier>
  </metadata>
  <manifest>
    <item id="book" href="book.xhtml" media-type="application/xhtml+xml"/>
    <item id="style" href="styles/stylesheet.css" media-type="text/css"/>
  </manifest>
  <spine><itemref idref="book"/></spine>
</package>''';
  final xhtml = '''<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
  <head><title>doc</title></head>
  <body>$bodyHtml</body>
</html>''';
  final archive = Archive()
    ..addFile(ArchiveFile.string('mimetype', 'application/epub+zip'))
    ..addFile(
      ArchiveFile.string('META-INF/container.xml', '''
<?xml version="1.0" encoding="utf-8"?>
<container version="1.0"
    xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf"
        media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>'''),
    )
    ..addFile(ArchiveFile.string('OEBPS/content.opf', opf))
    ..addFile(ArchiveFile.string('OEBPS/book.xhtml', xhtml))
    ..addFile(ArchiveFile.string('OEBPS/styles/stylesheet.css', css));
  return ZipEncoder().encodeBytes(archive);
}
