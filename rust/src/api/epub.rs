//! FFI surface for the Rust EPUB engine.

use crate::epub::cascade;
use crate::epub::container::EpubArchive;
use crate::epub::model::{BlockTree, FontFaceDto, MetadataDto, TocEntryDto};
use crate::epub::nav;
use crate::epub::opf::{self, Navigation};
use crate::epub::project::{self, ChapterDto};

/// Smoke-test entry point for the Burrow EPUB engine Rust backend.
///
/// Returns the crate version so Dart can verify the FFI bridge is wired up.
/// `frb(sync)` makes the generated Dart binding a plain `String engineVersion()`
/// (the version is a cheap constant, so there is no reason to hop isolates).
#[flutter_rust_bridge::frb(sync)]
pub fn engine_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

/// Opaque, Rust-owned handle to an opened EPUB (spec D15).
///
/// The ZIP stays on the Rust side so later tasks can read chapters, fonts and
/// images by reference without re-opening or re-shipping the archive. Dart only
/// ever holds the handle.
#[flutter_rust_bridge::frb(opaque)]
pub struct DocumentHandle {
    archive: EpubArchive,
    metadata: MetadataDto,
    navigation: Navigation,
}

/// Opens an EPUB, extracts its metadata, and resolves manifest/spine/TOC,
/// returning an opaque handle.
///
/// Errors are stringified for Dart (FRB maps `Err` to a thrown exception).
pub fn open_epub(path: String) -> Result<DocumentHandle, String> {
    let archive = EpubArchive::open(&path).map_err(|e| e.to_string())?;
    let metadata = opf::read_metadata_from(&archive).map_err(|e| e.to_string())?;
    let navigation = opf::read_navigation_from(&archive).map_err(|e| e.to_string())?;
    Ok(DocumentHandle {
        archive,
        metadata,
        navigation,
    })
}

/// Returns the metadata captured when the handle was opened.
pub fn metadata(handle: &DocumentHandle) -> Result<MetadataDto, String> {
    Ok(handle.metadata.clone())
}

/// Returns the table of contents in document order.
pub fn toc(handle: &DocumentHandle) -> Result<Vec<TocEntryDto>, String> {
    Ok(handle.navigation.toc.clone())
}

/// Returns the spine documents in reading order (normalised archive keys).
pub fn spine(handle: &DocumentHandle) -> Result<Vec<String>, String> {
    Ok(handle.navigation.spine.clone())
}

/// Returns the chapter titles in reading order.
pub fn chapter_titles(handle: &DocumentHandle) -> Result<Vec<String>, String> {
    Ok(opf::chapter_titles(&handle.archive, &handle.navigation))
}

/// Returns the number of chapters in the spine.
pub fn chapter_count(handle: &DocumentHandle) -> Result<u32, String> {
    Ok(chapter_titles(handle)?.len() as u32)
}

/// Opens `path` and extracts metadata without keeping a handle (parity helper).
pub fn read_metadata(path: String) -> Result<MetadataDto, String> {
    opf::read_metadata(&path).map_err(|e| e.to_string())
}

/// Parses one chapter into a structured block tree with computed styles.
///
/// `chapter_key` is a spine href (relative to the OPF directory) or an
/// already-normalised archive key; resolution is percent-decoding and
/// case-insensitive. Every node's `text_range` is in Dart UTF-16 code units,
/// and every node's `style` carries the resolved cascade (Task 6): author
/// rules, presentational hints and inline styles layered over the UA defaults,
/// with inheritance applied.
pub fn block_tree(handle: &DocumentHandle, chapter_key: String) -> Result<BlockTree, String> {
    cascade::parse_styled_document(&handle.archive, &handle.navigation.manifest, &chapter_key)
        .map_err(|e| e.to_string())
}

/// The book's `@font-face` families, extracted when the handle was opened.
pub fn font_faces(handle: &DocumentHandle) -> Result<Vec<FontFaceDto>, String> {
    Ok(handle.metadata.font_faces.clone())
}

/// Projects one spine chapter into today's flat-run model (spec D4/D6).
///
/// `index` is the spine reading order, as returned by [`spine`]. The projected
/// `body` carries one `\u{FFFC}` per image, every run/image offset is a Dart
/// UTF-16 code unit, `%` box lengths stay symbolic, and no resource bytes cross
/// the boundary (`ImageRunDto::source_key` is the reference Task 8 hydrates).
/// The chapter's title comes from its first TOC entry, falling back to the
/// document's own `<title>`/`<h1>`.
pub fn chapter(handle: &DocumentHandle, index: u32) -> Result<ChapterDto, String> {
    let key = handle
        .navigation
        .spine
        .get(index as usize)
        .cloned()
        .ok_or_else(|| format!("Chapter index out of range: {index}"))?;
    let title = chapter_title_for(handle, &key);
    let tree = cascade::parse_styled_document(&handle.archive, &handle.navigation.manifest, &key)
        .map_err(|e| e.to_string())?;
    Ok(project::project_tree(&tree, title, &handle.archive, &key))
}

/// The title for one spine document: its first TOC entry's title, else the
/// document's own `<title>`/`<h1>` (matching [`chapter_titles`] for the common
/// single-entry document).
fn chapter_title_for(handle: &DocumentHandle, key: &str) -> String {
    if let Some(entry) = handle.navigation.toc.iter().find(|e| e.file_key == key) {
        return entry.title.clone();
    }
    handle
        .archive
        .read_by_key(key)
        .and_then(|bytes| nav::document_title(&String::from_utf8_lossy(&bytes)))
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn engine_version_is_non_empty() {
        assert!(!engine_version().is_empty());
    }

    #[test]
    fn engine_version_matches_cargo_pkg_version() {
        assert_eq!(engine_version(), env!("CARGO_PKG_VERSION"));
    }
}
