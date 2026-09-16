import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:burrow/models/style_run.dart';
import 'package:burrow/services/document_parser.dart';

// The reader renders Chapter.title as a page heading, so a body that opens
// with the same heading (TOC "Chapter One" + in-body "CHAPTER ONE") shows it
// twice. The parser must drop the redundant opening line.
void main() {
  group('duplicate chapter headings', () {
    test('splitByAnchors strips a leading line repeating the title', () {
      final chapters = DocumentParser.splitByAnchors(
        'CHAPTER ONE\n\nSome text here',
        const [],
        const {},
        const [TocEntry('doc', null, 'Chapter One')],
      );

      expect(chapters.single.title, 'Chapter One');
      expect(chapters.single.body, 'Some text here');
    });

    test('splitByAnchors keeps a leading line that differs from the title', () {
      final chapters = DocumentParser.splitByAnchors(
        'Foreword\n\nSome text here',
        const [],
        const {},
        const [TocEntry('doc', null, 'Chapter One')],
      );

      expect(chapters.single.body, 'Foreword\n\nSome text here');
    });

    test('splitByAnchors rebases runs and drops heading-only runs', () {
      final chapters = DocumentParser.splitByAnchors(
        'CHAPTER ONE\n\nSome text here',
        const [
          StyleRun(0, 11, bold: true), // inside the stripped heading
          StyleRun(13, 17, bold: true), // "Some"
        ],
        const {},
        const [TocEntry('doc', null, 'Chapter One')],
      );

      final runs = chapters.single.runs;
      expect(runs.length, 1);
      expect(runs.single.start, 0);
      expect(chapters.single.body.substring(runs.single.start, runs.single.end),
          'Some');
    });

    test('a chapter holding only its title is left alone', () {
      final chapters = DocumentParser.splitByAnchors(
        'CHAPTER ONE',
        const [],
        const {},
        const [TocEntry('doc', null, 'Chapter One')],
      );

      expect(chapters.single.body, 'CHAPTER ONE');
    });

    test('TXT chapters drop the heading line from the body', () {
      final chapters = DocumentParser.chapterizeTxt(
        'Chapter 1\n\nBody text here',
      );

      expect(chapters.single.title, 'Chapter 1');
      expect(chapters.single.body, 'Body text here');
    });

    test('end to end: EPUB nav title wins over the in-body heading', () {
      const xhtml = '''<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
  <head><title>doc</title></head>
  <body><h2 id="ch1">CHAPTER ONE</h2><p>Body text here</p></body>
</html>''';
      const ncx = '''<?xml version="1.0" encoding="utf-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><navMap>
  <navPoint id="n0" playOrder="1"><navLabel><text>Chapter One</text></navLabel>
    <content src="book.xhtml#ch1"/></navPoint>
</navMap></ncx>''';
      const opf = '''<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0"
         unique-identifier="bookid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>Titled Book</dc:title>
    <dc:creator>A. Writer</dc:creator>
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="book" href="book.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine toc="ncx"><itemref idref="book"/></spine>
</package>''';
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
        ..addFile(ArchiveFile.string('OEBPS/toc.ncx', ncx))
        ..addFile(ArchiveFile.string('OEBPS/book.xhtml', xhtml));
      final doc = DocumentParser.parseEpubBytes(
        ZipEncoder().encodeBytes(archive),
      );

      expect(doc.chapters.single.title, 'Chapter One');
      expect(doc.chapters.single.body, isNot(startsWith('CHAPTER')));
      expect(doc.chapters.single.body, contains('Body text here'));
    });
  });
}
