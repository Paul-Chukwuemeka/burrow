//! Integration tests for the CBZ comic parser (`rust/src/epub/comic.rs`),
//! driven by the committed synthetic fixture `test/fixtures/epub/mini.cbz`.
//!
//! These pin the Dart-engine port contract (`DocumentParser._parseComicBook`,
//! CBZ branch):
//! - only image entries become pages (`.txt` is filtered out);
//! - pages are natural-sorted (`page1, page2, page10`, not archive order);
//! - per-page intrinsic dimensions come from the image headers;
//! - the cover is the first page's bytes;
//! - corrupt/empty archives fail with the Dart engine's messages verbatim.
//!
//! `cargo test` runs with `rust/` as the working directory, so fixtures are
//! resolved via `CARGO_MANIFEST_DIR`.

use rust_lib_burrow::epub::comic::{
    decode_image_dimensions, is_image_entry, parse_cbz,
};
use std::io::Write;
use std::sync::atomic::{AtomicU64, Ordering};

fn fixture(name: &str) -> String {
    format!("{}/../test/fixtures/epub/{name}", env!("CARGO_MANIFEST_DIR"))
}

static COUNTER: AtomicU64 = AtomicU64::new(0);

/// A temp file deleted on drop, for the error tests.
struct TempFile(std::path::PathBuf);

impl TempFile {
    fn new(suffix: &str) -> Self {
        let id = COUNTER.fetch_add(1, Ordering::SeqCst);
        Self(
            std::env::temp_dir()
                .join(format!("burrow-comic-test-{}-{}{suffix}", std::process::id(), id)),
        )
    }

    fn path_str(&self) -> &str {
        self.0.to_str().unwrap()
    }
}

impl Drop for TempFile {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

/// Writes a stored (uncompressed) ZIP to a temp path for the error tests.
fn write_zip(entries: &[(&str, &[u8])]) -> TempFile {
    let tmp = TempFile::new(".zip");
    let file = std::fs::File::create(&tmp.0).unwrap();
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
    tmp
}

#[test]
fn mini_cbz_pages_are_natural_sorted_with_dimensions() {
    let parsed = parse_cbz(&fixture("mini.cbz")).unwrap();
    let names: Vec<&str> = parsed
        .pages
        .iter()
        .map(|p| p.entry_name.as_str())
        .collect();
    // Archive order is page10, notes.txt, page2, page1: only a natural sort
    // yields page1 < page2 < page10 (Review Focus #3).
    assert_eq!(names, vec!["page1.png", "page2.png", "page10.png"]);
    assert_eq!(
        parsed
            .pages
            .iter()
            .map(|p| p.title.as_str())
            .collect::<Vec<_>>(),
        vec!["page1", "page2", "page10"]
    );
    assert_eq!(
        parsed
            .pages
            .iter()
            .map(|p| (p.width, p.height))
            .collect::<Vec<_>>(),
        vec![(4, 4), (8, 6), (6, 8)]
    );
    for page in &parsed.pages {
        assert!(!page.image_bytes.is_empty());
    }
}

#[test]
fn mini_cbz_cover_is_the_first_page() {
    let parsed = parse_cbz(&fixture("mini.cbz")).unwrap();
    assert_eq!(parsed.cover_bytes, parsed.pages[0].image_bytes);
}

#[test]
fn image_entry_filter_matches_dart_extensions() {
    for ext in ["jpg", "jpeg", "png", "gif", "webp", "bmp"] {
        assert!(is_image_entry(&format!("page.{ext}")), ".{ext}");
        assert!(
            is_image_entry(&format!("page.{ext}", ext = ext.to_uppercase())),
            "upper .{ext}"
        );
    }
    for name in ["notes.txt", "pic.svg", "pic.tiff", "noext", "jpg"] {
        assert!(!is_image_entry(name), "{name}");
    }
}

#[test]
fn image_dimensions_from_headers() {
    // PNG: width at 16, height at 20 (big-endian).
    let mut png = vec![0u8; 24];
    png[0..4].copy_from_slice(&[0x89, 0x50, 0x4E, 0x47]);
    png[16..20].copy_from_slice(&[0, 0, 0, 8]);
    png[20..24].copy_from_slice(&[0, 0, 0, 6]);
    assert_eq!(decode_image_dimensions(&png), (8, 6));
    // GIF: little-endian uint16 at 6/8.
    let gif = [0x47, 0x49, 0x46, 0, 0, 0, 8, 0, 6, 0];
    assert_eq!(decode_image_dimensions(&gif), (8, 6));
    // Garbage is unknown, never an error.
    assert_eq!(decode_image_dimensions(b"not an image"), (0, 0));
    assert_eq!(decode_image_dimensions(&[]), (0, 0));
}

#[test]
fn missing_file_is_not_a_valid_cbz() {
    let err = parse_cbz("/nonexistent-burrow-dir/missing.cbz").unwrap_err();
    assert_eq!(err, "Not a valid CBZ file");
}

#[test]
fn garbage_bytes_are_not_a_valid_cbz_archive() {
    let tmp = TempFile::new(".cbz");
    std::fs::write(&tmp.0, b"this is not a zip").unwrap();
    let err = parse_cbz(tmp.path_str()).unwrap_err();
    assert_eq!(err, "Not a valid CBZ/ZIP archive");
}

#[test]
fn archive_without_images_is_rejected_like_dart() {
    let tmp = write_zip(&[("notes.txt", b"no pages here")]);
    let err = parse_cbz(tmp.path_str()).unwrap_err();
    assert_eq!(err, "No images found in comic archive");
}
