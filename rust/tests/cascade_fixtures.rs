//! Integration tests for the CSS cascade, driven by the committed synthetic
//! mini-EPUBs in `test/fixtures/epub/`.
//!
//! These pin the input classes the cascade owns:
//! - a class rule applies to *every* matching element, including repeated
//!   identical paragraphs (Review Focus #2),
//! - class specificity beats a tag rule and inherited properties flow to
//!   descendants,
//! - `@font-face` extraction with relative `src` resolution,
//! - descendant combinators and presentational hints.
//!
//! `cargo test` runs with `rust/` as the working directory, so fixtures are
//! resolved via `CARGO_MANIFEST_DIR`.

use rust_lib_burrow::epub::block::parse_xhtml_document_parts;
use rust_lib_burrow::epub::cascade::{resolve_stylesheets, ComputedStyleTable};
use rust_lib_burrow::epub::container::EpubArchive;
use rust_lib_burrow::epub::model::{BlockNode, BlockTree};
use rust_lib_burrow::epub::opf::{read_metadata, read_navigation_from};

fn fixture(name: &str) -> String {
    format!("{}/../test/fixtures/epub/{name}", env!("CARGO_MANIFEST_DIR"))
}

fn styled_tree(epub: &str, doc: &str) -> (BlockTree, ComputedStyleTable) {
    let archive = EpubArchive::open(&fixture(epub)).unwrap();
    let navigation = read_navigation_from(&archive).unwrap();
    let (tree, inline_styles) = parse_xhtml_document_parts(&archive, doc).unwrap();
    let table = resolve_stylesheets(
        &navigation.manifest,
        |key| archive.read_by_key(key),
        &inline_styles,
        &tree,
    );
    (tree, table)
}

fn cascade_fixture(epub: &str, doc: &str) -> ComputedStyleTable {
    styled_tree(epub, doc).1
}

fn node_index(tree: &BlockTree, predicate: impl Fn(&BlockNode) -> bool) -> usize {
    tree.nodes.iter().position(predicate).expect("node")
}

fn indices_with_class(tree: &BlockTree, class: &str) -> Vec<usize> {
    tree.nodes
        .iter()
        .enumerate()
        .filter(|(_, node)| {
            node.attrs
                .class
                .as_deref()
                .map(|value| value.split_whitespace().any(|token| token == class))
                .unwrap_or(false)
        })
        .map(|(index, _)| index)
        .collect()
}

#[test]
fn class_rule_applies_to_every_matching_element() {
    let styles = cascade_fixture("repeated-paragraphs.epub", "ch1.xhtml");
    assert_eq!(styles.nodes_with_class("note").count(), 2);
    for style in styles.nodes_with_class("note") {
        assert_eq!(style.color.as_deref(), Some("#333333"));
        assert_eq!(style.font_size.as_deref(), Some("14px"));
    }
}

#[test]
fn element_rule_beats_tag_and_inherits_font_family() {
    let (tree, table) = styled_tree("external-css.epub", "ch1.xhtml");

    // `.title` (class) on the h1 beats the UA `h1 { font-size: 2em }`.
    let h1 = node_index(&tree, |node| node.attrs.tag == "h1");
    assert_eq!(table.style_for(h1).unwrap().font_size.as_deref(), Some("24px"));

    // `.note` (class) beats `p { font-size: 12px }` on the same element; both
    // repeated paragraphs are styled, not just the first.
    let notes = indices_with_class(&tree, "note");
    assert_eq!(notes.len(), 2);
    for index in notes {
        assert_eq!(
            table.style_for(index).unwrap().font_size.as_deref(),
            Some("14px"),
            "class specificity must beat the tag rule"
        );
    }

    // font-family is inherited from `body` to every descendant.
    for index in std::iter::once(h1).chain(indices_with_class(&tree, "note")) {
        assert_eq!(
            table.style_for(index).unwrap().font_family.as_deref(),
            Some("'Burrow Serif', serif")
        );
    }
}

#[test]
fn font_face_is_extracted_with_src_resolved_against_the_css_directory() {
    let (_, table) = styled_tree("external-css.epub", "ch1.xhtml");
    assert_eq!(table.font_faces.len(), 1);
    assert_eq!(table.font_faces[0].family, "Burrow Serif");
    assert_eq!(table.font_faces[0].src, "oebps/fonts/burrow.woff2");

    // The metadata path extracts the same faces without a chapter parse.
    let metadata = read_metadata(&fixture("external-css.epub")).unwrap();
    assert_eq!(metadata.font_faces, table.font_faces);
}

#[test]
fn descendant_combinator_and_presentational_hint_both_apply() {
    let (tree, table) = styled_tree("external-css.epub", "ch1.xhtml");

    let box_index = node_index(&tree, |node| node.attrs.class.as_deref() == Some("box"));
    let nested = tree.nodes[box_index]
        .children
        .iter()
        .map(|&child| child as usize)
        .find(|&child| tree.nodes[child].attrs.tag == "p")
        .expect("nested paragraph");
    assert_eq!(
        table.style_for(nested).unwrap().text_align.as_deref(),
        Some("justify")
    );

    let hinted = node_index(&tree, |node| node.attrs.align.as_deref() == Some("right"));
    assert_eq!(
        table.style_for(hinted).unwrap().text_align.as_deref(),
        Some("right")
    );
}

#[test]
fn computed_styles_are_attached_to_the_tree() {
    let (mut tree, table) = styled_tree("external-css.epub", "ch1.xhtml");
    table.attach(&mut tree);
    let h1 = node_index(&tree, |node| node.attrs.tag == "h1");
    assert_eq!(tree.nodes[h1].style.font_size.as_deref(), Some("24px"));
    assert!(tree.nodes[h1]
        .style
        .declared
        .iter()
        .any(|property| property == "font-size"));
}

#[test]
fn malformed_utf8_stylesheet_is_decoded_lossily_not_dropped() {
    // A stray 0xFF byte sits inside a comment: the stylesheet must be decoded
    // with `allowMalformed` (UTF-8 lossy) so the *valid* rule after it still
    // applies, instead of failing the whole sheet on the invalid byte.
    let tree = rust_lib_burrow::epub::block::parse_xhtml("<body><p class=\"note\">x</p></body>");
    let mut manifest = std::collections::HashMap::new();
    manifest.insert("css1".to_string(), "oebps/broken.css".to_string());
    let table = resolve_stylesheets(
        &manifest,
        |key| (key == "oebps/broken.css").then(|| b"/* \xff\xfe */ .note { color: red; }".to_vec()),
        &[],
        &tree,
    );
    let note = table.nodes_with_class("note").next().expect("note styled");
    assert_eq!(note.color.as_deref(), Some("red"));
}

#[test]
fn unstyled_book_has_no_author_declarations() {
    // minimal.epub declares no CSS; every node's computed style is UA defaults
    // only, so nothing is author-declared (which is what keeps the phase-1
    // projection unchanged for unstyled books).
    let archive = EpubArchive::open(&fixture("minimal.epub")).unwrap();
    let navigation = read_navigation_from(&archive).unwrap();
    let (tree, inline_styles) =
        parse_xhtml_document_parts(&archive, "Text/ch1.xhtml").unwrap();
    let table = resolve_stylesheets(
        &navigation.manifest,
        |key| archive.read_by_key(key),
        &inline_styles,
        &tree,
    );
    assert!(table.font_faces.is_empty());
    assert!(tree
        .nodes
        .iter()
        .all(|node| node.style.declared.is_empty()));
    assert!(table
        .styles
        .iter()
        .all(|style| style.declared.is_empty()));
}
