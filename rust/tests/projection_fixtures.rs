//! Integration tests for the Task 7 flat-run projection, driven by the
//! committed synthetic mini-EPUBs in `test/fixtures/epub/`.
//!
//! These pin the Phase-A contract on the Rust side:
//! - every `<img>` becomes exactly one `\u{FFFC}` placeholder, so the body's
//!   placeholder count equals the image count (Review Focus #5's precursor);
//! - run and image offsets are Dart UTF-16 code units, so a non-BMP emoji does
//!   not shift them (Review Focus #1);
//! - `%` box lengths stay symbolic;
//! - only author-declared CSS becomes a run (an unstyled book stays style-free).
//!
//! `cargo test` runs with `rust/` as the working directory, so fixtures are
//! resolved via `CARGO_MANIFEST_DIR`.

use rust_lib_burrow::epub::block::utf16_slice;
use rust_lib_burrow::epub::cascade::parse_styled_document;
use rust_lib_burrow::epub::container::EpubArchive;
use rust_lib_burrow::epub::opf::read_navigation_from;
use rust_lib_burrow::epub::project::{project_split, project_tree, ChapterDto, SplitEntry};

fn fixture(name: &str) -> String {
    format!(
        "{}/../test/fixtures/epub/{name}",
        env!("CARGO_MANIFEST_DIR")
    )
}

fn open(epub: &str) -> EpubArchive {
    EpubArchive::open(&fixture(epub)).unwrap()
}

/// Projects `doc` (a normalised archive key) of `epub` into a flat chapter.
fn project_fixture(epub: &str, doc: &str) -> ChapterDto {
    let archive = open(epub);
    let navigation = read_navigation_from(&archive).unwrap();
    let tree = parse_styled_document(&archive, &navigation.manifest, doc).unwrap();
    project_tree(&tree, String::new(), &archive, doc)
}

#[test]
fn image_becomes_ufffc_placeholder_with_offset() {
    let ch = project_fixture("projection.epub", "oebps/ch1.xhtml");
    assert_eq!(
        ch.body.chars().filter(|c| *c == '\u{FFFC}').count(),
        ch.images.len()
    );
    assert!(ch.body.char_indices().any(|(_, c)| c == '\u{FFFC}'));
}

#[test]
fn image_run_carries_reference_intrinsic_size_and_symbolic_css() {
    let ch = project_fixture("projection.epub", "oebps/ch1.xhtml");
    assert_eq!(ch.images.len(), 1);
    let image = &ch.images[0];
    assert_eq!(image.source_key.as_deref(), Some("oebps/images/pic.png"));
    assert_eq!((image.intrinsic_w, image.intrinsic_h), (8, 4));
    assert_eq!(image.alt, "tiny");
    assert_eq!(image.html_w, Some(8.0));
    assert_eq!(image.html_h, Some(4.0));
    assert!(!image.full_width);
    assert_eq!(image.img_class, "wide");

    // The placeholder sits exactly at the image offset (UTF-16 coordinates).
    assert_eq!(
        utf16_slice(&ch.body, image.offset as usize, image.offset as usize + 1),
        "\u{FFFC}"
    );

    // `max-width: 100%` must stay symbolic, never resolved at parse time.
    let css = image.css.as_ref().expect("image sizing css");
    let max_width = css.max_width.expect("max-width");
    assert!(max_width.is_percent);
    assert_eq!(max_width.value, 100.0);
}

#[test]
fn non_bmp_run_offsets_index_the_body_as_dart_substring() {
    let ch = project_fixture("projection.epub", "oebps/ch1.xhtml");
    let run = ch.runs.iter().find(|r| r.italic).expect("italic run");
    // A UTF-16 slice, exactly as Dart `String.substring` would produce it.
    assert_eq!(
        utf16_slice(&ch.body, run.start as usize, run.end as usize),
        "emoji \u{1F600} run"
    );
}

#[test]
fn author_declared_css_becomes_a_run() {
    let ch = project_fixture("projection.epub", "oebps/ch1.xhtml");
    let run = ch
        .runs
        .iter()
        .find(|r| r.css.as_ref().is_some_and(|css| css.color.is_some()))
        .expect("styled note run");
    let css = run.css.as_ref().unwrap();
    assert_eq!(css.color, Some(0xFF33_6699));
    assert_eq!(css.font_size, Some(14.0));
    assert_eq!(
        utf16_slice(&ch.body, run.start as usize, run.end as usize),
        "Styled note."
    );
}

