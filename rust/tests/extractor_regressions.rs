//! Regression tests for extractor hardening.
//!
//! Each test pins a user-visible failure found in the extractor audit. They are
//! intentionally end-to-end: parse XHTML (and, where relevant, attach the
//! cascade) and assert on the flat `ChapterDto::body` the reader renders.

use std::collections::HashMap;

use rust_lib_burrow::epub::block::{parse_xhtml, parse_xhtml_bytes};
use rust_lib_burrow::epub::cascade::resolve_stylesheets;
use rust_lib_burrow::epub::model::BlockTree;
use rust_lib_burrow::epub::project::{project_with, ChapterDto};

fn project(xml: &str) -> ChapterDto {
    let tree = parse_xhtml(xml);
    project_with(&tree, String::new(), &Default::default(), |src| {
        (src.to_string(), None)
    })
}

fn styled(xml: &str, css: &str) -> BlockTree {
    let mut tree = parse_xhtml(xml);
    let table = resolve_stylesheets(&HashMap::new(), |_| None, &[css.to_string()], &tree);
    table.attach(&mut tree);
    tree
}

fn project_styled(xml: &str, css: &str) -> String {
    let tree = styled(xml, css);
    project_with(&tree, String::new(), &Default::default(), |src| {
        (src.to_string(), None)
    })
    .body
}

fn body_of(tree: &BlockTree) -> String {
    project_with(tree, String::new(), &Default::default(), |src| {
        (src.to_string(), None)
    })
    .body
}

#[test]
fn windows_1252_declaration_is_honoured() {
    // "Café — “quote”" in windows-1252.
    let mut bytes =
        br#"<?xml version="1.0" encoding="windows-1252"?><html><body><p>"#.to_vec();
    bytes.extend_from_slice(&[
        b'C', b'a', b'f', 0xE9, b' ', 0x97, b' ', 0x93, b'q', b'u', b'o', b't', b'e',
        0x94,
    ]);
    bytes.extend_from_slice(b"</p></body></html>");
    let tree = parse_xhtml_bytes(&bytes);
    assert_eq!(body_of(&tree), "Café — “quote”");
}

#[test]
fn utf16_without_bom_is_decoded() {
    let text =
        "<?xml version=\"1.0\" encoding=\"utf-16\"?><html><body><p>Hello</p></body></html>";
    let mut bytes = Vec::new();
    for unit in text.encode_utf16() {
        bytes.extend_from_slice(&unit.to_le_bytes());
    }
    let tree = parse_xhtml_bytes(&bytes);
    assert_eq!(body_of(&tree), "Hello");
}

#[test]
fn pre_preserves_newlines_and_indentation() {
    let chapter = project("<body><pre>line one\nline two\n    indented</pre></body>");
    assert_eq!(chapter.body, "line one\nline two\n    indented");
}

#[test]
fn white_space_pre_preserves_newlines() {
    assert_eq!(
        project_styled(
            "<body><p class=\"p\">a\nb   c</p></body>",
            ".p { white-space: pre; }"
        ),
        "a\nb   c"
    );
}

#[test]
fn cdata_text_is_preserved() {
    assert_eq!(project("<body><p>a<![CDATA[b<c]]>d</p></body>").body, "ab<cd");
}

#[test]
fn display_none_content_is_excluded() {
    assert_eq!(
        project_styled(
            "<body><p>visible</p><p style=\"display:none\">secret</p></body>",
            ""
        ),
        "visible"
    );
    assert_eq!(
        project_styled(
            "<body><p>visible</p><p class=\"x\">secret</p></body>",
            ".x { display: none; }"
        ),
        "visible"
    );
}

#[test]
fn hidden_attribute_content_is_excluded() {
    assert_eq!(
        project_styled("<body><p>visible</p><p hidden>secret</p></body>", ""),
        "visible"
    );
}

#[test]
fn table_cells_do_not_merge() {
    let body = project(
        "<body><table><tr><td>A</td><td>B</td></tr><tr><td>C</td><td>D</td></tr></table></body>",
    )
    .body;
    assert_eq!(body, "A\nB\n\nC\nD");
}

#[test]
fn definition_list_entries_do_not_merge() {
    let body = project("<body><dl><dt>Term</dt><dd>Def</dd><dt>Term2</dt><dd>Def2</dd></dl></body>")
        .body;
    assert_eq!(body, "Term\nDef\nTerm2\nDef2");
}

#[test]
fn figure_captions_do_not_merge() {
    let body = project(
        "<body><figure><img src=\"a.png\"/><figcaption>Cap1</figcaption></figure>\
         <figure><img src=\"b.png\"/><figcaption>Cap2</figcaption></figure></body>",
    )
    .body;
    assert_eq!(body, "\u{FFFC}\nCap1\n\n\u{FFFC}\nCap2");
}

#[test]
fn ruby_annotation_text_is_excluded() {
    assert_eq!(
        project("<body><p><ruby>漢<rp>(</rp><rt>kan</rt><rp>)</rp></ruby></p></body>")
            .body,
        "漢"
    );
}

#[test]
fn hr_separates_paragraphs() {
    assert_eq!(
        project("<body><p>one</p><hr/><p>two</p></body>").body,
        "one\n\ntwo"
    );
}
