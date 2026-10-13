//! Integration tests for the OCF container + OPF metadata path, driven by the
//! committed synthetic mini-EPUBs in `test/fixtures/epub/`.
//!
//! `cargo test` runs with `rust/` as the working directory, so fixtures are
//! resolved via `CARGO_MANIFEST_DIR` rather than a bare relative path.

use rust_lib_burrow::epub::container::{container_rootfile, open};
use rust_lib_burrow::epub::opf::read_metadata;

fn fixture(name: &str) -> String {
    format!("{}/../test/fixtures/epub/{name}", env!("CARGO_MANIFEST_DIR"))
}

#[test]
fn reads_opf_path_from_container() {
    let z = open(&fixture("minimal.epub")).unwrap();
    assert_eq!(container_rootfile(&z).unwrap(), "OEBPS/content.opf");
}

#[test]
fn extracts_dublin_core_metadata() {
    let m = read_metadata(&fixture("minimal.epub")).unwrap();
    assert_eq!(m.title, "Minimal Book");
    assert_eq!(m.author, "A. Author");
}

#[test]
fn extracts_all_dublin_core_fields() {
    let m = read_metadata(&fixture("minimal.epub")).unwrap();
    assert_eq!(
        m.description.as_deref(),
        Some("A tiny synthetic book for Rust engine tests.")
    );
    assert_eq!(m.language.as_deref(), Some("en"));
    assert_eq!(m.publisher.as_deref(), Some("Burrow Test Press"));
    assert_eq!(m.publication_date.as_deref(), Some("2026-01-02"));
    assert_eq!(m.rights.as_deref(), Some("Public Domain"));
    assert_eq!(m.genre.as_deref(), Some("Fiction, Testing"));
    assert_eq!(m.isbn.as_deref(), Some("978-0-306-40615-7"));
    assert_eq!(m.series_name.as_deref(), Some("Burrow Chronicles"));
    assert_eq!(m.series_index, Some(2.0));
    assert!(m.font_faces.is_empty());
}

#[test]
fn extracts_cover_bytes() {
    let m = read_metadata(&fixture("minimal.epub")).unwrap();
    let cover = m.cover_bytes.expect("cover should resolve via meta name=cover");
    assert_eq!(&cover[..8], b"\x89PNG\r\n\x1a\n");
}

#[test]
fn percent_encoded_paths_do_not_throw() {
    let m = read_metadata(&fixture("percent-path.epub")).unwrap();
    assert_eq!(m.title, "Percent Paths");
    // `Images/Cover%20Art.png` decodes to a real entry and yields a PNG.
    let cover = m.cover_bytes.expect("percent-encoded cover should resolve");
    assert_eq!(&cover[..8], b"\x89PNG\r\n\x1a\n");
}

#[test]
fn read_href_resolves_case_insensitively() {
    let z = open(&fixture("minimal.epub")).unwrap();
    // Direct hit through the href — the `meta name="cover"` path, not the
    // `cover_fallback` filename scan.
    assert!(z.read_href("OEBPS", "Images/cover.png").is_some());
    // Directory AND file case differ from the stored entry (`OEBPS/Images/...`).
    assert!(z.read_href("oebps", "images/COVER.PNG").is_some());
    // `..` traversal still resolves after lowercasing.
    assert!(z.read_href("OEBPS/Text", "../Images/cover.png").is_some());
    // A genuinely absent entry must still miss.
    assert!(z.read_href("OEBPS", "Images/missing.png").is_none());
}

#[test]
fn percent_encoded_href_resolves_directly() {
    let z = open(&fixture("percent-path.epub")).unwrap();
    assert!(z.read_href("OEBPS", "Images/Cover%20Art.png").is_some());
    // A bare `%` in the href must not throw and must still match its entry.
    assert!(z.read_href("OEBPS", "Text/100%25_cover.xhtml").is_some());
}

#[test]
fn cover_resolves_via_meta_href_not_filename_scan() {
    // `front.png` contains no "cover", so `cover_fallback` cannot supply this
    // cover: it only passes if `meta name="cover"` -> manifest href resolves.
    let m = read_metadata(&fixture("opaque-cover.epub")).unwrap();
    let cover = m
        .cover_bytes
        .expect("cover must resolve through meta name=cover -> href");
    assert_eq!(&cover[..8], b"\x89PNG\r\n\x1a\n");
}

#[test]
fn rejects_non_epub_bytes() {
    use std::sync::atomic::{AtomicU32, Ordering};
    static SEQ: AtomicU32 = AtomicU32::new(0);
    let path = std::env::temp_dir().join(format!(
        "burrow-not-epub-{}-{}.epub",
        std::process::id(),
        SEQ.fetch_add(1, Ordering::Relaxed)
    ));
    std::fs::write(&path, b"this is not a zip archive").unwrap();
    let result = read_metadata(path.to_str().unwrap());
    let _ = std::fs::remove_file(&path);
    assert!(result.is_err());
}
