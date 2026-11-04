//! Block tree construction from parsed XHTML.
//!
//! [`dom`](super::dom) lowers XHTML to a browser-grade DOM; this module walks
//! it into a flat arena of [`BlockNode`]s. The tree keeps block structure —
//! paragraphs, headings, lists, list items, blockquote, pre, images — rather
//! than flattening it to a body string (G3), and every node carries a
//! `text_range` measured in **Dart UTF-16 code units**, the unit
//! `String.substring` uses downstream (D4).
//!
//! Two safety properties are enforced here (D9):
//!
//! - `<script>` (and `<style>`) subtrees are **dropped** during the build, so
//!   scripted content is never represented, let alone executed. `<style>` text
//!   is harvested for the cascade by [`parse_xhtml_bytes_parts_with_links`]
//!   (it is CSS text, not a node, and never enters the tree), while `<script>`
//!   text is discarded entirely;
//! - absolute URLs are kept **raw** in `attrs` and never resolved or fetched —
//!   the engine has no fetch capability, so [`BlockTree::remote_fetch_count`]
//!   is zero by construction.

use crate::epub::container::{container_rootfile, normalize_key, resolve_href, EpubArchive};
use crate::epub::dom;
use crate::epub::model::{Attrs, BlockKind, BlockNode, BlockTree, EpubError};
use markup5ever_rcdom::Handle;

/// Maximum element depth walked recursively. Deeper input is truncated rather
/// than risking a stack overflow on a hostile book.
const MAX_BLOCK_DEPTH: usize = 512;

/// Parses an XHTML document from `bytes` into a block tree.
pub fn parse_xhtml_bytes(bytes: &[u8]) -> BlockTree {
    parse_xhtml_bytes_parts(bytes).0
}

/// Parses an XHTML document from `bytes` into a block tree plus its `<link
/// rel="stylesheet">` / `<style>` inputs, in document order.
///
/// The style *elements* are still dropped — nothing style-like enters the tree
/// (D9) — but their CSS (and link target) is the cascade's input, which is why
/// it is returned alongside rather than in the tree (and never crosses the
/// FFI). `<link>` hrefs are returned exactly as written; resolving them
/// against the chapter's archive directory is the caller's job.
pub fn parse_xhtml_bytes_parts_with_links(bytes: &[u8]) -> (BlockTree, Vec<dom::StyleEvent>) {
    let document = dom::parse_document(bytes);
    Builder::default().build(document)
}

/// Parses an XHTML document from `bytes` into a block tree plus its inline
/// `<style>` text (in document order, from `<head>` and `<body>`).
pub fn parse_xhtml_bytes_parts(bytes: &[u8]) -> (BlockTree, Vec<String>) {
    let (tree, events) = parse_xhtml_bytes_parts_with_links(bytes);
    let styles = events
        .into_iter()
        .filter_map(|event| match event {
            dom::StyleEvent::Style(css) => Some(css),
            dom::StyleEvent::Link(_) => None,
        })
        .collect();
    (tree, styles)
}

/// Parses an XHTML document from a string into a block tree.
pub fn parse_xhtml(xml: &str) -> BlockTree {
    parse_xhtml_bytes(xml.as_bytes())
}

/// Resolves `doc_path` in `archive` and parses it into a block tree.
///
/// `doc_path` may be an href relative to the OPF directory (its form in the
/// spine) or an already-normalised archive key. Resolution is percent-decoding
/// and case-insensitive, so both `Text/100%_cover.xhtml` and
/// `oebps/text/100%_cover.xhtml` hit (bug class #148, Review Focus #3).
pub fn parse_xhtml_document(archive: &EpubArchive, doc_path: &str) -> Result<BlockTree, EpubError> {
    Ok(parse_xhtml_document_parts(archive, doc_path)?.0)
}

/// Like [`parse_xhtml_document`], but also returns the chapter's styling
/// inputs (`<link rel="stylesheet">` / `<style>`) in document order, and the
/// archive key the document was resolved to (used to resolve relative
/// `@import`/`<link>` hrefs).
pub fn parse_xhtml_document_parts_with_links(
    archive: &EpubArchive,
    doc_path: &str,
) -> Result<(BlockTree, Vec<dom::StyleEvent>, String), EpubError> {
    let (bytes, key) = read_chapter(archive, doc_path)?;
    let (tree, events) = parse_xhtml_bytes_parts_with_links(&bytes);
    Ok((tree, events, key))
}