#[test]
fn blockquote_text_is_a_quote_run() {
    let ch = project_fixture("projection.epub", "oebps/ch1.xhtml");
    let run = ch.runs.iter().find(|r| r.quote).expect("quote run");
    assert_eq!(
        utf16_slice(&ch.body, run.start as usize, run.end as usize),
        "Quoted text."
    );
}

#[test]
fn body_matches_the_dart_whitespace_collapse() {
    let ch = project_fixture("projection.epub", "oebps/ch1.xhtml");
    assert_eq!(
        ch.body,
        "Projection\n\nIntro emoji \u{1F600} run tail\n\nStyled note.\n\nQuoted text.\n\n\u{FFFC}"
    );
}

#[test]
fn unstyled_book_emits_no_css_runs() {
    let ch = project_fixture("minimal.epub", "oebps/text/ch1.xhtml");
    assert_eq!(ch.body, "One\n\nThe first chapter.");
    assert!(ch.runs.iter().all(|run| run.css.is_none()));
    assert!(ch.images.is_empty());
    // The block tree is carried through additively (D17).
    assert!(!ch.blocks.is_empty());
}

#[test]
fn non_bmp_book_offsets_stay_aligned() {
    let ch = project_fixture("nonbmp.epub", "oebps/ch1.xhtml");
    // "A😀B" (4 UTF-16 units) then a blank line then the astral CJK paragraph.
    assert!(ch.body.starts_with("A\u{1F600}B"));
    assert!(ch.body.contains("\u{10348} tail"));
    assert!(ch.body.contains("a b c"));
}

/// Splits `doc` (a normalised archive key) of `epub` at its TOC anchors.
fn split_fixture(epub: &str, doc: &str) -> Vec<ChapterDto> {
    let archive = open(epub);
    let navigation = read_navigation_from(&archive).unwrap();
    let entries: Vec<SplitEntry> = navigation
        .toc
        .iter()
        .filter(|entry| entry.file_key == doc)
        .map(|entry| SplitEntry {
            fragment: entry.fragment.clone(),
            title: entry.title.clone(),
        })
        .collect();
    let tree = parse_styled_document(&archive, &navigation.manifest, doc).unwrap();
    project_split(&tree, String::new(), &entries, &archive, doc)
}

#[test]
fn anchor_split_yields_one_chapter_per_toc_fragment() {
    let chapters = split_fixture("anchor-split.epub", "oebps/text/all.xhtml");
    assert_eq!(
        chapters
            .iter()
            .map(|c| c.title.as_str())
            .collect::<Vec<_>>(),
        vec!["Part One", "Part Two", "Part Three"]
    );
    // Each in-body heading repeats its TOC title and is stripped.
    assert_eq!(chapters[0].body, "First body.\n\n");
    assert_eq!(chapters[1].body, "Second body with emphasis.\n\n");
    assert_eq!(chapters[2].body, "Third body \u{FFFC}");
}

#[test]
fn anchor_split_rebases_runs_and_images() {
    let chapters = split_fixture("anchor-split.epub", "oebps/text/all.xhtml");
    let run = chapters[1]
        .runs
        .iter()
        .find(|run| run.italic)
        .expect("italic run");
    assert_eq!(
        utf16_slice(&chapters[1].body, run.start as usize, run.end as usize),
        "emphasis"
    );
    assert_eq!(chapters[2].images.len(), 1);
    let image = &chapters[2].images[0];
    assert_eq!(image.source_key.as_deref(), Some("oebps/images/pic.png"));
    assert_eq!(
        utf16_slice(
            &chapters[2].body,
            image.offset as usize,
            image.offset as usize + 1
        ),
        "\u{FFFC}"
    );
}

#[test]
fn anchor_split_resolves_the_percent_encoded_fragment() {
    // The third TOC entry targets `#sec%202` while the anchor id is `sec 2`:
    // without the decode tolerance it would stay whole under one chapter.
    let chapters = split_fixture("anchor-split.epub", "oebps/text/all.xhtml");
    assert_eq!(chapters.len(), 3);
    assert_eq!(chapters[2].title, "Part Three");
}
