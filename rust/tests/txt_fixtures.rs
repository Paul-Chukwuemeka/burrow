//! Integration tests for the TXT parser (`rust/src/epub/txt.rs`), driven by the
//! committed synthetic fixtures in `test/fixtures/epub/*.txt`.
//!
//! These pin the Dart-engine port contract:
//! - UTF-8 decodes as-is; Latin-1 bytes fall back to a Latin-1 decode when
//!   replacement chars dominate (byte-identical to Dart's `latin1.decode`,
//!   including the BOM bytes decoded as `ï»¿`);
//! - a lone BOM counts as blank (Dart trims U+FEFF; Rust's `trim` does not,
//!   so the port trims it explicitly);
//! - chapter splits follow `chapterizeTxt` exactly (heading regex +
//!   3-blank-line runs, duplicate-heading strip).
//!
//! `cargo test` runs with `rust/` as the working directory, so fixtures are
//! resolved via `CARGO_MANIFEST_DIR`.

use rust_lib_burrow::epub::txt::{decode_txt, parse_txt, parse_txt_bytes};

fn fixture(name: &str) -> String {
    format!("{}/../test/fixtures/epub/{name}", env!("CARGO_MANIFEST_DIR"))
}

#[test]
fn plain_txt_is_a_single_untitled_chapter() {
    let chapters = parse_txt(&fixture("plain.txt")).unwrap();
    assert_eq!(chapters.len(), 1);
    assert_eq!(chapters[0].title, "");
    assert_eq!(
        chapters[0].body,
        "The burrow was quiet in the morning.\n\nA second paragraph follows here, plain and simple.\n"
    );
    assert!(chapters[0].runs.is_empty());
    assert!(chapters[0].images.is_empty());
}

#[test]
fn chapters_txt_splits_on_headings_and_blank_runs() {
    let chapters = parse_txt(&fixture("chapters.txt")).unwrap();
    assert_eq!(
        chapters
            .iter()
            .map(|c| c.title.as_str())
            .collect::<Vec<_>>(),
        vec![
            "Chapter 1: The Beginning",
            "Chapter 2: The Middle",
            "PART II"
        ]
    );
    assert_eq!(
        chapters[0].body,
        "Once upon a time in the burrow.\n\nMore of the first chapter."
    );
    assert_eq!(chapters[1].body, "Something happened in the middle.");
    assert_eq!(chapters[2].body, "The second part begins here.");
}

#[test]
fn latin1_fixture_falls_back_from_utf8() {
    let chapters = parse_txt(&fixture("latin1-bom.txt")).unwrap();
    assert_eq!(chapters.len(), 1);
    assert_eq!(chapters[0].title, "");
    // The Latin-1 fallback decodes the BOM bytes as Latin-1 (`ï»¿`) instead of
    // stripping them — byte-identical to the Dart engine's `latin1.decode`.
    assert_eq!(
        chapters[0].body,
        "ï»¿Café crème brûlée.\n\nNaïve notes from the burrow.\n"
    );
}

#[test]
fn decode_prefers_utf8_for_valid_text() {
    assert_eq!(decode_txt("plain ascii".as_bytes()), "plain ascii");
    assert_eq!(decode_txt("emoji \u{1F600}".as_bytes()), "emoji \u{1F600}");
}

#[test]
fn blank_and_bom_only_inputs_are_rejected_like_dart() {
    assert_eq!(parse_txt_bytes(b"").unwrap_err(), "File is empty");
    assert_eq!(parse_txt_bytes(b"   \n  ").unwrap_err(), "File is empty");
    // A lone BOM: Dart's `trim()` strips U+FEFF, so this is "empty" there too.
    assert_eq!(
        parse_txt_bytes(b"\xef\xbb\xbf").unwrap_err(),
        "File is empty"
    );
}

#[test]
fn missing_file_is_an_io_error_not_a_format_error() {
    let err = parse_txt("/nonexistent-burrow-dir/missing.txt").unwrap_err();
    assert!(
        err.starts_with("Cannot open text file:"),
        "unexpected error: {err}"
    );
}