/// Like [`parse_xhtml_document`], but also returns the chapter's inline
/// `<style>` text for the cascade.
pub fn parse_xhtml_document_parts(
    archive: &EpubArchive,
    doc_path: &str,
) -> Result<(BlockTree, Vec<String>), EpubError> {
    let (tree, events, _) = parse_xhtml_document_parts_with_links(archive, doc_path)?;
    let styles = events
        .into_iter()
        .filter_map(|event| match event {
            dom::StyleEvent::Style(css) => Some(css),
            dom::StyleEvent::Link(_) => None,
        })
        .collect();
    Ok((tree, styles))
}

/// Reads a chapter's bytes and returns the archive key it resolved to: first
/// relative to the OPF directory, then as an archive-root key. Percent-encoded
/// and case-varied paths both resolve.
fn read_chapter(
    archive: &EpubArchive,
    doc_path: &str,
) -> Result<(Vec<u8>, String), EpubError> {
    let base = container_rootfile(archive)
        .ok()
        .map(|opf| dir_of(&opf))
        .unwrap_or_default();
    if !base.is_empty() {
        let key = resolve_href(&base, doc_path);
        if let Some(bytes) = archive.read_by_key(&key) {
            return Ok((bytes, key));
        }
    }
    let key = normalize_key(doc_path);
    if let Some(bytes) = archive.read_by_key(&key) {
        return Ok((bytes, key));
    }
    Err(EpubError::Invalid(format!("Chapter not found: {doc_path}")))
}

fn dir_of(path: &str) -> String {
    match path.rfind('/') {
        Some(i) => path[..i].to_string(),
        None => String::new(),
    }
}

/// The UTF-16 `text_range` of the paragraph wrapping `text`.
///
/// Convenience for the ordering test: `block_text_range("A\u{1F600}B")` parses
/// `<p>A😀B</p>` and returns the paragraph's range, which is `(0, 4)` because
/// the emoji is one scalar but two UTF-16 code units.
pub fn block_text_range(text: &str) -> (u32, u32) {
    let tree = parse_xhtml(&format!("<p>{text}</p>"));
    tree.nodes
        .iter()
        .find(|n| n.kind == BlockKind::Paragraph)
        .map(|n| n.text_range)
        .unwrap_or((0, 0))
}

impl BlockTree {
    /// The chapter text in document order.
    pub fn text(&self) -> &str {
        &self.text
    }

    /// The text of node `index`, sliced by its UTF-16 `text_range`.
    pub fn node_text(&self, index: usize) -> &str {
        let (start, end) = match self.nodes.get(index) {
            Some(node) => (node.text_range.0 as usize, node.text_range.1 as usize),
            None => return "",
        };
        utf16_slice(&self.text, start, end)
    }

    /// Whether the tree contains a `<script>` node. Always `false`: script
    /// subtrees are dropped at build time. Scans the arena rather than
    /// returning a literal so a future regression that emits a script node
    /// fails this test instead of silently passing.
    pub fn has_script_node(&self) -> bool {
        self.nodes.iter().any(|n| n.attrs.tag == "script")
    }

    /// Network fetches performed while parsing. Always `0` (D9).
    pub fn remote_fetch_count(&self) -> u32 {
        self.remote_fetches
    }

    /// Number of `<script>` subtrees that were present and dropped.
    pub fn dropped_script_count(&self) -> u32 {
        self.dropped_scripts
    }
}

/// Maps an element's local name to its structural role.
fn kind_of(name: &str) -> BlockKind {
    match name {
        "p" => BlockKind::Paragraph,
        "h1" | "h2" | "h3" | "h4" | "h5" | "h6" => BlockKind::Heading,
        "ul" | "ol" | "menu" => BlockKind::List,
        "li" => BlockKind::ListItem,
        "blockquote" => BlockKind::Blockquote,
        "pre" => BlockKind::Pre,
        "img" => BlockKind::Image,
        _ => BlockKind::Inline,
    }
}

