import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:burrow/models/style_run.dart';
import 'package:burrow/services/document_parser.dart';

void main() {
  group('chapterizeTxt', () {
    test('splits on explicit chapter headings', () {
      final text = '''Chapter 1: The Beginning
Once upon a time...

Chapter 2: The Middle
Something happened...

Chapter 3: The End
It was over.''';

      final chapters = DocumentParser.chapterizeTxt(text);
      expect(chapters.length, 3);
      expect(chapters[0].title, 'Chapter 1: The Beginning');
      expect(chapters[1].title, 'Chapter 2: The Middle');
      expect(chapters[2].title, 'Chapter 3: The End');
    });

    test('splits on blank-line runs (3+ blank lines)', () {
      final text = '''First section with some text here.

Second section with more text.

Third section with even more text.''';

      final chapters = DocumentParser.chapterizeTxt(text);
      // No heading and no 3+ blank lines, so single chapter.
      expect(chapters.length, 1);
    });

    test('splits on blank-line runs with actual 3+ blank lines', () {
      final text = '''First section.



Second section.



Third section.''';

      final chapters = DocumentParser.chapterizeTxt(text);
      expect(chapters.length, 3);
      expect(chapters[0].title, '');
      expect(chapters[1].title, '');
      expect(chapters[2].title, '');
    });

    test('splits on PART headings', () {
      final text = '''PART I
The beginning of the story.

PART II
The middle of the story.

PART III
The end of the story.''';

      final chapters = DocumentParser.chapterizeTxt(text);
      expect(chapters.length, 3);
      expect(chapters[0].title, 'PART I');
      expect(chapters[1].title, 'PART II');
      expect(chapters[2].title, 'PART III');
    });

    test('case insensitive heading matching', () {
      final text = '''chapter 1 lowercase
Some text.

CHAPTER 2 UPPERCASE
More text.''';

      final chapters = DocumentParser.chapterizeTxt(text);
      expect(chapters.length, 2);
      expect(chapters[0].title, 'chapter 1 lowercase');
      expect(chapters[1].title, 'CHAPTER 2 UPPERCASE');
    });

    test('short text returns single chapter', () {
      final text = 'Just a short paragraph.';
      final chapters = DocumentParser.chapterizeTxt(text);
      expect(chapters.length, 1);
      expect(chapters[0].title, '');
      expect(chapters[0].body, text);
    });

    test('empty text returns single empty chapter', () {
      final chapters = DocumentParser.chapterizeTxt('');
      expect(chapters.length, 1);
      expect(chapters[0].body, '');
    });

    test('heading in middle of line does not split', () {
      final text = '''This chapter talks about Chapter 5 of the other book.
More text here.''';

      final chapters = DocumentParser.chapterizeTxt(text);
      // "Chapter 5" is not at line start, so no split.
      expect(chapters.length, 1);
    });

    test('combined headings and blank-line runs', () {
      final text = '''Chapter 1
First chapter text.



Chapter 2
Second chapter text.''';

      final chapters = DocumentParser.chapterizeTxt(text);
      expect(chapters.length, 2);
      expect(chapters[0].title, 'Chapter 1');
      expect(chapters[1].title, 'Chapter 2');
    });

    test('strips empty chunks from splits', () {
      final text = '''Chapter 1
Text here.

Chapter 2
Text there.''';

      final chapters = DocumentParser.chapterizeTxt(text);
      // Should not have empty chapters between.
      for (final c in chapters) {
        expect(c.body.trim().isNotEmpty, isTrue);
      }
    });

    test('Ch. abbreviation works', () {
      final text = '''Ch. 1 First
Some text.

Ch. 2 Second
More text.''';

      final chapters = DocumentParser.chapterizeTxt(text);
      expect(chapters.length, 2);
      expect(chapters[0].title, 'Ch. 1 First');
      expect(chapters[1].title, 'Ch. 2 Second');
    });
  });

  group('htmlToText', () {
    test('strips HTML tags', () {
      expect(DocumentParser.htmlToText('<p>Hello</p>'), 'Hello');
    });

    test('converts block tags to newlines', () {
      expect(
        DocumentParser.htmlToText('<p>One</p><p>Two</p>'),
        'One\n\nTwo',
      );
    });

    test('decodes HTML entities', () {
      expect(DocumentParser.htmlToText('a &amp; b'), 'a & b');
      expect(DocumentParser.htmlToText('a &lt; b'), 'a < b');
      expect(DocumentParser.htmlToText('a &gt; b'), 'a > b');
    });

    test('collapses whitespace', () {
      expect(DocumentParser.htmlToText('  hello   world  '), 'hello world');
    });

    test('handles br tags', () {
      expect(DocumentParser.htmlToText('line1<br>line2'), 'line1\nline2');
    });

    test('strips comments', () {
      expect(
        DocumentParser.htmlToText('before<!-- comment -->after'),
        'beforeafter',
      );
    });

    test('drops head content so the document title is not read as text', () {
      expect(
        DocumentParser.htmlToText(
          '<html><head><title>Cover</title></head>'
          '<body><p>Real text</p></body></html>',
        ),
        'Real text',
      );
    });

    test('drops style and script bodies rather than reading them aloud', () {
      expect(
        DocumentParser.htmlToText(
          '<body><style>p { color: red; }</style>'
          '<script>var x = 1;</script><p>Real text</p></body>',
        ),
        'Real text',
      );
    });

    test('leaves markup alone when the element is never closed', () {
      // No </style>: better to show stray CSS than to swallow the chapter.
      expect(
        DocumentParser.htmlToText('<p>kept</p><style>p{color:red}'),
        contains('kept'),
      );
    });
  });

  group('htmlToRichText', () {
    test('plain text matches htmlToText output exactly', () {
      const samples = [
        '<p>Hello <em>world</em></p>',
        '<h1>Title</h1><p>Para one.</p><p>Para two.</p>',
        'line1<br>line2<br/>line3',
        '<blockquote>quoted words</blockquote><p>after</p>',
        '<p>a &amp; b &mdash; c</p>',
        '<div>  spaced   out  </div>',
      ];
      for (final html in samples) {
        final (text, _) = DocumentParser.htmlToRichText(html);
        expect(text, DocumentParser.htmlToText(html), reason: html);
      }
    });

    test('bold tags produce a bold run with correct offsets', () {
      final (text, runs) =
          DocumentParser.htmlToRichText('<p>some <b>bold</b> text</p>');
      expect(text, 'some bold text');
      expect(runs.length, 1);
      expect(runs[0].bold, isTrue);
      expect(text.substring(runs[0].start, runs[0].end), 'bold');
    });

    test('strong and em map to bold and italic', () {
      final (text, runs) = DocumentParser.htmlToRichText(
        '<p><strong>strong</strong> and <em>soft</em></p>',
      );
      expect(text, 'strong and soft');
      expect(runs.length, 2);
      expect(runs[0].bold, isTrue);
      expect(text.substring(runs[0].start, runs[0].end), 'strong');
      expect(runs[1].italic, isTrue);
      expect(text.substring(runs[1].start, runs[1].end), 'soft');
    });

    test('nested bold+italic produces both flags on one run', () {
      final (text, runs) = DocumentParser.htmlToRichText(
        '<p><b>bold <i>both</i> tail</b></p>',
      );
      expect(text, 'bold both tail');
      // Spaces around "both" sit inside <b>, so they stay bold-only.
      expect(runs.length, 3);
      expect(text.substring(runs[0].start, runs[0].end), 'bold ');
      expect(runs[0].bold && !runs[0].italic, isTrue);
      expect(text.substring(runs[1].start, runs[1].end), 'both');
      expect(runs[1].bold && runs[1].italic, isTrue);
      expect(text.substring(runs[2].start, runs[2].end), ' tail');
      expect(runs[2].bold && !runs[2].italic, isTrue);
    });

    test('blockquote produces quote run and paragraph break', () {
      final (text, runs) = DocumentParser.htmlToRichText(
        '<p>before</p><blockquote>quoted</blockquote><p>after</p>',
      );
      expect(text, contains('quoted'));
      final quotes = runs.where((r) => r.quote).toList();
      expect(quotes.length, 1);
      expect(text.substring(quotes[0].start, quotes[0].end), 'quoted');
      expect(text.indexOf('before'), lessThan(quotes[0].start));
      expect(text.indexOf('after'), greaterThan(quotes[0].end));
    });

    test('entities inside emphasis stay within the run', () {
      final (text, runs) =
          DocumentParser.htmlToRichText('<p><b>a &amp; b</b></p>');
      expect(text, 'a & b');
      expect(runs.length, 1);
      expect(runs[0].bold, isTrue);
      expect(text.substring(runs[0].start, runs[0].end), 'a & b');
    });

    test('adjacent same-style segments merge into one run', () {
      final (_, runs) = DocumentParser.htmlToRichText(
        '<p><b>one</b> <b>two</b> <span>plain</span></p>',
      );
      // The space between the two bold segments carries no style, so runs
      // must not merge across it.
      final boldRuns = runs.where((r) => r.bold).toList();
      expect(boldRuns.length, 2);
    });

    test('unclosed tags do not crash or over-extend past content', () {
      final (text, runs) =
          DocumentParser.htmlToRichText('<p><b>never closed');
      expect(text, 'never closed');
      expect(runs.single.end, text.length);
    });

    test('plain paragraphs produce no runs', () {
      final (text, runs) =
          DocumentParser.htmlToRichText('<p>just plain prose here</p>');
      expect(text, 'just plain prose here');
      expect(runs, isEmpty);
    });
  });

  group('buildStyledSpans', () {
    const base = TextStyle(fontSize: 16);
    final text = 'plain bold plain italic end';

    test('segments split at run boundaries with correct styles', () {
      final runs = [
        const StyleRun(6, 10, bold: true),
        const StyleRun(17, 23, italic: true),
      ];
      final spans = buildStyledSpans(text, runs, base, 0, text.length);
      expect(spans.length, 5); // plain|bold|plain|italic|end
      expect((spans[0]).text, 'plain ');
      expect((spans[0]).style, isNull); // inherits parent style
      expect((spans[1]).text, 'bold');
      expect((spans[1]).style!.fontWeight, FontWeight.w700);
      expect((spans[3]).text, 'italic');
      expect((spans[3]).style!.fontStyle, FontStyle.italic);
      expect(spans.map((s) => s.text).join(), text);
    });

    test('clips to requested range without touching outside runs', () {
      final runs = [const StyleRun(6, 10, bold: true)];
      final spans = buildStyledSpans(text, runs, base, 7, 9);
      expect(spans.length, 1);
      expect(spans.single.text, 'ol');
      expect(spans.single.style!.fontWeight, FontWeight.w700);
    });

    test('quote runs take the supplied muted color', () {
      final runs = [const StyleRun(6, 10, quote: true)];
      final spans = buildStyledSpans(
        text,
        runs,
        base,
        0,
        text.length,
        quoteColor: Colors.grey,
      );
      expect(spans[1].style!.color, Colors.grey);
      expect(spans[1].style!.fontStyle, FontStyle.italic);
    });
  });

  group('parseHtmlDocument anchors', () {
    test('resolves an id to the offset of the following text', () {
      final (body, _, anchors, _) =
          DocumentParser.parseHtmlDocument('<p>Intro</p><h2 id="two">Two</h2>');
      expect(anchors['two'], isNotNull);
      expect(body.substring(anchors['two']!), startsWith('Two'));
    });

    test('anchor offset skips the collapsed whitespace before it', () {
      final (body, _, anchors, _) = DocumentParser.parseHtmlDocument(
        '<p>Intro</p>\n\n   <h2 id="two">   Two</h2>',
      );
      // The break belongs to the previous section, not the anchored one.
      expect(body[anchors['two']!], 'T');
    });

    test('supports legacy <a name> and single quotes', () {
      final (body, _, anchors, _) = DocumentParser.parseHtmlDocument(
        "<p>One</p><a name='two'>Two</a><p id='three'>Three</p>",
      );
      expect(body.substring(anchors['two']!), startsWith('Two'));
      expect(body.substring(anchors['three']!), startsWith('Three'));
    });

    test('does not mistake data-id for an id', () {
      final (_, _, _, anchors) = DocumentParser.parseHtmlDocument(
        '<p data-id="nope">One</p>',
      );
      expect(anchors, isEmpty);
    });

    test('first declaration wins for duplicate ids', () {
      final (body, _, anchors, _) = DocumentParser.parseHtmlDocument(
        '<p id="dup">First</p><p id="dup">Second</p>',
      );
      expect(body.substring(anchors['dup']!), startsWith('First'));
    });
  });

  group('splitByAnchors', () {
    test('splits one document into a chapter per anchor', () {
      final (body, runs, anchors, _) = DocumentParser.parseHtmlDocument(
        '<h2 id="a">One</h2><p>alpha</p>'
        '<h2 id="b">Two</h2><p>beta</p>'
        '<h2 id="c">Three</h2><p>gamma</p>',
      );
      final chapters = DocumentParser.splitByAnchors(body, runs, anchors, const [
        TocEntry('f', 'a', 'One'),
        TocEntry('f', 'b', 'Two'),
        TocEntry('f', 'c', 'Three'),
      ]);

      expect(chapters.map((c) => c.title), ['One', 'Two', 'Three']);
      expect(chapters[0].body, contains('alpha'));
      expect(chapters[0].body, isNot(contains('beta')));
      expect(chapters[1].body, contains('beta'));
      expect(chapters[2].body, contains('gamma'));
      // Splitting must not lose or duplicate a single character.
      expect(chapters.map((c) => c.body).join(), body);
    });

    test('rebases style runs into the slice they belong to', () {
      final (body, runs, anchors, _) = DocumentParser.parseHtmlDocument(
        '<h2 id="a">One</h2><p>plain <em>emph</em></p>'
        '<h2 id="b">Two</h2><p><strong>bold</strong> tail</p>',
      );
      final chapters = DocumentParser.splitByAnchors(body, runs, anchors, const [
        TocEntry('f', 'a', 'One'),
        TocEntry('f', 'b', 'Two'),
      ]);

      expect(chapters.length, 2);
      final first = chapters[0];
      final second = chapters[1];
      expect(first.runs.length, 1);
      expect(
        first.body.substring(first.runs.single.start, first.runs.single.end),
        'emph',
      );
      expect(first.runs.single.italic, isTrue);
      expect(second.runs.length, 1);
      expect(
        second.body.substring(second.runs.single.start, second.runs.single.end),
        'bold',
      );
      expect(second.runs.single.bold, isTrue);
    });

    test('text before the first anchor becomes an untitled chapter', () {
      final (body, runs, anchors, _) = DocumentParser.parseHtmlDocument(
        '<p>front matter</p><h2 id="b">Two</h2><p>beta</p>',
      );
      final chapters = DocumentParser.splitByAnchors(
        body,
        runs,
        anchors,
        const [TocEntry('f', 'b', 'Two')],
      );

      expect(chapters.length, 2);
      expect(chapters[0].title, isEmpty);
      expect(chapters[0].body, contains('front matter'));
      expect(chapters[1].title, 'Two');
    });

    test('keeps the document whole when no entry resolves', () {
      final (body, runs, anchors, _) =
          DocumentParser.parseHtmlDocument('<p>only text</p>');
      final chapters = DocumentParser.splitByAnchors(
        body,
        runs,
        anchors,
        const [TocEntry('f', 'missing', 'Title')],
      );

      expect(chapters.length, 1);
      expect(chapters.single.title, 'Title');
      expect(chapters.single.body, body);
    });

    test('ignores entries whose fragment is absent from the document', () {
      final (body, runs, anchors, _) = DocumentParser.parseHtmlDocument(
        '<h2 id="a">One</h2><p>alpha</p><h2 id="b">Two</h2><p>beta</p>',
      );
      final chapters = DocumentParser.splitByAnchors(body, runs, anchors, const [
        TocEntry('f', 'a', 'One'),
        TocEntry('f', 'ghost', 'Ghost'),
        TocEntry('f', 'b', 'Two'),
      ]);

      expect(chapters.map((c) => c.title), ['One', 'Two']);
    });

    test('a fragmentless entry titles the whole document', () {
      final (body, runs, anchors, _) = DocumentParser.parseHtmlDocument(
        '<h2 id="a">One</h2><p>alpha</p>',
      );
      final chapters = DocumentParser.splitByAnchors(
        body,
        runs,
        anchors,
        const [TocEntry('f', null, 'Whole')],
      );

      expect(chapters.length, 1);
      expect(chapters.single.title, 'Whole');
      expect(chapters.single.body, body);
    });
  });

  group('parseEpubBytes', () {
    test('a document holding several chapters yields one chapter each', () {
      final doc = DocumentParser.parseEpubBytes(
        _buildEpub(
          opf: _opf(
            items: '<item id="ncx" href="toc.ncx" '
                'media-type="application/x-dtbncx+xml"/>'
                '<item id="book" href="book.xhtml" '
                'media-type="application/xhtml+xml"/>',
            spine: '<itemref idref="book"/>',
            spineToc: 'ncx',
          ),
          ncx: _ncx(const [
            ('Chapter One', 'book.xhtml#ch1'),
            ('Chapter Two', 'book.xhtml#ch2'),
            ('Chapter Three', 'book.xhtml#ch3'),
          ]),
          docs: {
            'book.xhtml': _xhtml(
              '<h2 id="ch1">Chapter One</h2><p>Alpha body.</p>'
              '<h2 id="ch2">Chapter Two</h2><p>Beta body.</p>'
              '<h2 id="ch3">Chapter Three</h2><p>Gamma body.</p>',
            ),
          },
        ),
      );

      expect(doc.title, 'Anchored Book');
      expect(doc.author, 'A. Writer');
      // Before the fix this collapsed to a single chapter titled "Chapter One"
      // holding all three sections' text.
      expect(doc.chapters.length, 3);
      expect(
        doc.chapters.map((c) => c.title),
        ['Chapter One', 'Chapter Two', 'Chapter Three'],
      );
      expect(doc.chapters[0].body, contains('Alpha'));
      expect(doc.chapters[0].body, isNot(contains('Beta')));
      expect(doc.chapters[1].body, contains('Beta'));
      expect(doc.chapters[2].body, contains('Gamma'));
    });

    test('one chapter per file still works', () {
      final doc = DocumentParser.parseEpubBytes(
        _buildEpub(
          opf: _opf(
            items: '<item id="ncx" href="toc.ncx" '
                'media-type="application/x-dtbncx+xml"/>'
                '<item id="c1" href="c1.xhtml" '
                'media-type="application/xhtml+xml"/>'
                '<item id="c2" href="c2.xhtml" '
                'media-type="application/xhtml+xml"/>',
            spine: '<itemref idref="c1"/><itemref idref="c2"/>',
            spineToc: 'ncx',
          ),
          ncx: _ncx(const [
            ('First', 'c1.xhtml'),
            ('Second', 'c2.xhtml'),
          ]),
          docs: {
            'c1.xhtml': _xhtml('<p>alpha</p>'),
            'c2.xhtml': _xhtml('<p>beta</p>'),
          },
        ),
      );

      expect(doc.chapters.map((c) => c.title), ['First', 'Second']);
      expect(doc.chapters[0].body, 'alpha');
      expect(doc.chapters[1].body, 'beta');
    });

    test('nested navPoints keep reading order', () {
      final doc = DocumentParser.parseEpubBytes(
        _buildEpub(
          opf: _opf(
            items: '<item id="ncx" href="toc.ncx" '
                'media-type="application/x-dtbncx+xml"/>'
                '<item id="book" href="book.xhtml" '
                'media-type="application/xhtml+xml"/>',
            spine: '<itemref idref="book"/>',
            spineToc: 'ncx',
          ),
          ncx: '''
<?xml version="1.0" encoding="utf-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><navMap>
  <navPoint id="p1"><navLabel><text>Part One</text></navLabel>
    <content src="book.xhtml#p1"/>
    <navPoint id="s1"><navLabel><text>Section A</text></navLabel>
      <content src="book.xhtml#s1"/></navPoint>
  </navPoint>
</navMap></ncx>''',
          docs: {
            'book.xhtml': _xhtml(
              '<h1 id="p1">Part One</h1><p>intro</p>'
              '<h2 id="s1">Section A</h2><p>detail</p>',
            ),
          },
        ),
      );

      expect(doc.chapters.map((c) => c.title), ['Part One', 'Section A']);
      expect(doc.chapters[0].body, contains('intro'));
      expect(doc.chapters[1].body, contains('detail'));
    });

    test('EPUB3 uses the manifest item flagged properties="nav"', () {
      // A decoy document sits earlier in the manifest and carries a stray
      // link; only the flagged nav document should supply titles.
      final doc = DocumentParser.parseEpubBytes(
        _buildEpub(
          opf: _opf(
            items: '<item id="decoy" href="decoy.xhtml" '
                'media-type="application/xhtml+xml"/>'
                '<item id="nav" href="nav.xhtml" properties="nav" '
                'media-type="application/xhtml+xml"/>'
                '<item id="book" href="book.xhtml" '
                'media-type="application/xhtml+xml"/>',
            spine: '<itemref idref="decoy"/><itemref idref="book"/>',
          ),
          nav: _xhtml(
            '<nav epub:type="toc"><ol>'
            '<li><a href="book.xhtml#ch1">Real One</a></li>'
            '<li><a href="book.xhtml#ch2">Real Two</a></li>'
            '</ol></nav>',
          ),
          docs: {
            'decoy.xhtml':
                _xhtml('<p>front</p><a href="book.xhtml">Bogus Title</a>'),
            'book.xhtml': _xhtml(
              '<h2 id="ch1">Real One</h2><p>alpha</p>'
              '<h2 id="ch2">Real Two</h2><p>beta</p>',
            ),
          },
        ),
      );

      final titles = doc.chapters.map((c) => c.title).toList();
      expect(titles, contains('Real One'));
      expect(titles, contains('Real Two'));
      expect(titles, isNot(contains('Bogus Title')));
    });

    test('falls back to the filename when metadata has no title', () {
      final doc = DocumentParser.parseEpubBytes(
        _buildEpub(
          opf: '''<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0"
         unique-identifier="bookid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"/>
  <manifest><item id="book" href="book.xhtml"
        media-type="application/xhtml+xml"/></manifest>
  <spine><itemref idref="book"/></spine>
</package>''',
          docs: {'book.xhtml': _xhtml('<p>text</p>')},
        ),
        fallbackTitle: 'From Filename',
      );

      expect(doc.title, 'From Filename');
      expect(doc.chapters.single.title, isEmpty);
    });

    test('strips HTML tags from description', () {
      final doc = DocumentParser.parseEpubBytes(
        _buildEpub(
          opf: '''<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0"
         unique-identifier="bookid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>Titled Book</dc:title>
    <dc:creator>A. Writer</dc:creator>
    <dc:description><p>A <b>bold</b> and <i>italic</i> story.</p></dc:description>
  </metadata>
  <manifest><item id="book" href="book.xhtml"
        media-type="application/xhtml+xml"/></manifest>
  <spine><itemref idref="book"/></spine>
</package>''',
          docs: {'book.xhtml': _xhtml('<p>content</p>')},
        ),
      );

      expect(doc.description, 'A bold and italic story.');
      expect(doc.description, isNot(contains('<p>')));
      expect(doc.description, isNot(contains('<b>')));
    });

    test('rejects a file that is not a zip', () {
      expect(
        () => DocumentParser.parseEpubBytes(
          Uint8List.fromList('not a zip'.codeUnits),
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });
}

// -----------------------------------------------------------------------------
// Synthetic EPUB builders.
// -----------------------------------------------------------------------------

Uint8List _buildEpub({
  required String opf,
  Map<String, String> docs = const {},
  String? ncx,
  String? nav,
}) {
  final archive = Archive()
    ..addFile(ArchiveFile.string('mimetype', 'application/epub+zip'))
    ..addFile(ArchiveFile.string('META-INF/container.xml', '''
<?xml version="1.0" encoding="utf-8"?>
<container version="1.0"
    xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf"
        media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>'''))
    ..addFile(ArchiveFile.string('OEBPS/content.opf', opf));
  if (ncx != null) {
    archive.addFile(ArchiveFile.string('OEBPS/toc.ncx', ncx));
  }
  if (nav != null) {
    archive.addFile(ArchiveFile.string('OEBPS/nav.xhtml', nav));
  }
  docs.forEach((name, content) {
    archive.addFile(ArchiveFile.string('OEBPS/$name', content));
  });
  return ZipEncoder().encodeBytes(archive);
}

String _opf({
  required String items,
  required String spine,
  String? spineToc,
}) =>
    '''<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0"
         unique-identifier="bookid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>Anchored Book</dc:title>
    <dc:creator>A. Writer</dc:creator>
  </metadata>
  <manifest>$items</manifest>
  <spine${spineToc == null ? '' : ' toc="$spineToc"'}>$spine</spine>
</package>''';

String _ncx(List<(String, String)> points) {
  final buf = StringBuffer('''<?xml version="1.0" encoding="utf-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><navMap>''');
  for (var i = 0; i < points.length; i++) {
    final (label, src) = points[i];
    buf.write('<navPoint id="n$i" playOrder="${i + 1}">'
        '<navLabel><text>$label</text></navLabel>'
        '<content src="$src"/></navPoint>');
  }
  buf.write('</navMap></ncx>');
  return buf.toString();
}

String _xhtml(String body) => '''<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"
      xmlns:epub="http://www.idpf.org/2007/ops">
  <head><title>doc</title></head>
  <body>$body</body>
</html>''';
