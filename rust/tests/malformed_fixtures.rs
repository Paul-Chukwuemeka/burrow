//! Integration tests for XHTML → block tree, driven by the committed synthetic
//! mini-EPUBs in `test/fixtures/epub/`.
//!
//! These pin the four input classes the block tree owns:
//! - malformed XHTML recovery (Review Focus #4),
//! - non-BMP UTF-16 offsets (Review Focus #1),
//! - percent-encoded/uppercase spine paths (Review Focus #3),
//! - scripted content / remote URLs (spec criterion 8, D9).
//!
//! `cargo test` runs with `rust/` as the working directory, so fixtures are
//! resolved via `CARGO_MANIFEST_DIR`.

use rust_lib_burrow::epub::block::{block_text_range, parse_xhtml_document};
use rust_lib_burrow::epub::container::EpubArchive;
use rust_lib_burrow::epub::model::{BlockKind, BlockTree, EpubError};

fn fixture(name: &str) -> String {
    format!(
        "{}/../test/fixtures/epub/{name}",
        env!("CARGO_MANIFEST_DIR")
    )
}

fn parse_xhtml_fixture(epub: &str, doc: &str) -> Result<BlockTree, EpubError> {
    let archive = EpubArchive::open(&fixture(epub))?;
    parse_xhtml_document(&archive, doc)
}

#[test]
fn well_formed_chapters_survive_unclosed_div() {
    let tree = parse_xhtml_fixture("malformed.epub", "ch1.xhtml").unwrap();
    assert!(tree.text().contains("Chapter one body"));

    // The sibling chapter is unaffected by ch1's unclosed tags.
    let sibling = parse_xhtml_fixture("malformed.epub", "ch2.xhtml").unwrap();
    assert!(sibling.text().contains("Chapter two body"));
}

#[test]
fn malformed_chapter_keeps_both_unclosed_paragraphs_as_blocks() {
    let tree = parse_xhtml_fixture("malformed.epub", "ch1.xhtml").unwrap();
    let paragraphs = tree
        .nodes
        .iter()
        .filter(|n| n.kind == BlockKind::Paragraph)
        .count();
    assert_eq!(paragraphs, 2, "both unclosed <p>s must survive as blocks");
    assert!(tree.text().contains("Chapter one second paragraph"));
}

#[test]
fn block_text_range_is_utf16() {
    // "A😀B" parsed as one paragraph => text_range == (0, 4).
    assert_eq!(block_text_range("A\u{1F600}B"), (0, 4));
}

#[test]
fn non_bmp_paragraph_offsets_are_utf16_through_the_archive() {
    let tree = parse_xhtml_fixture("nonbmp.epub", "ch1.xhtml").unwrap();
    let first = tree
        .nodes
        .iter()
        .position(|n| n.kind == BlockKind::Paragraph)
        .expect("first paragraph");
    assert_eq!(tree.nodes[first].text_range, (0, 4));
    assert_eq!(tree.node_text(first), "A\u{1F600}B");

    // The second paragraph starts at UTF-16 offset 4 (not byte offset 7).
    let second = tree
        .nodes
        .iter()
        .enumerate()
        .filter(|(_, n)| n.kind == BlockKind::Paragraph)
        .nth(1)
        .map(|(i, _)| i)
        .expect("second paragraph");
    assert_eq!(tree.nodes[second].text_range.0, 4);
    assert_eq!(tree.node_text(second), "\u{10348} tail");
}

#[test]
fn uppercase_percent_spine_path_resolves() {
    assert!(parse_xhtml_fixture("percent-path.epub", "Text/100%_cover.xhtml").is_ok());
    // The already-normalised key form resolves too.
    assert!(parse_xhtml_fixture("percent-path.epub", "oebps/text/100%_cover.xhtml").is_ok());
}

#[test]
fn script_and_remote_urls_are_never_executed_or_fetched() {
    let tree = parse_xhtml_fixture("scripted.epub", "ch1.xhtml").unwrap();
    assert!(!tree.has_script_node());
    assert_eq!(tree.remote_fetch_count(), 0);

    // The script *was* present and was dropped before entering the tree, so its
    // source cannot leak into the chapter text.
    assert_eq!(tree.dropped_script_count(), 1);
    assert!(!tree.text().contains("boom"));
    assert!(tree.text().contains("Safe body text"));

    // The absolute image URL is kept raw in the attrs — never resolved or
    // fetched (there is no fetch capability to resolve against).
    let image = tree
        .nodes
        .iter()
        .find(|n| n.kind == BlockKind::Image)
        .expect("image node");
    assert_eq!(
        image.attrs.src.as_deref(),
        Some("https://example.com/tracker.png")
    );
}
