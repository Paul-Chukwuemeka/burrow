import 'package:burrow/utils/highlight_locator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const charsBefore = [0, 100, 250];

  group('splitFlatOffset', () {
    test('finds the chapter containing the offset', () {
      expect(splitFlatOffset(0, charsBefore), (chapter: 0, offset: 0));
      expect(splitFlatOffset(99, charsBefore), (chapter: 0, offset: 99));
      expect(splitFlatOffset(100, charsBefore), (chapter: 1, offset: 0));
      expect(splitFlatOffset(249, charsBefore), (chapter: 1, offset: 149));
      expect(splitFlatOffset(250, charsBefore), (chapter: 2, offset: 0));
      expect(splitFlatOffset(300, charsBefore), (chapter: 2, offset: 50));
    });

    test('clamps negative offsets and handles an empty document', () {
      expect(splitFlatOffset(-5, charsBefore), (chapter: 0, offset: 0));
      expect(splitFlatOffset(10, const []), (chapter: 0, offset: 0));
    });
  });

  group('reflowableLocatorFromFlat', () {
    test('keeps a cross-chapter selection', () {
      expect(
        reflowableLocatorFromFlat(
          start: 90,
          end: 110,
          charsBefore: charsBefore,
        ),
        (chapter: 0, startOffset: 90, endChapter: 1, endOffset: 10),
      );
    });

    test('keeps a same-chapter selection', () {
      expect(
        reflowableLocatorFromFlat(start: 10, end: 20, charsBefore: charsBefore),
        (chapter: 0, startOffset: 10, endChapter: 0, endOffset: 20),
      );
    });

    test('uses the later chapter when the end is exactly on a boundary', () {
      expect(
        reflowableLocatorFromFlat(
          start: 90,
          end: 100,
          charsBefore: charsBefore,
        ),
        (chapter: 0, startOffset: 90, endChapter: 1, endOffset: 0),
      );
    });
  });

  group('flatOffsetFor', () {
    test('round-trips a locator', () {
      expect(flatOffsetFor(1, 0, charsBefore), 100);
      expect(flatOffsetFor(0, 50, charsBefore), 50);
      expect(flatOffsetFor(2, 25, charsBefore), 275);
    });

    test('clamps chapter and offset into range', () {
      expect(flatOffsetFor(-1, 5, charsBefore), 5);
      expect(flatOffsetFor(5, 0, charsBefore), 250);
      expect(flatOffsetFor(0, -5, charsBefore), 0);
    });
  });

  group('clampReflowableLocator', () {
    int length(int chapter) => 50;

    test('returns null for a missing chapter', () {
      expect(
        clampReflowableLocator(
          chapter: 5,
          startOffset: 0,
          endChapter: 5,
          endOffset: 10,
          chapterCount: 3,
          chapterLength: length,
        ),
        isNull,
      );
    });

    test('clamps an overlong end offset', () {
      expect(
        clampReflowableLocator(
          chapter: 0,
          startOffset: 40,
          endChapter: 0,
          endOffset: 90,
          chapterCount: 3,
          chapterLength: length,
        ),
        (chapter: 0, start: 40, end: 50),
      );
    });

    test('returns null when the clamped range is empty', () {
      expect(
        clampReflowableLocator(
          chapter: 0,
          startOffset: 80,
          endChapter: 0,
          endOffset: 90,
          chapterCount: 3,
          chapterLength: length,
        ),
        isNull,
      );
    });

    test('returns the start chapter for a cross-chapter range', () {
      expect(
        clampReflowableLocator(
          chapter: 0,
          startOffset: 10,
          endChapter: 2,
          endOffset: 20,
          chapterCount: 3,
          chapterLength: length,
        ),
        (chapter: 0, start: 10, end: 50),
      );
    });

    test('returns null when endChapter precedes chapter', () {
      expect(
        clampReflowableLocator(
          chapter: 2,
          startOffset: 0,
          endChapter: 0,
          endOffset: 10,
          chapterCount: 3,
          chapterLength: length,
        ),
        isNull,
      );
    });
  });

  group('clipHighlightToPage', () {
    test('clips a highlight that starts before the page', () {
      expect(
        clipHighlightToPage(
          highlightChapter: 0,
          startOffset: 10,
          endChapter: 0,
          endOffset: 90,
          chapter: 0,
          pageStart: 40,
          pageEnd: 60,
          chapterLength: 100,
        ),
        (start: 40, end: 60),
      );
    });

    test('returns null for a different chapter', () {
      expect(
        clipHighlightToPage(
          highlightChapter: 0,
          startOffset: 10,
          endChapter: 0,
          endOffset: 90,
          chapter: 1,
          pageStart: 0,
          pageEnd: 30,
          chapterLength: 100,
        ),
        isNull,
      );
    });

    test('paints a middle page of a cross-chapter highlight', () {
      expect(
        clipHighlightToPage(
          highlightChapter: 0,
          startOffset: 10,
          endChapter: 2,
          endOffset: 20,
          chapter: 1,
          pageStart: 0,
          pageEnd: 30,
          chapterLength: 100,
        ),
        (start: 0, end: 30),
      );
    });

    test('returns null when the highlight ends before the page', () {
      expect(
        clipHighlightToPage(
          highlightChapter: 0,
          startOffset: 10,
          endChapter: 0,
          endOffset: 20,
          chapter: 0,
          pageStart: 40,
          pageEnd: 60,
          chapterLength: 100,
        ),
        isNull,
      );
    });

    test('returns null when the highlight starts after the page', () {
      expect(
        clipHighlightToPage(
          highlightChapter: 0,
          startOffset: 70,
          endChapter: 0,
          endOffset: 90,
          chapter: 0,
          pageStart: 0,
          pageEnd: 30,
          chapterLength: 100,
        ),
        isNull,
      );
    });
  });
}