/// The heading level (1–6) for an `h1`–`h6`, else `None`.
fn heading_level(name: &str) -> Option<u8> {
    match name {
        "h1" => Some(1),
        "h2" => Some(2),
        "h3" => Some(3),
        "h4" => Some(4),
        "h5" => Some(5),
        "h6" => Some(6),
        _ => None,
    }
}

/// Block-level tags. Used only to decide whether a whitespace-only text node is
/// rendered content (inline flow) or layout (block flow); it is deliberately
/// broader than [`BlockKind`], because e.g. a `<div>` is [`BlockKind::Inline`]
/// but still establishes a block boundary for whitespace purposes.
fn is_block_tag(name: &str) -> bool {
    matches!(
        name,
        "address"
            | "article"
            | "aside"
            | "blockquote"
            | "details"
            | "div"
            | "dl"
            | "fieldset"
            | "figcaption"
            | "figure"
            | "footer"
            | "form"
            | "h1"
            | "h2"
            | "h3"
            | "h4"
            | "h5"
            | "h6"
            | "header"
            | "hr"
            | "li"
            | "main"
            | "menu"
            | "nav"
            | "ol"
            | "p"
            | "pre"
            | "section"
            | "table"
            | "ul"
    )
}

fn is_block_element(node: &Handle) -> bool {
    dom::element_name(node)
        .map(|name| is_block_tag(&name))
        .unwrap_or(false)
}

fn attrs_of(tag: &str, node: &Handle) -> Attrs {
    let mut attrs = Attrs {
        tag: tag.to_string(),
        ..Default::default()
    };
    let mut hidden = false;
    for (name, value) in dom::attributes(node) {
        match name.as_str() {
            "id" => attrs.id = Some(value),
            "name" => attrs.name = Some(value),
            "class" => attrs.class = Some(value),
            "src" => attrs.src = Some(value),
            "href" => attrs.href = Some(value),
            "alt" => attrs.alt = Some(value),
            "width" => attrs.width = Some(value),
            "height" => attrs.height = Some(value),
            "style" => attrs.style = Some(value),
            "align" => attrs.align = Some(value),
            // The HTML `hidden` attribute is `display: none` in the UA sheet;
            // fold it into the inline style so the cascade and projection see
            // one representation.
            "hidden" => hidden = true,
            _ => {}
        }
    }
    if hidden {
        let style = attrs.style.take().unwrap_or_default();
        attrs.style = Some(if style.trim().is_empty() {
            "display:none".to_string()
        } else {
            format!("{style};display:none")
        });
    }
    attrs
}

/// Byte offset of the `target`-th UTF-16 code unit in `s`.
///
/// Using this instead of a byte count is what keeps every following run and
/// image offset aligned when a chapter contains a non-BMP character (Review
/// Focus #1).
fn utf16_to_byte(s: &str, target: usize) -> usize {
    let mut units = 0;
    for (byte, ch) in s.char_indices() {
        if units >= target {
            return byte;
        }
        units += ch.len_utf16();
    }
    s.len()
}

/// Slices `s` by UTF-16 code-unit offsets (half-open).
pub fn utf16_slice(s: &str, start: usize, end: usize) -> &str {
    let (start, end) = if end < start {
        (start, start)
    } else {
        (start, end)
    };
    &s[utf16_to_byte(s, start)..utf16_to_byte(s, end)]
}

#[derive(Default)]
struct Builder {
    nodes: Vec<BlockNode>,
    text: String,
    /// Running length of `text` in UTF-16 code units.
    utf16_len: usize,
    dropped_scripts: u32,
}

