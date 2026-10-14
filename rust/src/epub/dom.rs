//! `html5ever`-backed XHTML parsing: browser-grade recovery, nothing more.
//!
//! This module is the *only* place `html5ever` / `markup5ever_rcdom` types
//! appear. [`parse_document`] lowers a byte slice to an `RcDom` and the rest of
//! the crate reads it through the tiny accessors below (`element_name`,
//! `attributes`, `text`, `children`, `find_element`). The DOM never leaves.
//!
//! Parsing XHTML with the **HTML5** algorithm (rather than an XML parser) is
//! the point of G1/D5: EPUB XHTML is supposed to be well-formed XML, but real
//! books misnest and leave tags unclosed, and the HTML5 algorithm recovers the
//! way a browser does — so an unclosed `<div>` in one chapter cannot swallow
//! the next (Review Focus #4).

use html5ever::tendril::TendrilSink;
use html5ever::ParseOpts;
use markup5ever_rcdom::{Handle, NodeData, RcDom};

/// Parses `bytes` as HTML with HTML5 error recovery, returning the document
/// node.
///
/// UTF-16 input is decoded via a BOM when present; otherwise the bytes are
/// decoded as UTF-8 (lossy). The decoded text is then fed to `html5ever`
/// through its UTF-8 sink, so this one function is the encoding boundary.
pub fn parse_document(bytes: &[u8]) -> Handle {
    let text = decode(bytes);
    html5ever::parse_document(RcDom::default(), ParseOpts::default())
        .from_utf8()
        .one(text.as_bytes())
        .document
}

/// Decodes XHTML bytes to UTF-8 text, honouring a UTF-16 BOM.
fn decode(bytes: &[u8]) -> String {
    if let Some(rest) = bytes.strip_prefix(&[0xFF, 0xFE]) {
        return String::from_utf16_lossy(&utf16_units(rest, u16::from_le_bytes));
    }
    if let Some(rest) = bytes.strip_prefix(&[0xFE, 0xFF]) {
        return String::from_utf16_lossy(&utf16_units(rest, u16::from_be_bytes));
    }
    let body = bytes.strip_prefix(&[0xEF, 0xBB, 0xBF]).unwrap_or(bytes);
    String::from_utf8_lossy(body).into_owned()
}

/// Pairs `bytes` into UTF-16 code units, ignoring an odd trailing byte.
fn utf16_units(bytes: &[u8], from_bytes: fn([u8; 2]) -> u16) -> Vec<u16> {
    let mut units = Vec::with_capacity(bytes.len() / 2);
    let mut i = 0;
    while i + 1 < bytes.len() {
        units.push(from_bytes([bytes[i], bytes[i + 1]]));
        i += 2;
    }
    units
}

/// The lowercased local element name, or `None` for a non-element node.
pub fn element_name(node: &Handle) -> Option<String> {
    match &node.data {
        NodeData::Element { name, .. } => Some(name.local.as_ref().to_string()),
        _ => None,
    }
}

/// The element's attributes as `(lowercased local name, value)` in source order.
pub fn attributes(node: &Handle) -> Vec<(String, String)> {
    match &node.data {
        NodeData::Element { attrs, .. } => attrs
            .borrow()
            .iter()
            .map(|a| (a.name.local.as_ref().to_string(), a.value.to_string()))
            .collect(),
        _ => Vec::new(),
    }
}

/// The contents of a text node, or `None` for any other node.
pub fn text(node: &Handle) -> Option<String> {
    match &node.data {
        NodeData::Text { contents } => Some(contents.borrow().to_string()),
        _ => None,
    }
}

/// The node's children in document order.
pub fn children(node: &Handle) -> Vec<Handle> {
    node.children.borrow().clone()
}

/// The concatenated text of every element named `name`, in document order,
/// including descendants of `node`.
///
/// Used to harvest `<style>` text from the whole document (`<head>` and
/// `<body>`), matching the Dart parser's `doc.querySelectorAll('style')`.
pub fn element_texts(node: &Handle, name: &str) -> Vec<String> {
    let mut out = Vec::new();
    collect_element_texts(node, name, &mut out);
    out
}

fn collect_element_texts(node: &Handle, name: &str, out: &mut Vec<String>) {
    for child in children(node) {
        if element_name(&child).as_deref() == Some(name) {
            let mut text = String::new();
            gather_text(&child, &mut text);
            out.push(text);
        } else {
            collect_element_texts(&child, name, out);
        }
    }
}

fn gather_text(node: &Handle, out: &mut String) {
    for child in children(node) {
        if let Some(text) = text(&child) {
            out.push_str(&text);
        } else {
            gather_text(&child, out);
        }
    }
}

/// The first element in document order whose local name matches `name`,
/// searching descendants only (not `node` itself).
pub fn find_element(node: &Handle, name: &str) -> Option<Handle> {
    for child in children(node) {
        if element_name(&child).as_deref() == Some(name) {
            return Some(child);
        }
        if let Some(found) = find_element(&child, name) {
            return Some(found);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recovers_from_unclosed_tags() {
        let dom = parse_document(b"<html><body><div><p>kept<p>also kept</body></html>");
        let body = find_element(&dom, "body").expect("body");
        // Both paragraphs survive even though neither `</p>` nor `</div>` was
        // written: HTML5 recovery, not XML failure.
        let mut count = 0;
        fn walk(node: &Handle, count: &mut usize) {
            for child in children(node) {
                if element_name(&child).as_deref() == Some("p") {
                    *count += 1;
                }
                walk(&child, count);
            }
        }
        walk(&body, &mut count);
        assert_eq!(count, 2);
    }

    #[test]
    fn decodes_utf16_le_with_bom() {
        let mut bytes = vec![0xFF, 0xFE];
        for unit in "Hi".encode_utf16() {
            bytes.extend_from_slice(&unit.to_le_bytes());
        }
        assert_eq!(decode(&bytes), "Hi");
    }

    #[test]
    fn decodes_utf8() {
        assert_eq!(decode("héllo".as_bytes()), "héllo");
    }
}
