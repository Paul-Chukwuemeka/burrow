//! EPUB3 navigation documents (`properties="nav"`) and EPUB2 NCX parsing.
//!
//! Both produce the same [`TocEntryDto`] shape so the rest of the engine does
//! not care which format the book uses. Resolution mirrors
//! `DocumentParser._parseNavDoc` / `_parseNcx`: the target path is resolved
//! against the TOC document's directory (percent-decoded, lowercased), while
//! the fragment is kept **raw** because anchor matching tolerates encoding
//! differences later.

use std::collections::HashSet;

use quick_xml::events::{BytesStart, Event};
use quick_xml::reader::Reader;

use super::container::resolve_href;
use super::model::TocEntryDto;

/// Parses an EPUB3 nav document into TOC entries.
///
/// The `<nav epub:type="toc">` element wins; failing that the first `<nav>`,
/// and failing that the document root (matching Dart). When `require_nav` is
/// set — the last-resort scan for books that never flag their nav document —
/// a document without any `<nav>` yields nothing, so a stray link in an
/// ordinary chapter is never mistaken for a table of contents.
pub fn parse_nav(xml: &str, doc_path: &str, require_nav: bool) -> Vec<TocEntryDto> {
    let Some(root) = parse_dom(xml) else {
        return Vec::new();
    };

    let mut navs = Vec::new();
    descendants(&root, "nav", &mut navs);
    if navs.is_empty() && require_nav {
        return Vec::new();
    }

    let nav = navs
        .iter()
        .find(|n| {
            n.attr("type")
                .map(|t| t.split_whitespace().any(|p| p == "toc"))
                .unwrap_or(false)
        })
        .or_else(|| navs.first())
        .copied()
        .unwrap_or(&root);

    let base = dir_of(doc_path);
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    let mut anchors = Vec::new();
    descendants(nav, "a", &mut anchors);
    for a in anchors {
        let Some(href) = a.attr("href") else { continue };
        let title = inner_text(a);
        if title.is_empty() {
            continue;
        }
        push_entry(&mut out, &mut seen, &base, href, title);
    }
    out
}

/// Parses an EPUB2 `toc.ncx` into TOC entries.
///
/// Every `navPoint` is flattened in document order, so nested points keep their
/// reading sequence. A `navPoint`'s label comes from its own first `<text>`
/// child and its target from its own first `<content>` child.
pub fn parse_ncx(xml: &str, ncx_path: &str) -> Vec<TocEntryDto> {
    let Some(root) = parse_dom(xml) else {
        return Vec::new();
    };

    let base = dir_of(ncx_path);
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    let mut points = Vec::new();
    descendants(&root, "navpoint", &mut points);
    for point in points {
        let title = first(point, "text").map(inner_text).unwrap_or_default();
        if title.is_empty() {
            continue;
        }
        let Some(src) = first(point, "content").and_then(|c| c.attr("src")) else {
            continue;
        };
        push_entry(&mut out, &mut seen, &base, src, title);
    }
    out
}

/// Extracts a spine document's own title for the TOC-less fallback: the first
/// non-empty `<title>`, else the first non-empty `<h1>`.
pub fn document_title(xml: &str) -> Option<String> {
    let root = parse_dom(xml)?;
    for tag in ["title", "h1"] {
        let mut found = Vec::new();
        descendants(&root, tag, &mut found);
        for el in found {
            let text = inner_text(el);
            if !text.is_empty() {
                return Some(text);
            }
        }
    }
    None
}

/// Splits an href into its resolved document key and its raw fragment.
fn push_entry(
    out: &mut Vec<TocEntryDto>,
    seen: &mut HashSet<String>,
    base: &str,
    href: &str,
    title: String,
) {
    let hash = href.find('#');
    let fragment = hash
        .map(|i| href[i + 1..].trim().to_string())
        .filter(|s| !s.is_empty());
    let file_key = resolve_href(base, href); // percent-decoded + lowercased
    if file_key.is_empty() {
        return;
    }
    let dedup = format!("{file_key}#{}", fragment.as_deref().unwrap_or(""));
    if !seen.insert(dedup) {
        return;
    }
    out.push(TocEntryDto {
        file_key,
        fragment,
        title,
    });
}

fn dir_of(path: &str) -> String {
    match path.rfind('/') {
        Some(i) => path[..i].to_string(),
        None => String::new(),
    }
}

// ---------------------------------------------------------------------------
// A minimal, error-tolerant XML DOM.
//
// quick-xml streams events, and the TOC lookups are naturally tree-shaped
// ("the first `<a>` inside the `<nav>` whose `epub:type` is `toc`"), so build
// the tree once. Malformed XML stops parsing and keeps what was read, matching
// the OPF/container parsers' tolerance.
//
// Text is stored as `#text` child nodes rather than a field on the element, so
// a mixed-content label such as `<a><span>1</span> Introduction</a>` keeps its
// document order ("1 Introduction"), matching Dart's `innerText`.
// ---------------------------------------------------------------------------

