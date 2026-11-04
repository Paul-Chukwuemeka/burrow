//! Integration tests for the chapter-scoped cascade: `<link rel="stylesheet">`
//! inputs are applied in document order, unrelated manifest sheets are not
//! applied, `@import`ed sheets apply before the importing sheet, and
//! style-less documents keep the legacy manifest fallback.

use std::collections::HashMap;

use rust_lib_burrow::epub::block::{parse_xhtml_bytes_parts_with_links};
use rust_lib_burrow::epub::cascade::{resolve_stylesheets_ordered, ComputedStyleTable};
use rust_lib_burrow::epub::dom::StyleEvent;
use rust_lib_burrow::epub::model::BlockTree;

fn apply(
    html: &str,
    manifest: &HashMap<String, String>,
    sheets: &[(&str, &str)],
) -> (BlockTree, ComputedStyleTable) {
    let (tree, events) = parse_xhtml_bytes_parts_with_links(html.as_bytes());
    let sheet_map: HashMap<String, &str> = sheets
        .iter()
        .map(|(key, css)| (key.trim_matches('/').to_ascii_lowercase(), *css))
        .collect();
    let read = |key: &str| {
        sheet_map
            .get(key)
            .map(|css| css.as_bytes().to_vec())
    };
    let table = resolve_stylesheets_ordered(manifest, read, &events, "oebps/ch1.xhtml", &tree);
    (tree, table)
}

fn p_color(tree: &BlockTree, table: &ComputedStyleTable) -> Option<String> {
    let index = tree
        .nodes
        .iter()
        .position(|n| n.attrs.tag == "p")
        .expect("p node");
    table.style_for(index).unwrap().color.clone()
}

const LINK_TWO: &str = r#"<html><head>
    <link rel="stylesheet" href="a.css"/>
    <link rel="stylesheet" href="b.css"/>
</head><body><p>x</p></body></html>"#;

const LINK_TWO_REVERSED: &str = r#"<html><head>
    <link rel="stylesheet" href="b.css"/>
    <link rel="stylesheet" href="a.css"/>
</head><body><p>x</p></body></html>"#;

#[test]
fn linked_sheets_apply_in_document_order() {
    let sheets = [("oebps/a.css", "p { color: red; }"), ("oebps/b.css", "p { color: blue; }")];
    let (tree, table) = apply(LINK_TWO, &HashMap::new(), &sheets);
    assert_eq!(p_color(&tree, &table).as_deref(), Some("blue"));
}

#[test]
fn linked_sheets_apply_in_document_order_reversed() {
    let sheets = [("oebps/a.css", "p { color: red; }"), ("oebps/b.css", "p { color: blue; }")];
    let (tree, table) = apply(LINK_TWO_REVERSED, &HashMap::new(), &sheets);
    assert_eq!(p_color(&tree, &table).as_deref(), Some("red"));
}

#[test]
fn unlinked_manifest_css_is_not_applied() {
    let html = r#"<html><head>
        <link rel="stylesheet" href="a.css"/>
    </head><body><p>x</p></body></html>"#;
    let mut manifest = HashMap::new();
    manifest.insert("a".to_string(), "oebps/a.css".to_string());
    manifest.insert("z".to_string(), "oebps/z.css".to_string());
    let sheets = [("oebps/a.css", "p { color: red; }"), ("oebps/z.css", "p { color: green; }")];
    let (tree, table) = apply(html, &manifest, &sheets);
    assert_eq!(p_color(&tree, &table).as_deref(), Some("red"));
}

#[test]
fn chapter_without_styling_inputs_falls_back_to_manifest_css() {
    let html = r#"<html><head></head><body><p>x</p></body></html>"#;
    let mut manifest = HashMap::new();
    manifest.insert("a".to_string(), "oebps/a.css".to_string());
    let sheets = [("oebps/a.css", "p { color: red; }")];
    let (tree, table) = apply(html, &manifest, &sheets);
    assert_eq!(p_color(&tree, &table).as_deref(), Some("red"));
}

