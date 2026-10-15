//! PDF stub parsing: the empty-chapter contract both engines share.
//!
//! PDF is never reflowed by either engine — rendering stays in `pdfrx`. The
//! Dart isolate's PDF branch (`DocumentParser._parseIsolate`, the `pdf` case
//! in `lib/services/document_parser.dart`) returns a stub without touching
//! the file: filename-derived title (applied Dart-side), empty author, one
//! `Chapter('', '')`, no cover bytes (the cover renders via `pdf_cover.dart`).
//! Metadata is the same shape (`_extractMetadataIsolate`: filename title,
//! empty author). This module ports that stub so `BookFormat.pdf` can route
//! to the Rust engine with byte-identical output.
//!
//! Deliberately no validation: Dart accepts any `.pdf` path (even a missing
//! file) and still returns the stub, so checking magic bytes or existence
//! here would *diverge* from the contract this port pins.

use crate::epub::project::ChapterDto;
use crate::epub::{filename, model::MetadataDto};

/// Returns the PDF stub: a single empty, untitled chapter.
///
/// `path` is accepted (and ignored) for API symmetry with [`parse_txt`](
/// crate::epub::txt::parse_txt): the filename-derived title is applied
/// Dart-side, exactly like the TXT port. Infallible in practice — kept as a
/// `Result` so the FFI shape matches the other `parse_*` entries.
pub fn parse_pdf(path: &str) -> Result<Vec<ChapterDto>, String> {
    let _ = path;
    Ok(vec![ChapterDto::default()])
}

/// Extracts PDF metadata (the `extract_metadata_pdf` behind the FFI).
///
/// Mirrors `_extractMetadataIsolate`'s PDF branch
/// (`lib/services/document_parser.dart`): the file is never read — the title
/// is filename-derived, the author empty, and there is no cover (it renders
/// via `pdf_cover.dart`). Infallible in practice, kept as a `Result` so the
/// FFI shape matches the other `extract_metadata_*` entries.
pub fn extract_metadata_pdf(path: &str) -> Result<MetadataDto, String> {
    Ok(MetadataDto {
        title: filename::title_from_filename(path),
        ..Default::default()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stub_is_a_single_empty_chapter() {
        let chapters = parse_pdf("whatever.pdf").expect("stub never fails");
        assert_eq!(chapters.len(), 1);
        assert_eq!(chapters[0].title, "");
        assert_eq!(chapters[0].body, "");
        assert!(chapters[0].runs.is_empty());
        assert!(chapters[0].images.is_empty());
    }

    #[test]
    fn stub_ignores_the_path_like_dart() {
        // Dart's pdf branch never reads the file, so neither do we: even a
        // missing file yields the stub rather than an error.
        let chapters = parse_pdf("/does/not/exist.pdf").expect("stub never fails");
        assert_eq!(chapters.len(), 1);
    }
}
