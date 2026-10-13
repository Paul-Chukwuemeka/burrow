//! Rust EPUB engine: OCF container and OPF metadata.
//!
//! Phase-A layout:
//! - [`container`] opens the ZIP and resolves entries by href;
//! - [`opf`] parses the package document and extracts metadata/cover;
//! - [`model`] holds the DTOs and error type shared with the FFI layer.
//!
//! Later tasks add manifest/spine/TOC ([`opf`]), XHTML, CSS, and resources.

pub mod container;
pub mod model;
pub mod opf;
