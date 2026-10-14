//! Rust EPUB engine: OCF container, OPF metadata, and manifest/spine/TOC.
//!
//! Phase-A layout:
//! - [`container`] opens the ZIP and resolves entries by href;
//! - [`opf`] parses the package document and resolves manifest/spine/TOC;
//! - [`nav`] parses EPUB3 nav documents and EPUB2 NCX;
//! - [`dom`] parses XHTML with browser-grade HTML5 recovery;
//! - [`block`] lowers that DOM into the block tree with UTF-16 ranges;
//! - [`css`] parses stylesheets and `@font-face` with `cssparser`/`selectors`;
//! - [`cascade`] matches selectors and computes styles onto the block tree;
//! - [`model`] holds the DTOs and error type shared with the FFI layer.
//!
//! Later tasks add resources and the flat-run projection.

pub mod block;
pub mod cascade;
pub mod container;
pub mod css;
pub mod dom;
pub mod model;
pub mod nav;
pub mod opf;