/// Element name used for text nodes in the tree.
const TEXT_NODE: &str = "#text";

#[derive(Debug, Default)]
struct El {
    name: String,
    /// (local name, lowercased) -> value
    attrs: Vec<(String, String)>,
    /// Text content for a `#text` node; empty for elements.
    text: String,
    /// Child elements and text nodes, in document order.
    children: Vec<El>,
}

impl El {
    fn attr(&self, local: &str) -> Option<&str> {
        let want = local.to_ascii_lowercase();
        self.attrs
            .iter()
            .find(|(k, _)| *k == want)
            .map(|(_, v)| v.as_str())
    }
}

fn el_of(e: &BytesStart<'_>) -> El {
    let attrs = e
        .attributes()
        .flatten()
        .map(|a| {
            (
                a.key.local_name().as_ref().to_ascii_lowercase(),
                a.normalized_value(quick_xml::XmlVersion::Implicit1_0)
                    .map(|v| v.into_owned())
                    .unwrap_or_else(|_| a.value.to_string()),
            )
        })
        .collect();
    El {
        name: e.local_name().as_ref().to_ascii_lowercase(),
        attrs,
        text: String::new(),
        children: Vec::new(),
    }
}

fn parse_dom(xml: &str) -> Option<El> {
    let mut reader = Reader::from_str(xml);
    reader.config_mut().trim_text(false);

    let mut stack: Vec<El> = Vec::new();
    let mut root: Option<El> = None;
    loop {
        match reader.read_event() {
            Ok(Event::Start(e)) => stack.push(el_of(&e)),
            Ok(Event::Empty(e)) => attach(&mut stack, &mut root, el_of(&e)),
            Ok(Event::Text(e)) => push_text(&mut stack, &e.into_inner()),
            Ok(Event::CData(e)) => push_text(&mut stack, &e.into_inner()),
            // quick-xml 0.42 emits entities separately from text.
            Ok(Event::GeneralRef(e)) => {
                let mut entity = String::new();
                append_entity(&mut entity, &e);
                push_text(&mut stack, &entity);
            }
            Ok(Event::End(e)) => {
                // Match the end tag against the stack so unclosed elements
                // cannot swallow their real parents. The nearest open element
                // with the same name wins; anything unclosed above it folds
                // into that element as siblings (in document order), not
                // nested under each other. A stray end tag with no open match
                // is ignored instead of popping an innocent element.
                // Well-formed input always matches the stack top, so its tree
                // is identical to a blind pop.
                let end_name = e.local_name();
                let end_name = end_name.as_ref().to_ascii_lowercase();
                let Some(idx) = stack.iter().rposition(|el| el.name == end_name) else {
                    continue;
                };
                let above: Vec<El> = stack.drain(idx + 1..).collect();
                if let Some(matched) = stack.last_mut() {
                    matched.children.extend(above);
                }
                if let Some(el) = stack.pop() {
                    attach(&mut stack, &mut root, el);
                }
            }
            Ok(Event::Eof) => break,
            // Tolerate malformed XML: keep what parsed.
            Err(_) => break,
            _ => {}
        }
    }
    // Tolerate unclosed elements at EOF: fold the stack bottom-up instead of
    // dropping it, so an unclosed root still yields a tree. When no root
    // closed yet, the folded stack becomes the root; when a root already
    // closed (kept in `root`), trailing unclosed elements are dropped.
    // Note: two *closed* roots last-win (`attach` overwrites `root`); only
    // the unclosed-trailing case keeps the first.
    while stack.len() > 1 {
        if let Some(el) = stack.pop() {
            attach(&mut stack, &mut root, el);
        }
    }
    if root.is_none() {
        root = stack.pop();
    }
    root
}

fn attach(stack: &mut Vec<El>, root: &mut Option<El>, el: El) {
    match stack.last_mut() {
        Some(parent) => parent.children.push(el),
        None => *root = Some(el),
    }
}

/// Appends `s` to the parent's trailing `#text` node, or starts a new one, so
/// text keeps its position relative to sibling elements.
fn push_text(stack: &mut Vec<El>, s: &str) {
    let Some(top) = stack.last_mut() else { return };
    if let Some(last) = top.children.last_mut() {
        if last.name == TEXT_NODE {
            last.text.push_str(s);
            return;
        }
    }
    top.children.push(El {
        name: TEXT_NODE.to_string(),
        attrs: Vec::new(),
        text: s.to_string(),
        children: Vec::new(),
    });
}