impl Builder {
    fn build(mut self, document: Handle) -> (BlockTree, Vec<dom::StyleEvent>) {
        // Harvest the document's styling inputs in document order before
        // walking: the style *elements* are dropped (D9), but their CSS text
        // (and the `<link rel="stylesheet">` targets) are cascade input.
        let style_events = dom::style_events(&document);

        // The `<body>` is the content root; `<head>` (title, stylesheets) is
        // not part of the chapter text. The synthetic root carries the body's
        // tag/id/class so a `body { … }` rule can match it during the cascade.
        //
        // Both `document` and `body` must stay live for the whole walk.
        // `markup5ever_rcdom`'s `Drop for Node` drains the *descendants* of a
        // dropped node, so dropping the document root — or the body handle —
        // while a descendant is still being read would empty that descendant's
        // children mid-walk.
        let body = dom::find_element(&document, "body");
        let root_attrs = match &body {
            Some(body) => attrs_of("body", body),
            None => Attrs::default(),
        };
        let root = self.push(BlockKind::Root, None, (0, 0), root_attrs);

        let children = match &body {
            Some(body) => self.walk_children(body, false, 0),
            None => self.walk_children(&document, false, 0),
        };

        self.nodes[root].children = children;
        self.nodes[root].text_range = (0, self.utf16_len as u32);
        (
            BlockTree {
                nodes: self.nodes,
                text: self.text,
                remote_fetches: 0,
                dropped_scripts: self.dropped_scripts,
            },
            style_events,
        )
    }

    /// Walks the children of `parent`, returning the arena indices of the child
    /// nodes built (text is folded into the shared buffer, not a node).
    ///
    /// Whitespace handling is decided here, per parent: a whitespace-only text
    /// node is *layout* only when the parent also lays out a block-level child.
    /// Inside an inline flow (`<p>a <em>b</em> <em>c</em></p>`) the spaces are
    /// rendered content and must survive, or the node text and the selected
    /// offsets would silently merge words.
    fn walk_children(&mut self, parent: &Handle, in_pre: bool, depth: usize) -> Vec<u32> {
        if depth > MAX_BLOCK_DEPTH {
            return Vec::new();
        }
        let children = dom::children(parent);
        let block_flow = children.iter().any(is_block_element);

        let mut out = Vec::new();
        for child in &children {
            if let Some(text) = dom::text(child) {
                if text.is_empty() {
                    continue;
                }
                if !in_pre && block_flow && text.chars().all(char::is_whitespace) {
                    continue;
                }
                self.utf16_len += text.encode_utf16().count();
                self.text.push_str(&text);
                continue;
            }
            // XHTML CDATA sections arrive as bogus comments (`[CDATA[...]]`)
            // from the HTML5 tokenizer; recover their literal text.
            if let Some(text) = dom::cdata_text(child) {
                if text.is_empty() {
                    continue;
                }
                if !in_pre && block_flow && text.chars().all(char::is_whitespace) {
                    continue;
                }
                self.utf16_len += text.encode_utf16().count();
                self.text.push_str(&text);
                continue;
            }
            if let Some(index) = self.walk(child, in_pre, depth + 1) {
                out.push(index as u32);
            }
        }
        out
    }

    /// Builds one element node (and its subtree), returning its arena index.
    fn walk(&mut self, node: &Handle, in_pre: bool, depth: usize) -> Option<usize> {
        if depth > MAX_BLOCK_DEPTH {
            return None;
        }
        let name = dom::element_name(node)?;

        // D9: scripted/styled content is never represented. The subtree is
        // dropped before any node is created.
        if name == "script" || name == "style" {
            if name == "script" {
                self.dropped_scripts += 1;
            }
            return None;
        }

        // Ruby annotations are pronunciation aids, not body text. Keeping them
        // would render `漢(kan)` instead of `漢`.
        if matches!(name.as_str(), "rt" | "rp" | "rtc") {
            return None;
        }

        let kind = kind_of(&name);
        let attrs = attrs_of(&name, node);
        let index = self.push(
            kind,
            heading_level(&name),
            (self.utf16_len as u32, self.utf16_len as u32),
            attrs,
        );

        let in_pre = in_pre || name == "pre";
        let children = self.walk_children(node, in_pre, depth + 1);
        self.nodes[index].children = children;
        // The node's range now spans every descendant text node appended.
        self.nodes[index].text_range.1 = self.utf16_len as u32;
        Some(index)
    }

