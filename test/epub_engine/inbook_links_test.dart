// In-book EPUB links end-to-end: the Rust engine resolves every internal
// `<a href>` of `inbook-links.epub` to a flat chapter target offscreen, and
// `EpubDtoMapper` carries those onto the domain `Chapter` unchanged.
//
// The fixture's spine is a contents page of links followed by an anchor-split
// document (part1..3), so the flat chapter list is: contents (0), Part One
// (1), Part Two (2), Part Three (3). External http hrefs and unresolvable
// anchors never cross the FFI.
import 'package:burrow/services/epub/rust_epub_engine.dart';
import 'package:burrow/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';

const _fixture = 'test/fixtures/epub/inbook-links.epub';

void main() {
  setUpAll(() async {
    await RustLib.init();
  });

  test('contents links resolve to flat chapter targets', () async {
    final doc = await const RustEpubEngine().parse(_fixture);
    expect(doc.chapters, hasLength(4));
    final links = doc.chapters.first.links;
    // part-one, part-two (styled), self-note, footnote. The https link drops.
    expect(links, hasLength(4));
    final targets = links.map((l) => l.target).toList();
    expect(targets, containsAllInOrder(<int>[1, 2, 0, 3]));
    // Every link's range re-reads its own visible text from the body.
    for (final link in links) {
      expect(
        doc.chapters.first.body.substring(link.start, link.end),
        isNotEmpty,
        reason: 'links must cover their own text',
      );
    }
  });

  test('chapter-local links carry the final body offsets', () async {
    final doc = await const RustEpubEngine().parse(_fixture);
    // The anchor-split document's Part Two has a same-file link ahead.
    final partTwo = doc.chapters[2];
    expect(partTwo.title, 'Part Two');
    final ahead = partTwo.links.single;
    expect(ahead.target, 3);
    expect(
      partTwo.body.substring(ahead.start, ahead.end),
      'next',
    );
  });
}
