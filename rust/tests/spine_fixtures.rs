//! Integration tests for manifest resolution, spine order, and the table of
//! contents (EPUB3 nav + EPUB2 NCX), driven by the committed synthetic
//! mini-EPUBs in `test/fixtures/epub/`.
//!
//! `cargo test` runs with `rust/` as the working directory, so fixtures are
//! resolved via `CARGO_MANIFEST_DIR` rather than a bare relative path.

use rust_lib_burrow::api::epub::{chapter_count, chapter_titles, open_epub};
use rust_lib_burrow::epub::model::TocEntryDto;

fn fixture(name: &str) -> String {
    format!("{}/../test/fixtures/epub/{name}", env!("CARGO_MANIFEST_DIR"))
}

fn titles(name: &str) -> Vec<String> {
    let handle = open_epub(fixture(name)).unwrap();
    chapter_titles(&handle).unwrap()
}

#[test]
fn spine_order_matches_opf() {
    assert_eq!(titles("minimal.epub"), vec!["One", "Two"]);
}

#[test]
fn spine_falls_back_to_natural_order_without_itemrefs() {
    // No `<itemref>`s: the manifest's XHTML items are the chapter list, sorted
    // naturally (`ch2` before `ch10`), not in manifest order (`ch10` first).
    assert_eq!(titles("no-spine.epub"), vec!["Two", "Ten"]);
}

#[test]
fn spine_resolves_percent_encoded_and_case_insensitive_hrefs() {
    // `Text/100%25_cover.xhtml` -> `oebps/text/100%_cover.xhtml` and
    // `Text/CH2.XHTML` -> `oebps/text/ch2.xhtml`.
    assert_eq!(titles("percent-path.epub"), vec!["One", "Two"]);
}

#[test]
fn toc_falls_back_from_nav_to_ncx() {
    let nav = open_epub(fixture("nav.epub")).unwrap();
    assert_eq!(
        chapter_titles(&nav).unwrap(),
        vec!["1 One", "Two"],
        "EPUB3 nav document supplies the titles",
    );

    let ncx = open_epub(fixture("ncx.epub")).unwrap();
    assert_eq!(
        chapter_titles(&ncx).unwrap(),
        vec!["One", "Two"],
        "EPUB2 toc.ncx supplies the titles",
    );
}

#[test]
fn toc_entries_keep_normalized_path_and_raw_fragment() {
    let nav = open_epub(fixture("nav.epub")).unwrap();
    let toc = rust_lib_burrow::api::epub::toc(&nav).unwrap();
    assert_eq!(
        toc,
        vec![
            TocEntryDto {
                file_key: "oebps/text/ch1.xhtml".to_string(),
                fragment: None,
                // Mixed-content label (`<span>1</span> One`) keeps document
                // order rather than emitting the trailing text first.
                title: "1 One".to_string(),
            },
            TocEntryDto {
                file_key: "oebps/text/ch2.xhtml".to_string(),
                // The fragment is kept raw (not percent-decoded).
                fragment: Some("sec%202".to_string()),
                title: "Two".to_string(),
            },
        ],
    );
}

#[test]
fn chapter_count_matches_titles() {
    let handle = open_epub(fixture("nav.epub")).unwrap();
    assert_eq!(chapter_count(&handle).unwrap(), 2);
    assert_eq!(
        chapter_count(&handle).unwrap() as usize,
        chapter_titles(&handle).unwrap().len(),
    );
}
