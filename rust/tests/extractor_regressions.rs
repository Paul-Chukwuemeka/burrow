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

// --- Phase 2: paths, colours, units, CSS groups, TOC, images ---

use rust_lib_burrow::epub::comic::decode_image_dimensions;
use rust_lib_burrow::epub::container::{decode_percent, normalize_key, resolve_href};
use rust_lib_burrow::epub::nav::parse_nav;

#[test]
fn percent_decoding_is_tolerant_of_a_stray_percent() {
    assert_eq!(
        decode_percent("Chapter%201%20-%20100%.xhtml"),
        "Chapter 1 - 100%.xhtml"
    );
    assert_eq!(
        decode_percent("Chapter%201%20-%20100%25.xhtml"),
        "Chapter 1 - 100%.xhtml"
    );
}

#[test]
fn nfc_and_nfd_keys_match() {
    assert_eq!(
        normalize_key("caf\u{00E9}.xhtml"),
        normalize_key("cafe\u{0301}.xhtml")
    );
}

#[test]
fn backslash_hrefs_are_normalised() {
    assert_eq!(
        resolve_href("OEBPS", "Text\\ch1.xhtml"),
        "oebps/text/ch1.xhtml"
    );
}

#[test]
fn eight_digit_hex_is_rrggbbaa() {
    let chapter = project_styled_chapter("<body><p style=\"color:#00000080\">x</p></body>", "");
    let color = chapter
        .runs
        .iter()
        .find_map(|run| run.css.as_ref().and_then(|css| css.color))
        .expect("colour run");
    assert_eq!(color, 0x8000_0000);
}

#[test]
fn centimetre_lengths_are_converted_to_pixels() {
    let chapter = project_styled_chapter("<body><p style=\"font-size:1cm\">x</p></body>", "");
    let size = chapter
        .runs
        .iter()
        .find_map(|run| run.css.as_ref().and_then(|css| css.font_size))
        .expect("font-size run");
    assert!((size - 37.795_275_590_551_18).abs() < 0.001, "{size}");
}

#[test]
fn html_rules_apply_to_the_body_root() {
    let tree = styled("<body><p>x</p></body>", "html { color: red; }");
    assert_eq!(tree.nodes[0].style.color.as_deref(), Some("red"));
}

#[test]
fn media_screen_rules_are_applied_but_print_rules_are_not() {
    let tree = styled(
        "<body><p>x</p></body>",
        "@media screen { p { color: red; } } @media print { p { color: blue; } }",
    );
    let p = tree.nodes.iter().find(|n| n.attrs.tag == "p").unwrap();
    assert_eq!(p.style.color.as_deref(), Some("red"));
}

#[test]
fn margin_shorthand_expands_to_longhands() {
    let tree = styled("<body><p>x</p></body>", "p { margin: 0 2em; }");
    let p = tree.nodes.iter().find(|n| n.attrs.tag == "p").unwrap();
    assert_eq!(p.style.margin_top.as_deref(), Some("0"));
    assert_eq!(p.style.margin_right.as_deref(), Some("2em"));
    assert_eq!(p.style.margin_bottom.as_deref(), Some("0"));
    assert_eq!(p.style.margin_left.as_deref(), Some("2em"));
}

#[test]
fn toc_titles_collapse_internal_whitespace() {
    let xml = r#"<html><body><nav epub:type="toc"><ol>
        <li><a href="ch1.xhtml">Chapter
            One</a></li>
    </ol></nav></body></html>"#;
    let toc = parse_nav(xml, "nav.xhtml", false);
    assert_eq!(toc[0].title, "Chapter One");
}

#[test]
fn svg_width_ignores_stroke_and_data_attributes() {
    let svg = br#"<svg xmlns="http://www.w3.org/2000/svg" stroke-width="2" data-width="7" width="100" height="50"></svg>"#;
    assert_eq!(decode_image_dimensions(svg), (100, 50));
}

fn project_styled_chapter(xml: &str, css: &str) -> ChapterDto {
    let tree = styled(xml, css);
    project_with(&tree, String::new(), &Default::default(), |src| {
        (src.to_string(), None)
    })
}