#[test]
fn inline_style_after_link_beats_link() {
    let html = r#"<html><head>
        <link rel="stylesheet" href="a.css"/>
        <style>p { color: green; }</style>
    </head><body><p>x</p></body></html>"#;
    let sheets = [("oebps/a.css", "p { color: red; }")];
    let (tree, table) = apply(html, &HashMap::new(), &sheets);
    assert_eq!(p_color(&tree, &table).as_deref(), Some("green"));
}

#[test]
fn link_after_inline_style_beats_inline() {
    let html = r#"<html><head>
        <style>p { color: green; }</style>
        <link rel="stylesheet" href="a.css"/>
    </head><body><p>x</p></body></html>"#;
    let sheets = [("oebps/a.css", "p { color: red; }")];
    let (tree, table) = apply(html, &HashMap::new(), &sheets);
    assert_eq!(p_color(&tree, &table).as_deref(), Some("red"));
}

#[test]
fn alternate_stylesheet_link_is_ignored() {
    let html = r#"<html><head>
        <link rel="alternate stylesheet" href="alt.css"/>
    </head><body><p>x</p></body></html>"#;
    let sheets = [("oebps/alt.css", "p { color: red; }")];
    let (tree, table) = apply(html, &HashMap::new(), &sheets);
    assert_eq!(p_color(&tree, &table), None);
}

#[test]
fn import_applies_before_the_importing_sheet() {
    let importing = r#"@import url("b.css");
p { color: green; }"#;
    let html = r#"<html><head>
        <link rel="stylesheet" href="a.css"/>
    </head><body><p>x</p></body></html>"#;
    let sheets = [
        ("oebps/a.css", importing),
        ("oebps/b.css", "p { color: red; }"),
    ];
    let (tree, table) = apply(html, &HashMap::new(), &sheets);
    assert_eq!(p_color(&tree, &table).as_deref(), Some("green"));

    let importing_only = r#"@import "b.css";"#;
    let sheets = [
        ("oebps/a.css", importing_only),
        ("oebps/b.css", "p { color: red; }"),
    ];
    let (tree, table) = apply(html, &HashMap::new(), &sheets);
    assert_eq!(p_color(&tree, &table).as_deref(), Some("red"));
}

#[test]
fn import_resolves_relative_to_the_importing_sheet() {
    let css = r#"@import url("../two/b.css");"#;
    let html = r#"<html><head>
        <link rel="stylesheet" href="one/a.css"/>
    </head><body><p>x</p></body></html>"#;
    let sheets = [
        ("oebps/one/a.css", css),
        ("oebps/two/b.css", "p { color: red; }"),
    ];
    let (tree, table) = apply(html, &HashMap::new(), &sheets);
    assert_eq!(p_color(&tree, &table).as_deref(), Some("red"));
}

#[test]
fn cyclic_imports_terminate() {
    let a = r#"@import url("b.css"); p { color: green; }"#;
    let b = r#"@import url("a.css"); p { font-size: 12px; }"#;
    let html = r#"<html><head>
        <link rel="stylesheet" href="a.css"/>
    </head><body><p>x</p></body></html>"#;
    let sheets = [("oebps/a.css", a), ("oebps/b.css", b)];
    let (tree, table) = apply(html, &HashMap::new(), &sheets);
    assert_eq!(p_color(&tree, &table).as_deref(), Some("green"));
}

#[test]
fn print_import_is_skipped() {
    let css = r#"@import url("print.css") print; p { color: green; }"#;
    let html = r#"<html><head>
        <link rel="stylesheet" href="a.css"/>
    </head><body><p>x</p></body></html>"#;
    let sheets = [
        ("oebps/a.css", css),
        ("oebps/print.css", "p { color: red; }"),
    ];
    let (tree, table) = apply(html, &HashMap::new(), &sheets);
    assert_eq!(p_color(&tree, &table).as_deref(), Some("green"));
}

#[test]
fn screen_import_is_applied() {
    let css = r#"@import url("screen.css") screen; p { color: green; }"#;
    let html = r#"<html><head>
        <link rel="stylesheet" href="a.css"/>
    </head><body><p>x</p></body></html>"#;
    let sheets = [
        ("oebps/a.css", css),
        ("oebps/screen.css", "p { color: red; }"),
    ];
    let (tree, table) = apply(html, &HashMap::new(), &sheets);
    assert_eq!(p_color(&tree, &table).as_deref(), Some("green"));
}

