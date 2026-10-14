// Dart adapter tests for the DTO -> domain mapper (Task 7).
//
// The mapper is the last hop of the Phase-A contract (spec D4): the offsets the
// Rust engine emits are Dart UTF-16 code units, so `String.substring` on the
// mapped chapter body must reproduce exactly the text a run covers — including
// when a non-BMP character precedes or sits inside the run (Review Focus #1).
// Percent box lengths must arrive as symbolic `CssLength.percent`, never
// resolved. Image bytes stay empty until Task 8 hydrates them.
import 'dart:ui';

import 'package:burrow/services/epub/epub_dto_mapper.dart';
import 'package:burrow/src/rust/epub/model.dart';
import 'package:burrow/src/rust/epub/project.dart';
import 'package:flutter_test/flutter_test.dart';

ChapterDto _chapter({required String body, List<StyleRunDto> runs = const []}) {
  return ChapterDto(
    title: '',
    body: body,
    runs: runs,
    images: const [],
    blocks: const [],
  );
}

void main() {
  test('run offsets index the body as a Dart substring', () {
    // Two UTF-16 units for the emoji; the run covers it and the following text.
    final dto = _chapter(
      body: 'pre \u{1F600} run post',
      runs: const [
        StyleRunDto(start: 4, end: 10, bold: false, italic: true, quote: false),
      ],
    );
    final chapter = EpubDtoMapper.toChapter(dto);
    expect(
      chapter.body.substring(chapter.runs.first.start, chapter.runs.first.end),
      '\u{1F600} run',
    );
    expect(chapter.runs.first.italic, isTrue);
  });

  test('image maps with empty bytes and keeps its sizing reference', () {
    final dto = ChapterDto(
      title: '',
      body: 'x\u{FFFC}',
      runs: const [],
      images: const [
        ImageRunDto(
          offset: 1,
          intrinsicW: 8,
          intrinsicH: 4,
          alt: 'tiny',
          fullWidth: false,
          sourceKey: 'oebps/images/pic.png',
          imgSrc: 'Images/pic.png',
          imgClass: 'wide',
          elementId: 'pic',
          htmlW: 8,
          htmlH: 4,
        ),
      ],
      blocks: const [],
    );
    final chapter = EpubDtoMapper.toChapter(dto);
    final image = chapter.images.single;
    expect(image.bytes, isEmpty);
    expect(image.offset, 1);
    expect(image.sourceKey, 'oebps/images/pic.png');
    expect(image.intrinsicWidth, 8);
    expect(image.intrinsicHeight, 4);
    expect(image.htmlWidth, 8);
    expect(image.htmlHeight, 4);
  });

  test('percent box lengths stay symbolic and colour maps to a Color', () {
    const dto = CssStyleDto(
      color: 0xFF336699,
      fontSize: 14,
      maxWidth: CssLengthDto(value: 100, isPercent: true),
      width: CssLengthDto(value: 12, isPercent: false),
    );
    final css = EpubDtoMapper.cssStyleFrom(dto)!;
    expect(css.color, const Color(0xFF336699));
    expect(css.fontSize, 14);
    expect(css.maxWidth!.isPercent, isTrue);
    expect(css.maxWidth!.value, 100);
    expect(css.width!.isPercent, isFalse);
    expect(css.width!.value, 12);
    expect(css.isEmpty, isFalse);
  });

  test('a null DTO maps to no CssStyle', () {
    expect(EpubDtoMapper.cssStyleFrom(null), isNull);
  });

  test('toParsedDocument carries metadata, chapters, and no cover', () {
    const metadata = MetadataDto(
      title: 'A Book',
      author: 'A. Author',
      language: 'en',
      fontFaces: [],
    );
    final doc = EpubDtoMapper.toParsedDocument(
      chapters: [_chapter(body: 'Hello')],
      metadata: metadata,
      fallbackTitle: 'fallback',
    );
    expect(doc.title, 'A Book');
    expect(doc.author, 'A. Author');
    expect(doc.chapters.single.body, 'Hello');
    expect(doc.coverBytes, isNull);
  });

  test('an empty metadata title falls back to the filename title', () {
    const metadata = MetadataDto(title: '', author: '', fontFaces: []);
    final doc = EpubDtoMapper.toParsedDocument(
      chapters: [_chapter(body: 'Hello')],
      metadata: metadata,
      fallbackTitle: 'Fallback',
    );
    expect(doc.title, 'Fallback');
  });
}
