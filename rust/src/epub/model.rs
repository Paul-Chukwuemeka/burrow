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

/// One table-of-contents entry, in document order.
///
/// Mirrors `TocEntry` in `lib/services/document_parser.dart`: `file_key` is the
/// *normalised* (percent-decoded, lowercased) archive path of the target
/// document without its fragment, and `fragment` is the raw (still
/// percent-encoded) anchor id, or `None` when the entry targets the whole
/// document. Several entries commonly point into one spine document via
/// different `#anchor`s; each is a chapter in its own right, so the fragment is
/// what tells them apart.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct TocEntryDto {
    pub file_key: String,
    pub fragment: Option<String>,
    pub title: String,
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

/// The structural role of a [`BlockNode`].
///
/// Deliberately small: the kinds the phase-1 flat projection and the future
/// paginator need to tell apart (D6/G3). Everything without a dedicated role —
/// inline markup (`span`, `em`, `a`, `code`, …) *and* generic block containers
/// (`div`, `section`, `figure`, …) — is [`BlockKind::Inline`]; its children are
/// preserved, so a `<div>` wrapping paragraphs is a transparent node rather
/// than a flattening point.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum BlockKind {
    /// The synthetic tree root (also the `<body>` container).
    #[default]
    Root,
    Paragraph,
    /// An `h1`–`h6`; the payload is the level (1–6).
    Heading(u8),
    /// A `ul`/`ol`/`menu`.
    List,
    /// An `li`.
    ListItem,
    Blockquote,
    Pre,
    /// An `img`. Carries no text; `attrs.src`/`alt`/`width`/`height` describe it.
    Image,
    /// Inline markup, or any element without a dedicated role (see the enum doc).
    Inline,
}

/// The attributes the block tree keeps for a node.
///
/// `tag` is the lowercased local element name (not an attribute), carried so a
/// later cascade can run selector matching (Task 6). The rest are the HTML
/// attributes the phase-1 model needs; `src`/`href` are kept **raw**, never
/// resolved or fetched (D9).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Attrs {
    pub tag: String,
    pub id: Option<String>,
    pub class: Option<String>,
    pub src: Option<String>,
    pub href: Option<String>,
    pub alt: Option<String>,
    pub width: Option<String>,
    pub height: Option<String>,
}

/// One node in the flat [`BlockTree`] arena.
///
/// `children` are indices into the arena (never recursive handles), so the tree
/// crosses the FFI as a flat `Vec`. `text_range` is a half-open range into
/// [`BlockTree::text`] measured in **Dart UTF-16 code units**, not Rust UTF-8
/// bytes (D4): a non-BMP char such as `\u{1F600}` counts as two.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct BlockNode {
    pub kind: BlockKind,
    pub text_range: (usize, usize),
    pub children: Vec<usize>,
    pub attrs: Attrs,
}

/// A chapter parsed into a structured block tree.
///
/// `nodes` is a flat arena whose first entry is always the [`BlockKind::Root`];
/// `text` is the chapter's visible text in document order, which `text_range`
/// offsets index. The tree preserves block structure (paragraphs, headings,
/// lists, blockquote, pre, images) instead of flattening to a body string (G3).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct BlockTree {
    pub nodes: Vec<BlockNode>,
    /// Chapter text, in document order, in UTF-16-indexable form.
    pub text: String,
    /// Network fetches performed while building the tree. Always `0`: the
    /// engine has no fetch capability (D9), and this field exists so the
    /// invariant is asserted, not assumed.
    pub remote_fetches: u32,
    /// Number of `<script>` subtrees dropped while building. Proves the
    /// scripted content *was present and removed*, complementing
    /// `has_script_node()` (which must stay false).
    pub dropped_scripts: u32,
}