/// Resolves a `&name;` / `&#38;` reference event into text (mirrors `opf.rs`).
fn append_entity(dst: &mut String, e: &quick_xml::events::BytesRef<'_>) {
    if let Ok(Some(c)) = e.resolve_char_ref() {
        dst.push(c);
        return;
    }
    if let Some(s) = quick_xml::escape::resolve_predefined_entity(e.as_ref()) {
        dst.push_str(s);
        return;
    }
    dst.push('&');
    dst.push_str(e.as_ref());
    dst.push(';');
}

/// Collects descendant elements whose local name matches, in document order.
fn descendants<'a>(el: &'a El, name: &str, out: &mut Vec<&'a El>) {
    for child in &el.children {
        if child.name == name {
            out.push(child);
        }
        descendants(child, name, out);
    }
}

fn first<'a>(el: &'a El, name: &str) -> Option<&'a El> {
    let mut found = Vec::new();
    descendants(el, name, &mut found);
    found.first().copied()
}

/// Concatenates text under `el` in **document order**, then trims. Text nodes
/// and element children are walked together, so mixed content like
/// `<a><span>1</span> Introduction</a>` yields `"1 Introduction"`, matching
/// Dart's `innerText`.
fn inner_text(el: &El) -> String {
    fn walk(el: &El, out: &mut String) {
        for child in &el.children {
            if child.name == TEXT_NODE {
                out.push_str(&child.text);
            } else {
                walk(child, out);
            }
        }
    }
    let mut out = String::new();
    walk(el, &mut out);
    // TOC source files routinely wrap titles across lines; collapse every
    // whitespace run (not just the ends) so the reader shows one clean line.
    out.split_whitespace().collect::<Vec<_>>().join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nav_prefers_the_toc_typed_nav() {
        let xml = r#"<html><body>
            <nav epub:type="landmarks"><a href="Text/ch1.xhtml">Start</a></nav>
            <nav epub:type="toc">
              <ol>
                <li><a href="Text/ch1.xhtml">One</a></li>
                <li><a href="Text/ch2.xhtml#sec%202">Two</a></li>
              </ol>
            </nav>
        </body></html>"#;
        let toc = parse_nav(xml, "OEBPS/nav.xhtml", false);
        assert_eq!(
            toc,
            vec![
                TocEntryDto {
                    file_key: "oebps/text/ch1.xhtml".into(),
                    fragment: None,
                    title: "One".into(),
                },
                TocEntryDto {
                    file_key: "oebps/text/ch2.xhtml".into(),
                    fragment: Some("sec%202".into()),
                    title: "Two".into(),
                },
            ],
        );
    }

    #[test]
    fn nav_without_a_nav_element_only_counts_when_required() {
        let xml = r#"<html><body><p><a href="Text/ch1.xhtml">One</a></p></body></html>"#;
        assert!(parse_nav(xml, "OEBPS/page.xhtml", true).is_empty());
        assert_eq!(parse_nav(xml, "OEBPS/page.xhtml", false).len(), 1);
    }

    #[test]
    fn nav_label_keeps_mixed_content_in_document_order() {
        // A label with a leading element and trailing text must read
        // "1 Introduction", not "Introduction1" (Dart `innerText` order).
        let xml = r#"<html><body><nav epub:type="toc">
            <ol><li><a href="Text/ch1.xhtml"><span>1</span> Introduction</a></li></ol>
        </nav></body></html>"#;
        let toc = parse_nav(xml, "OEBPS/nav.xhtml", false);
        assert_eq!(toc.len(), 1);
        assert_eq!(toc[0].title, "1 Introduction");
    }

    #[test]
    fn document_title_keeps_mixed_content_in_document_order() {
        let xml = "<html><head><title>Part <em>One</em> here</title></head></html>";
        assert_eq!(document_title(xml).as_deref(), Some("Part One here"));
    }

    #[test]
    fn ncx_flattens_navpoints_in_order() {
        let xml = r#"<ncx><navMap>
            <navPoint><navLabel><text>One</text></navLabel>
              <content src="Text/ch1.xhtml"/></navPoint>
            <navPoint><navLabel><text>Two</text></navLabel>
              <content src="Text/ch2.xhtml#a"/>
              <navPoint><navLabel><text>Sub</text></navLabel>
                <content src="Text/ch3.xhtml"/></navPoint>
            </navPoint>
        </navMap></ncx>"#;
        let toc = parse_ncx(xml, "OEBPS/toc.ncx");
        assert_eq!(
            toc.iter().map(|e| e.title.as_str()).collect::<Vec<_>>(),
            vec!["One", "Two", "Sub"],
        );
        assert_eq!(toc[1].fragment.as_deref(), Some("a"));
    }

    #[test]
    fn document_title_reads_first_title_then_h1() {
        assert_eq!(
            document_title("<html><head><title> One </title></head></html>").as_deref(),
            Some("One"),
        );
        assert_eq!(
            document_title("<html><body><h1>Heading</h1></body></html>").as_deref(),
            Some("Heading"),
        );
        assert_eq!(document_title("<html><body><p>x</p></body></html>"), None);
    }
}