    fn push(
        &mut self,
        kind: BlockKind,
        heading_level: Option<u8>,
        text_range: (u32, u32),
        attrs: Attrs,
    ) -> usize {
        self.nodes.push(BlockNode {
            kind,
            heading_level,
            text_range,
            children: Vec::new(),
            attrs,
            style: crate::epub::cascade::ComputedStyle::default(),
        });
        self.nodes.len() - 1
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text_of(xml: &str) -> String {
        parse_xhtml(xml).text
    }

    #[test]
    fn parses_block_structure_without_flattening() {
        let tree = parse_xhtml(
            "<body><h1>Title</h1><p>Intro <em>here</em>.</p>\
             <ul><li>One</li><li>Two</li></ul>\
             <blockquote><p>Quoted</p></blockquote>\
             <pre>  keep  </pre></body>",
        );
        let kinds: Vec<BlockKind> = tree.nodes.iter().map(|n| n.kind).collect();
        assert!(kinds.contains(&BlockKind::Heading));
        assert_eq!(
            kinds.iter().filter(|k| **k == BlockKind::Paragraph).count(),
            2
        );
        assert_eq!(kinds.iter().filter(|k| **k == BlockKind::List).count(), 1);
        assert_eq!(
            kinds.iter().filter(|k| **k == BlockKind::ListItem).count(),
            2
        );
        assert_eq!(
            kinds
                .iter()
                .filter(|k| **k == BlockKind::Blockquote)
                .count(),
            1
        );
        assert_eq!(kinds.iter().filter(|k| **k == BlockKind::Pre).count(), 1);
    }

    #[test]
    fn heading_level_matches_its_tag() {
        let tree = parse_xhtml("<body><h3>Third</h3></body>");
        let heading = tree
            .nodes
            .iter()
            .find(|n| n.kind == BlockKind::Heading)
            .expect("heading");
        assert_eq!(heading.heading_level, Some(3));
    }

    #[test]
    fn paragraph_text_range_spans_its_text() {
        let tree = parse_xhtml("<body><p>Hello world</p></body>");
        let p = tree
            .nodes
            .iter()
            .position(|n| n.kind == BlockKind::Paragraph)
            .expect("paragraph");
        assert_eq!(tree.nodes[p].text_range, (0, 11));
        assert_eq!(tree.node_text(p), "Hello world");
    }

    #[test]
    fn image_keeps_raw_src_and_alt() {
        let tree = parse_xhtml("<body><p><img src=\"https://x/y.png\" alt=\"a\"/></p></body>");
        let img = tree
            .nodes
            .iter()
            .find(|n| n.kind == BlockKind::Image)
            .expect("image");
        assert_eq!(img.attrs.src.as_deref(), Some("https://x/y.png"));
        assert_eq!(img.attrs.alt.as_deref(), Some("a"));
    }

    #[test]
    fn scripts_are_dropped_and_never_executed() {
        let tree = parse_xhtml("<body><p>keep</p><script>alert('boom')</script></body>");
        assert!(!tree.has_script_node());
        assert_eq!(tree.dropped_script_count(), 1);
        assert_eq!(tree.text, "keep");
        assert_eq!(tree.remote_fetch_count(), 0);
    }

    #[test]
    fn spaces_between_inline_siblings_are_preserved() {
        // The spaces are children of the `<p>`, whose children are all inline,
        // so they are rendered content — dropping them would merge the words.
        let tree = parse_xhtml("<body><p>a <em>b</em> <em>c</em></p></body>");
        assert_eq!(tree.text, "a b c");
        let p = tree
            .nodes
            .iter()
            .position(|n| n.kind == BlockKind::Paragraph)
            .expect("paragraph");
        assert_eq!(tree.nodes[p].text_range, (0, 5));
        assert_eq!(tree.node_text(p), "a b c");
    }

    #[test]
    fn whitespace_between_blocks_is_not_content_but_pre_is_kept() {
        assert_eq!(text_of("<body>\n  <p>a</p>\n  <p>b</p>\n</body>"), "ab");
        assert_eq!(text_of("<body><pre>  x  </pre></body>"), "  x  ");
        // Indentation around a block container is layout, even though the
        // container itself is `Inline` (a `<div>`).
        assert_eq!(text_of("<body>\n  <div><p>a</p></div>\n</body>"), "a");
    }

    #[test]
    fn utf16_slice_handles_non_bmp() {
        assert_eq!(utf16_slice("A\u{1F600}B", 0, 4), "A\u{1F600}B");
        assert_eq!(utf16_slice("A\u{1F600}B", 0, 3), "A\u{1F600}");
        assert_eq!(utf16_slice("A\u{1F600}B", 3, 4), "B");
    }
}
