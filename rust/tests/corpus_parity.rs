//! Corpus parity gate, Rust side (Task 9).
//!
//! The Dart side of the gate (`test/epub_engine/parity_test.dart` + the
//! divergence ledger) compares both engines fixture by fixture. This suite is
//! the Rust half: it opens every committed synthetic fixture in
//! `test/fixtures/epub/`, checks the structural invariants the Dart engine
//! relies on (one `\u{FFFC}` per image, UTF-16 offsets in range), and pins the
//! known-divergence behaviours the ledger classifies (nav-first TOC,
//! all-miss spine fallback, missing-image placeholder, SVG 0x0 intrinsics,
//! block-markup descriptions, OPF-cover inline `full_width`).
//!
//! `cargo test` runs with `rust/` as the working directory, so fixtures are
//! resolved via `CARGO_MANIFEST_DIR` rather than a bare relative path.

use rust_lib_burrow::api::epub::{chapter, chapter_count, metadata, open_epub};

/// Every committed synthetic fixture. `generate.py` is the source of truth;
///
/// this list must stay in sync with it.
fn corpus() -> Vec<&'static str> {
    vec![
        "anchor-split.epub",
        "cover-inline.epub",
        "dangling-spine.epub",
        "dual-toc.epub",
        "embedded-font.epub",
        "external-css.epub",
        "malformed.epub",
        "minimal.epub",
        "missing-image.epub",
        "nav.epub",
        "ncx.epub",
        "no-spine.epub",
        "nonbmp.epub",
        "opaque-cover.epub",
        "percent-path.epub",
        "projection.epub",
        "repeated-paragraphs.epub",
        "rich-meta.epub",
        "scripted.epub",
        "svg-image.epub",
    ]
}

fn fixture(name: &str) -> String {
    format!("{}/../test/fixtures/epub/{name}", env!("CARGO_MANIFEST_DIR"))
}

fn utf16_len(s: &str) -> u32 {
    s.encode_utf16().count() as u32
}

#[test]
fn every_fixture_opens_with_at_least_one_chapter() {
    for name in corpus() {
        let handle = open_epub(fixture(name)).unwrap_or_else(|e| panic!("{name}: {e}"));
        let count = chapter_count(&handle).unwrap();
        assert!(count >= 1, "{name}: expected chapters, got {count}");
    }
}

#[test]
fn placeholders_and_offsets_are_consistent() {
    // One `\u{FFFC}` per image, and every run/image offset inside the body in
    // Dart UTF-16 code units — the coordinates the Dart reader consumes.
    for name in corpus() {
        let handle = open_epub(fixture(name)).unwrap();
        let count = chapter_count(&handle).unwrap();
        for index in 0..count {
            let dto = chapter(&handle, index).unwrap();
            let body_len = utf16_len(&dto.body);
            assert_eq!(
                dto.body.chars().filter(|c| *c == '\u{FFFC}').count(),
                dto.images.len(),
                "{name} chapter {index}: placeholder/image count",
            );
            for run in &dto.runs {
                assert!(
                    run.start <= run.end && run.end <= body_len,
                    "{name} chapter {index}: run {}-{} outside body {body_len}",
                    run.start,
                    run.end,
                );
            }
            for image in &dto.images {
                assert!(
                    image.offset < body_len,
                    "{name} chapter {index}: image offset {} outside body {body_len}",
                    image.offset,
                );
            }
        }
    }
}

#[test]
fn dual_toc_prefers_the_epub3_nav_over_the_ncx() {
    // Ledger (accepted): Dart reads the NCX first, Rust the nav.
    let handle = open_epub(fixture("dual-toc.epub")).unwrap();
    let titles: Vec<String> = (0..chapter_count(&handle).unwrap())
        .map(|i| chapter(&handle, i).unwrap().title)
        .collect();
    assert_eq!(titles, vec!["Nav One", "Nav Two"]);
}

#[test]
fn dangling_spine_falls_back_to_natural_manifest_order() {
    // Ledger (accepted): every spine idref misses, so Dart throws "no readable
    // text" while Rust falls back to the natural-sorted manifest list.
    let handle = open_epub(fixture("dangling-spine.epub")).unwrap();
    let titles: Vec<String> = (0..chapter_count(&handle).unwrap())
        .map(|i| chapter(&handle, i).unwrap().title)
        .collect();
    assert_eq!(titles, vec!["One", "Two"]);
}

#[test]
fn missing_image_keeps_a_placeholder_without_a_source_key() {
    // Ledger (accepted): Dart drops the unresolvable `<img>`, Rust keeps a
    // sized placeholder with no source key.
    let handle = open_epub(fixture("missing-image.epub")).unwrap();
    let dto = chapter(&handle, 0).unwrap();
    assert_eq!(dto.images.len(), 1);
    let image = &dto.images[0];
    assert_eq!(image.source_key, None);
    assert_eq!((image.intrinsic_w, image.intrinsic_h), (0, 0));
}

#[test]
fn svg_image_keeps_a_placeholder_with_unknown_intrinsics() {
    // Ledger (accepted): Dart drops `.svg` `<img>` tags entirely, Rust keeps a
    // placeholder but reads 0x0 (no SVG viewBox sniffing yet).
    let handle = open_epub(fixture("svg-image.epub")).unwrap();
    let dto = chapter(&handle, 0).unwrap();
    assert_eq!(dto.images.len(), 1);
    let image = &dto.images[0];
    assert!(image.source_key.is_some());
    assert_eq!((image.intrinsic_w, image.intrinsic_h), (0, 0));
}

#[test]
fn rich_meta_description_keeps_paragraph_breaks() {
    // Fixed in this task (parity item 7): escaped block markup in the OPF
    // description keeps Dart's paragraph breaks instead of collapsing.
    let handle = open_epub(fixture("rich-meta.epub")).unwrap();
    let meta = metadata(&handle).unwrap();
    assert_eq!(
        meta.description.as_deref(),
        Some("First para.\n\nSecond para.")
    );
}

#[test]
fn opf_cover_inline_image_is_not_full_width() {
    // Ledger (bug): Dart marks this image full-width via the OPF `coverHrefs`;
    // Rust only matches id/filename "cover".
    let handle = open_epub(fixture("cover-inline.epub")).unwrap();
    let dto = chapter(&handle, 0).unwrap();
    assert_eq!(dto.images.len(), 1);
    assert!(!dto.images[0].full_width);
}