#[test]
fn import_in_inline_style_resolves_against_the_chapter_directory() {
    let html = r#"<html><head>
        <style>@import url("shared/a.css"); p { color: green; }</style>
    </head><body><p>x</p></body></html>"#;
    let sheets = [("oebps/shared/a.css", "p { color: red; }")];
    let (tree, table) = apply(html, &HashMap::new(), &sheets);
    assert_eq!(p_color(&tree, &table).as_deref(), Some("green"));
}

#[test]
fn events_preserve_document_order() {
    let html = r#"<html><head>
        <link rel="stylesheet" href="a.css"/>
        <style>p { color: green; }</style>
        <link rel="stylesheet" href="b.css"/>
    </head><body><p>x</p></body></html>"#;
    let (_, events) = parse_xhtml_bytes_parts_with_links(html.as_bytes());
    assert_eq!(
        events,
        vec![
            StyleEvent::Link("a.css".to_string()),
            StyleEvent::Style("p { color: green; }".to_string()),
            StyleEvent::Link("b.css".to_string()),
        ]
    );
}

/// End-to-end through a real archive: chapter 1 links only `style1.css`, so
/// the manifest's `style2.css` must not leak into it; chapter 2 declares no
/// styling input and gets the legacy manifest fallback.
#[test]
fn chapter_scoped_cascade_through_the_full_path() {
    let container = br#"<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>"#;
    let opf = br#"<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="id" version="3.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="id">test</dc:identifier>
    <dc:title>T</dc:title>
    <dc:creator>a</dc:creator>
    <dc:language>en</dc:language>
  </metadata>
  <manifest>
    <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="ch2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
    <item id="s1" href="style1.css" media-type="text/css"/>
    <item id="s2" href="style2.css" media-type="text/css"/>
  </manifest>
  <spine><itemref idref="ch1"/><itemref idref="ch2"/></spine>
</package>"#;
    let ch1 = br#"<?xml version="1.0"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><link rel="stylesheet" href="style1.css"/></head>
<body><p class="x">one</p></body></html>"#;
    let ch2 = br#"<?xml version="1.0"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head></head><body><p class="x">two</p></body></html>"#;
    let entries: Vec<(&str, &[u8])> = vec![
        ("mimetype", b"application/epub+zip"),
        ("META-INF/container.xml", container),
        ("OEBPS/content.opf", opf),
        ("OEBPS/ch1.xhtml", ch1),
        ("OEBPS/ch2.xhtml", ch2),
        ("OEBPS/style1.css", b".x { color: red; }"),
        ("OEBPS/style2.css", b".x { color: blue; }"),
    ];
    let path = write_epub(&entries);
    let archive = rust_lib_burrow::epub::container::EpubArchive::open(path.to_str().unwrap()).unwrap();
    let navigation = rust_lib_burrow::epub::opf::read_navigation_from(&archive).unwrap();
    let p_color = |key: &str| {
        let tree = rust_lib_burrow::epub::cascade::parse_styled_document(
            &archive,
            &navigation.manifest,
            key,
        )
        .unwrap();
        let index = tree.nodes.iter().position(|n| n.attrs.tag == "p").unwrap();
        tree.nodes[index].style.color.clone()
    };
    assert_eq!(p_color("OEBPS/ch1.xhtml").as_deref(), Some("red"));
    assert_eq!(p_color("OEBPS/ch2.xhtml").as_deref(), Some("blue"));
    let _ = std::fs::remove_file(&path);
}

/// Writes entries into a minimal stored (uncompressed) ZIP with an .epub
/// extension and returns its path.
fn write_epub(entries: &[(&str, &[u8])]) -> std::path::PathBuf {
    use std::io::Write;
    let path = std::env::temp_dir().join(format!(
        "burrow-casc-link-{}-{:?}.epub",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let file = std::fs::File::create(&path).unwrap();
    let mut writer = zip::ZipWriter::new(file);
    for (name, data) in entries {
        writer
            .start_file(
                *name,
                zip::write::SimpleFileOptions::default()
                    .compression_method(zip::CompressionMethod::Stored),
            )
            .unwrap();
        writer.write_all(data).unwrap();
    }
    writer.finish().unwrap();
    path
}
