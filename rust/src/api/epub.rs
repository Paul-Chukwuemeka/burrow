//! FFI surface for the Rust EPUB engine.

use crate::epub::cascade;
use crate::epub::comic::{self, ParsedComicDto};
use crate::epub::container::EpubArchive;
use crate::epub::model::{BlockTree, FontFaceDto, MetadataDto, TocEntryDto};
use crate::epub::nav;
use crate::epub::opf::{self, Navigation};
use crate::epub::project::{self, ChapterDto};
use crate::epub::{pdf, txt};

use std::sync::Mutex;

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
    /// The flattened chapter list (one chapter per TOC anchor), computed on
    /// first use. Every chapter read goes through it so `chapter`,
    /// `chapter_titles` and `chapter_count` can never disagree.
    flat: Mutex<Option<Vec<ChapterDto>>>,
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
        flat: Mutex::new(None),
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

/// Returns the chapter titles in reading order (one per TOC anchor).
pub fn chapter_titles(handle: &DocumentHandle) -> Result<Vec<String>, String> {
    Ok(flat_chapters(handle)?
        .into_iter()
        .map(|chapter| chapter.title)
        .collect())
}

/// Returns the number of chapters (one per TOC anchor, not per spine file).
pub fn chapter_count(handle: &DocumentHandle) -> Result<u32, String> {
    Ok(flat_chapters(handle)?.len() as u32)
}

/// Opens `path` and extracts metadata without keeping a handle (parity helper).
pub fn read_metadata(path: String) -> Result<MetadataDto, String> {
    opf::read_metadata(&path).map_err(|e| e.to_string())
}

/// Extracts TXT metadata without parsing chapters (the TXT leg of non-EPUB
/// metadata parity).
///
/// Ports `_extractMetadataIsolate`'s TXT branch: filename-derived title, empty
/// author, no cover — the file itself is never read.
pub fn extract_metadata_txt(path: String) -> Result<MetadataDto, String> {
    txt::extract_metadata_txt(&path)
}

/// Extracts CBZ metadata without parsing pages (the CBZ leg of non-EPUB
/// metadata parity).
///
/// Ports `DocumentParser._extractCbzMetadata`: only the first (natural-sorted)
/// page's bytes cross as the cover; the Dart adapter downscales it, exactly
/// like the Dart metadata path. Error strings match Dart's `FormatException`
/// messages verbatim so the Dart adapter can translate them back.
pub fn extract_metadata_cbz(path: String) -> Result<MetadataDto, String> {
    comic::extract_metadata_cbz(&path)
}

/// Extracts CBR metadata without touching the archive (the CBR leg of
/// non-EPUB metadata parity).
///
/// Ports `_extractMetadataIsolate`'s CBR branch: filename-derived title plus
/// the inferred series, with the cover deferred (null) exactly like Dart.
pub fn extract_metadata_cbr(path: String) -> Result<MetadataDto, String> {
    comic::extract_metadata_cbr(&path)
}

