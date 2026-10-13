//! Rust EPUB engine: OCF container, OPF metadata, and manifest/spine/TOC.
//!
//! Phase-A layout:
//! - [`container`] opens the ZIP and resolves entries by href;
//! - [`opf`] parses the package document and resolves manifest/spine/TOC;
//! - [`nav`] parses EPUB3 nav documents and EPUB2 NCX;
//! - [`model`] holds the DTOs and error type shared with the FFI layer.
//!
//! Later tasks add XHTML, CSS, and resources.

pub mod container;
pub mod model;
pub mod nav;
pub mod opf;
