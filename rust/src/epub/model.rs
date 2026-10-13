//! Shared types for the Rust EPUB engine.
//!
//! The DTOs here are the FFI surface (see `crate::api::epub`). Their fields
//! correspond one-to-one with `ParsedMetadata` in
//! `lib/services/document_parser.dart`, so the Dart adapter can map them
//! without loss and Task 10 can compare the two engines field by field.

use std::fmt;

/// Errors raised while opening or parsing an EPUB container/OPF.
///
/// Deliberately coarse: the FFI layer stringifies these and Dart treats any
/// failure as an unreadable book. The variants exist so tests can assert on
/// the *kind* of failure and so log messages stay useful.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EpubError {
    /// The file could not be opened or read.
    Io(String),
    /// A size cap (compressed or decompressed) was exceeded.
    TooLarge(String),
    /// The bytes are not a structurally valid EPUB.
    Invalid(String),
}

impl fmt::Display for EpubError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            EpubError::Io(m) => write!(f, "{m}"),
            EpubError::TooLarge(m) => write!(f, "{m}"),
            EpubError::Invalid(m) => write!(f, "{m}"),
        }
    }
}

impl std::error::Error for EpubError {}

/// Metadata extracted from an OPF package document.
///
/// Mirrors the non-comic fields of `ParsedMetadata` (Dart). `cover_bytes`
/// carries the raw cover image (the Dart adapter downscales it later), and
/// `font_faces` is populated once the CSS cascade lands (Task 6); it is empty
/// during Task 3.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct MetadataDto {
    pub title: String,
    pub author: String,
    pub description: Option<String>,
    pub publisher: Option<String>,
    pub isbn: Option<String>,
    pub language: Option<String>,
    pub publication_date: Option<String>,
    pub rights: Option<String>,
    pub genre: Option<String>,
    pub series_name: Option<String>,
    pub series_index: Option<f64>,
    pub cover_bytes: Option<Vec<u8>>,
    pub font_faces: Vec<FontFaceDto>,
}

/// One `@font-face` the book declares.
///
/// Fields mirror `FontFaceInfo` (Dart). `bytes` is intentionally absent for
/// now: fonts are resolved lazily by `key` in a later task (spec D15), so the
/// DTO only carries family and source.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct FontFaceDto {
    pub family: String,
    pub src: String,
}