/// Extracts PDF metadata without reading the file (the PDF leg of non-EPUB
/// metadata parity).
///
/// Ports `_extractMetadataIsolate`'s PDF branch: filename-derived title,
/// empty author, no cover.
pub fn extract_metadata_pdf(path: String) -> Result<MetadataDto, String> {
    pdf::extract_metadata_pdf(&path)
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

/// Reads one archive entry's bytes by reference (spec D15).
///
/// `key` is a normalised archive key — an `ImageRunDto::source_key` or a
/// `FontFaceDto::src` — so image/font bytes cross the FFI on demand instead
/// of at parse time. Errors when the entry is absent; the Dart lazy loader
/// treats that as "skip" (a sized placeholder / skipped font), never as a
/// failed book.
pub fn read_resource(handle: &DocumentHandle, key: String) -> Result<Vec<u8>, String> {
    handle
        .archive
        .read_resource(&key)
        .ok_or_else(|| format!("Resource not found: {key}"))
}

/// Projects one chapter into today's flat-run model (spec D4/D6).
///
/// `index` is the flattened chapter order: every spine document contributes
/// one chapter per TOC anchor (in document order), mirroring Dart's
/// `splitByAnchors`. The projected `body` carries one `\u{FFFC}` per image,
/// every run/image offset is a Dart UTF-16 code unit, `%` box lengths stay
/// symbolic, and no resource bytes cross the boundary
/// (`ImageRunDto::source_key` is the reference Task 8 hydrates). A chapter
/// whose TOC entry has no fragment keeps the document's first TOC title (or
/// its own `<title>`/`<h1>` when the book has no TOC entry for it), and a
/// leading body line repeating the title is dropped.
///
/// Only the requested chapter is cloned out of the cached flat list: the
/// whole book is projected once, then each `chapter` call is O(1) under one
/// lock acquisition (previously every call re-cloned every chapter).
pub fn chapter(handle: &DocumentHandle, index: u32) -> Result<ChapterDto, String> {
    let mut guard = handle.flat.lock().map_err(|e| e.to_string())?;
    if guard.is_none() {
        *guard = Some(build_flat(handle)?);
    }
    guard
        .as_ref()
        .and_then(|flat| flat.get(index as usize).cloned())
        .ok_or_else(|| format!("Chapter index out of range: {index}"))
}

/// Drops the Rust side of an opened EPUB early.
///
/// Dart calls this in a `try/finally` around `parse`/hydration so a failed or
/// abandoned open never waits on GC finalizers to release the inflated
/// archive. Taking the handle by value is what runs the destructor.
pub fn close_document(handle: DocumentHandle) {
    drop(handle);
}

/// Parses a plain-text book into flat chapters (the TXT half of retiring the
/// Dart engine).
///
/// Decoding is UTF-8 with a Latin-1 fallback when replacement chars dominate,
/// and chapters follow `chapterizeTxt` (heading regex + 3-blank-line runs).
/// Chapters carry no runs or images; the filename-derived title is applied
/// Dart-side, matching `DocumentParser._parseTxt`.
pub fn parse_txt(path: String) -> Result<Vec<ChapterDto>, String> {
    txt::parse_txt(&path)
}

/// Parses a CBZ comic into natural-sorted pages plus the cover (the CBZ half
/// of retiring the Dart engine).
///
/// Each image entry becomes one page (title, raw entry name, bytes, intrinsic
/// size); the cover is the first page's bytes, un-downscaled exactly like
/// `DocumentParser._parseComicBook`. Error strings match that method's
/// `FormatException` messages verbatim so the Dart adapter can translate them
/// back. Unlike the EPUB path there is no handle: page bytes cross by value
/// because comics have no OPF for on-demand hydration.
pub fn parse_cbz(path: String) -> Result<ParsedComicDto, String> {
    comic::parse_cbz(&path)
}

/// Parses a CBR comic into natural-sorted pages plus the cover (the CBR half
/// of retiring the Dart engine).
///
/// Listing and extraction run through the `rars` crate in Rust; the Dart
/// `rar` plugin is never touched from this path. Otherwise identical to
/// [`parse_cbz`]: one page per image entry, first page's bytes as the cover,
/// Dart-verbatim error strings, bytes by value (no handle).
pub fn parse_cbr(path: String) -> Result<ParsedComicDto, String> {
    comic::parse_cbr(&path)
}

/// Returns the PDF stub both engines share (the PDF leg of retiring the
/// Dart engine).
///
/// PDF is never reflowed here — rendering stays in `pdfrx`. The Dart
/// isolate's PDF branch returns an empty-chapter stub without reading the
/// file (filename title applied Dart-side, empty author, one `Chapter('',
/// '')`, no cover bytes), so this port does no validation either: any
/// `.pdf` path yields the same single empty chapter, keeping the two
/// engines byte-identical by construction.
pub fn parse_pdf(path: String) -> Result<Vec<ChapterDto>, String> {
    pdf::parse_pdf(&path)
}

/// The flattened chapter list: every spine document in reading order, each
/// split at its TOC anchors (Dart's `splitByAnchors` + `_stripDuplicateHeading`
/// semantics). Computed once and cached on the handle.
fn flat_chapters(handle: &DocumentHandle) -> Result<Vec<ChapterDto>, String> {
    if let Some(cached) = handle.flat.lock().map_err(|e| e.to_string())?.clone() {
        return Ok(cached);
    }
    let out = build_flat(handle)?;
    let result = out.clone();
    *handle.flat.lock().map_err(|e| e.to_string())? = Some(out);
    Ok(result)
}

/// Projects every spine document; the uncached worker behind [`flat_chapters`]
/// and [`chapter`]. Takes no lock itself: [`chapter`] calls it while holding
/// `handle.flat`'s lock, [`flat_chapters`] without holding it.
fn build_flat(handle: &DocumentHandle) -> Result<Vec<ChapterDto>, String> {
    let mut docs = Vec::new();
    for key in &handle.navigation.spine {
        let entries: Vec<project::SplitEntry> = handle
            .navigation
            .toc
            .iter()
            .filter(|entry| entry.file_key == *key)
            .map(|entry| project::SplitEntry {
                fragment: entry.fragment.clone(),
                title: entry.title.clone(),
            })
            .collect();
        let fallback = chapter_title_for(handle, key);
        let tree =
            cascade::parse_styled_document(&handle.archive, &handle.navigation.manifest, key)
                .map_err(|e| e.to_string())?;
        docs.push(project::project_split_ext(
            &tree,
            fallback,
            key,
            &entries,
            &handle.archive,
            &handle.navigation.cover_hrefs,
        ));
    }
    Ok(project::resolve_split_links(docs))
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
