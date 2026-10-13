//! Rust EPUB engine: OCF container, OPF metadata, and manifest/spine/TOC.
//!
//! Phase-A layout:
//! - [`container`] opens the ZIP and resolves entries by href;
//! - [`opf`] parses the package document and resolves manifest/spine/TOC;
//! - [`nav`] parses EPUB3 nav documents and EPUB2 NCX;
//! - [`dom`] parses XHTML with browser-grade HTML5 recovery;
//! - [`block`] lowers that DOM into the block tree with UTF-16 ranges;
//! - [`model`] holds the DTOs and error type shared with the FFI layer.
//!
//! Later tasks add CSS, resources, and the flat-run projection.

pub mod block;
pub mod container;
pub mod dom;
pub mod model;
pub mod nav;
pub mod opf;
