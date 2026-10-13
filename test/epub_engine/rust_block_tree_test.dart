// Dart adapter test for the Rust block tree (Task 5).
//
// Confirms the tree crosses FFI intact and that the two invariants the rest of
// Phase A depends on hold on the Dart side:
//  * `BlockNode.textRange` indexes `BlockTree.text` in UTF-16 code units, so
//    `text.substring` produces the node's text even with non-BMP characters;
//  * scripted content is absent and no remote fetch happened (D9 / criterion 8).
//
// `RustLib.init()` dlopens the host build from `rust/target/release/`;
// `test/flutter_test_config.dart` builds it on demand.
import 'package:burrow/src/rust/api/epub.dart';
import 'package:burrow/src/rust/epub/model.dart';
import 'package:burrow/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';

const _minimal = 'test/fixtures/epub/minimal.epub';
const _nonBmp = 'test/fixtures/epub/nonbmp.epub';
const _scripted = 'test/fixtures/epub/scripted.epub';
const _malformed = 'test/fixtures/epub/malformed.epub';

void main() {
  setUpAll(() async {
    await RustLib.init();
  });

  test('exposes block structure (headings and paragraphs) over FFI', () async {
    final handle = await openEpub(path: _minimal);
    final tree = await blockTree(handle: handle, chapterKey: 'oebps/text/ch1.xhtml');

    expect(tree.nodes, isNotEmpty);
    expect(tree.nodes.first.kind, BlockKind.root);
    expect(tree.text, contains('The first chapter.'));

    final headings =
        tree.nodes.where((n) => n.kind == BlockKind.heading).toList();
    expect(headings, hasLength(1));
    expect(headings.single.headingLevel, 1);

    final paragraphs =
        tree.nodes.where((n) => n.kind == BlockKind.paragraph).toList();
    expect(paragraphs, isNotEmpty);
    // `textRange` is a plain Dart record of two `int`s (u32 on the Rust side).
    final (start, end) = paragraphs.first.textRange;
    expect(tree.text.substring(start, end), contains('The first chapter.'));
  });

  test('text ranges are UTF-16 code units for non-BMP text', () async {
    final handle = await openEpub(path: _nonBmp);
    final tree = await blockTree(handle: handle, chapterKey: 'oebps/ch1.xhtml');

    final paragraphs =
        tree.nodes.where((n) => n.kind == BlockKind.paragraph).toList();
    expect(paragraphs, hasLength(3));

    final first = paragraphs[0].textRange;
    expect(first.$1, 0);
    expect(first.$2, 4); // "A😀B" is 4 UTF-16 units, not 6 bytes.
    expect(tree.text.substring(0, 4), 'A\u{1F600}B');

    final second = paragraphs[1].textRange;
    expect(second.$1, 4);
    expect(tree.text.substring(second.$1, second.$2), '\u{10348} tail');

    // Inline-sibling spaces are rendered content and must survive.
    final third = paragraphs[2].textRange;
    expect(tree.text.substring(third.$1, third.$2), 'a b c');
  });

  test('drops scripted content and never fetches remote URLs', () async {
    final handle = await openEpub(path: _scripted);
    final tree = await blockTree(handle: handle, chapterKey: 'oebps/ch1.xhtml');

    expect(tree.droppedScripts, 1);
    expect(tree.remoteFetches, 0);
    expect(tree.text, contains('Safe body text.'));
    expect(tree.text, isNot(contains('boom')));

    final image = tree.nodes.firstWhere((n) => n.kind == BlockKind.image);
    expect(image.attrs.src, 'https://example.com/tracker.png');
  });

  test('recovers from malformed XHTML without losing content', () async {
    final handle = await openEpub(path: _malformed);
    final tree = await blockTree(handle: handle, chapterKey: 'oebps/ch1.xhtml');

    expect(tree.text, contains('Chapter one body'));
    expect(tree.text, contains('Chapter one second paragraph'));
  });
}
