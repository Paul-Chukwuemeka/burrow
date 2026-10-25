import 'package:burrow/utils/text_selection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'isWordChar accepts letters/digits and in-word apostrophes, rejects punctuation',
    () {
      for (final c in ['a', 'Z', 'é', '中', '1', '’']) {
        expect(isWordChar(c.runes.first), isTrue, reason: c);
      }
      for (final c in ['—', '\u201C', '\u201D', '.', ' ', '\uFFFC']) {
        expect(isWordChar(c.runes.first), isFalse, reason: c);
      }
    },
  );

  test('wordBoundsAt snaps outwards and trims edge punctuation', () {
    const body = 'The first chapter.';
    expect(wordBoundsAt(0, body, 0), (start: 0, end: 3)); // The
    expect(wordBoundsAt(5, body, 0), (start: 4, end: 9)); // first
    expect(wordBoundsAt(12, body, 0), (
      start: 10,
      end: 17,
    )); // chapter (period dropped)
    expect(wordBoundsAt(0, 'a — b', 0)!.end, 1); // em dash is not a word
  });

  test('wordBoundsAt returns null when the press is not on a word char', () {
    const body = 'The first chapter.';
    expect(wordBoundsAt(17, body, 0), isNull); // the period
    expect(wordBoundsAt(3, body, 0), isNull); // the space after "The"
  });

  test(
    'wordBoundsAt returns null when the press is on a word-edge apostrophe',
    () {
      expect(wordBoundsAt(0, "'tis", 0), isNull); // leading apostrophe
      expect(wordBoundsAt(4, 'word’ next', 0), isNull); // trailing apostrophe
    },
  );

  test('wordBoundsAt treats astral letters as word characters', () {
    const body = 'a\u{20000}b';
    expect(wordBoundsAt(0, body, 0), (start: 0, end: 4));
  });

  test('wordBoundsAt clamps to the page window', () {
    const body = 'one two three';
    // Window covering only "two" (flat 4..7): a press at 4 must not return "one".
    expect(wordBoundsAt(4, body, 0, loFlat: 4, hiFlat: 7), (start: 4, end: 7));
  });

  test(
    'showsSelectionEndHandle bridges when the page’s last char is covered',
    () {
      // The previous page runs flat 0..1080 (end exclusive), so the selection end
      // at 1080 includes the character at 1079: the handle waits at the top of
      // this page.
      expect(
        showsSelectionEndHandle(
          isCurrentPage: true,
          selectionEnd: 1080,
          pageFlatStart: 1081,
          pageFlatEnd: 1620,
          previousPageFlatEnd: 1080,
          isLastPage: false,
        ),
        isTrue,
      );
    },
  );

  test('showsSelectionEndHandle refuses an end short of the page edge', () {
    // A word-snapped end before trailing punctuation stops at 1079 and does
    // not cover the page's final character: nothing waits on the next page.
    expect(
      showsSelectionEndHandle(
        isCurrentPage: true,
        selectionEnd: 1079,
        pageFlatStart: 1081,
        pageFlatEnd: 1620,
        previousPageFlatEnd: 1080,
        isLastPage: false,
      ),
      isFalse,
    );
    // Likewise a selection that ends in the middle of the previous page.
    expect(
      showsSelectionEndHandle(
        isCurrentPage: true,
        selectionEnd: 700,
        pageFlatStart: 1081,
        pageFlatEnd: 1620,
        previousPageFlatEnd: 1080,
        isLastPage: false,
      ),
      isFalse,
    );
  });

  test('showsSelectionEndHandle accepts an end on the current page', () {
    expect(
      showsSelectionEndHandle(
        isCurrentPage: true,
        selectionEnd: 1200,
        pageFlatStart: 1081,
        pageFlatEnd: 1620,
        previousPageFlatEnd: 1080,
        isLastPage: false,
      ),
      isTrue,
    );
  });

  test('showsSelectionEndHandle accepts an end at the last page end', () {
    expect(
      showsSelectionEndHandle(
        isCurrentPage: true,
        selectionEnd: 1620,
        pageFlatStart: 1081,
        pageFlatEnd: 1620,
        previousPageFlatEnd: 1080,
        isLastPage: true,
      ),
      isTrue,
    );
    // The same end on a non-last page belongs to the next page instead.
    expect(
      showsSelectionEndHandle(
        isCurrentPage: true,
        selectionEnd: 1620,
        pageFlatStart: 1081,
        pageFlatEnd: 1620,
        previousPageFlatEnd: 1080,
        isLastPage: false,
      ),
      isFalse,
    );
  });

  test('showsSelectionEndHandle is false off the current page', () {
    expect(
      showsSelectionEndHandle(
        isCurrentPage: false,
        selectionEnd: 1200,
        pageFlatStart: 1081,
        pageFlatEnd: 1620,
        previousPageFlatEnd: 1080,
        isLastPage: false,
      ),
      isFalse,
    );
    expect(
      showsSelectionEndHandle(
        isCurrentPage: true,
        selectionEnd: null,
        pageFlatStart: 1081,
        pageFlatEnd: 1620,
        previousPageFlatEnd: 1080,
        isLastPage: false,
      ),
      isFalse,
    );
  });

  test('selectionText joins chapters with newline and strips placeholders', () {
    final bodies = ['ab\uFFFCcd', 'EF'];
    const charsBefore = [0, 6];
    expect(
      selectionText(
        start: 0,
        end: 8,
        chapterBodies: bodies,
        charsBefore: charsBefore,
      ),
      'abcd\nEF',
    );
  });

  test('selectionText skips an image-only chapter without a blank line', () {
    expect(
      selectionText(
        start: 0,
        end: 3,
        chapterBodies: ['A', '\uFFFC', 'B'],
        charsBefore: [0, 1, 2],
      ),
      'A\nB',
    );
  });

  test('pageLocalRange clamps to the page', () {
    expect(
      pageLocalRange(
        selectionStart: 3,
        selectionEnd: 9,
        chapterStartFlat: 0,
        pageStart: 5,
        pageEnd: 12,
      ),
      (start: 5, end: 9),
    );
    expect(
      pageLocalRange(
        selectionStart: 0,
        selectionEnd: 3,
        chapterStartFlat: 0,
        pageStart: 5,
        pageEnd: 12,
      ),
      isNull,
    );
  });

  test('isSingleWordRange is true only for one word', () {
    final bodies = ['The first chapter.'];
    expect(
      isSingleWordRange(
        start: 4,
        end: 9,
        chapterBodies: bodies,
        charsBefore: [0],
      ),
      isTrue,
    );
    expect(
      isSingleWordRange(
        start: 4,
        end: 17,
        chapterBodies: bodies,
        charsBefore: [0],
      ),
      isFalse,
    );
  });
}
