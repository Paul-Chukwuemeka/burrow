//! FFI surface for the Rust EPUB engine.

use crate::epub::container::EpubArchive;
use crate::epub::model::MetadataDto;
use crate::epub::opf;

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
    // Retained for Tasks 4-8 (manifest/spine/TOC and resource reads).
    #[allow(dead_code)]
    archive: EpubArchive,
    metadata: MetadataDto,
}

/// Opens an EPUB and extracts its metadata, returning an opaque handle.
///
/// Errors are stringified for Dart (FRB maps `Err` to a thrown exception).
pub fn open_epub(path: String) -> Result<DocumentHandle, String> {
    let archive = EpubArchive::open(&path).map_err(|e| e.to_string())?;
    let metadata = opf::read_metadata_from(&archive).map_err(|e| e.to_string())?;
    Ok(DocumentHandle { archive, metadata })
}

/// Returns the metadata captured when the handle was opened.
pub fn metadata(handle: &DocumentHandle) -> Result<MetadataDto, String> {
    Ok(handle.metadata.clone())
}

/// Opens `path` and extracts metadata without keeping a handle (parity helper).
pub fn read_metadata(path: String) -> Result<MetadataDto, String> {
    opf::read_metadata(&path).map_err(|e| e.to_string())
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
