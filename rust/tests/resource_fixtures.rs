//! Integration tests for Task 8: resources by reference + `@font-face`
//! hydration, driven by the committed synthetic mini-EPUBs in
//! `test/fixtures/epub/`.
//!
//! Contracts pinned here:
//! - a missing `<img>` entry never fails the book: the projection keeps a
//!   sized placeholder (`\u{FFFC}` + an `ImageRun` with `source_key: None`
//!   and unknown intrinsic size) instead of dropping the image or throwing;
//! - `read_resource` returns raw entry bytes by normalised key and errors on
//!   a missing entry (the Dart lazy loader treats the error as "skip");
//! - `embedded-font.epub` exposes its `@font-face` families with resolvable
//!   `src` keys whose bytes `read_resource` can materialise.
//!
//! `cargo test` runs with `rust/` as the working directory, so fixtures are
//! resolved via `CARGO_MANIFEST_DIR`.

use rust_lib_burrow::api::epub::{font_faces, open_epub, read_resource};
use rust_lib_burrow::epub::block::utf16_slice;
use rust_lib_burrow::epub::cascade::parse_styled_document;
use rust_lib_burrow::epub::container::EpubArchive;
use rust_lib_burrow::epub::opf::read_navigation_from;
use rust_lib_burrow::epub::project::{project_tree, ChapterDto};

fn fixture(name: &str) -> String {
    format!(
        "{}/../test/fixtures/epub/{name}",
        env!("CARGO_MANIFEST_DIR")
    )
}

/// Projects `doc` (a normalised archive key) of `epub` into a flat chapter.
fn project_fixture(epub: &str, doc: &str) -> ChapterDto {
    let archive = EpubArchive::open(&fixture(epub)).unwrap();
    let navigation = read_navigation_from(&archive).unwrap();
    let tree = parse_styled_document(&archive, &navigation.manifest, doc).unwrap();
    project_tree(&tree, String::new(), &archive, doc, &navigation.cover_hrefs)
}

#[test]
fn missing_image_entry_yields_sized_placeholder() {
    let ch = project_fixture("missing-image.epub", "oebps/ch1.xhtml");
    // The book parses: body text around the missing image survives.
    assert!(ch.body.contains("Before"));
    assert!(ch.body.contains("after"));
    // The missing `<img>` keeps exactly one placeholder with a sized
    // (empty-bytes) image run rather than failing the book.
    assert_eq!(ch.images.len(), 1);
    let image = &ch.images[0];
    assert_eq!(image.source_key, None);
    assert_eq!((image.intrinsic_w, image.intrinsic_h), (0, 0));
    assert_eq!(
        utf16_slice(&ch.body, image.offset as usize, image.offset as usize + 1),
        "\u{FFFC}"
    );
}

#[test]
fn read_resource_returns_entry_bytes_by_key() {
    let handle = open_epub(fixture("projection.epub")).unwrap();
    let bytes = read_resource(&handle, "oebps/images/pic.png".to_string()).unwrap();
    assert!(!bytes.is_empty());
    // PNG magic: the bytes are the real entry, not a placeholder.
    assert_eq!(
        &bytes[..8],
        &[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]
    );
}

#[test]
fn read_resource_errors_for_a_missing_entry() {
    let handle = open_epub(fixture("missing-image.epub")).unwrap();
    assert!(read_resource(&handle, "oebps/images/ghost.png".to_string()).is_err());
}

#[test]
fn embedded_font_faces_expose_resolvable_src_keys() {
    let handle = open_epub(fixture("embedded-font.epub")).unwrap();
    let faces = font_faces(&handle).unwrap();
    assert_eq!(faces.len(), 1);
    assert_eq!(faces[0].family, "Burrow Serif");
    // The `src` is a normalised archive key whose bytes hydrate on demand.
    let bytes = read_resource(&handle, faces[0].src.clone()).unwrap();
    assert!(!bytes.is_empty());
}
