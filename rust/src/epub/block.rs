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
//!   scripted content is never represented, let alone executed;
//! - absolute URLs are kept **raw** in `attrs` and never resolved or fetched —
//!   the engine has no fetch capability, so [`BlockTree::remote_fetch_count`]
//!   is zero by construction.

use crate::epub::container::{container_rootfile, normalize_key, resolve_href, EpubArchive};
use crate::epub::dom;
use crate::epub::model::{Attrs, BlockKind, BlockNode, BlockTree, EpubError};
use markup5ever_rcdom::Handle;

/// Parses an XHTML document from `bytes` into a block tree.
pub fn parse_xhtml_bytes(bytes: &[u8]) -> BlockTree {
    let document = dom::parse_document(bytes);
    Builder::default().build(document)
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
    let bytes = read_chapter(archive, doc_path)?;
    Ok(parse_xhtml_bytes(&bytes))
}

/// Reads a chapter's bytes: first relative to the OPF directory, then as an
/// archive-root key. Percent-encoded and case-varied paths both resolve.
fn read_chapter(archive: &EpubArchive, doc_path: &str) -> Result<Vec<u8>, EpubError> {
    let base = container_rootfile(archive)
        .ok()
        .map(|opf| dir_of(&opf))
        .unwrap_or_default();
    if !base.is_empty() {
        if let Some(bytes) = archive.read_by_key(&resolve_href(&base, doc_path)) {
            return Ok(bytes);
        }
    }
    if let Some(bytes) = archive.read_by_key(&normalize_key(doc_path)) {
        return Ok(bytes);
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
pub fn block_text_range(text: &str) -> (usize, usize) {
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
            Some(node) => node.text_range,
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
        "h1" => BlockKind::Heading(1),
        "h2" => BlockKind::Heading(2),
        "h3" => BlockKind::Heading(3),
        "h4" => BlockKind::Heading(4),
        "h5" => BlockKind::Heading(5),
        "h6" => BlockKind::Heading(6),
        "ul" | "ol" | "menu" => BlockKind::List,
        "li" => BlockKind::ListItem,
        "blockquote" => BlockKind::Blockquote,
        "pre" => BlockKind::Pre,
        "img" => BlockKind::Image,
        _ => BlockKind::Inline,
    }
}

fn attrs_of(tag: &str, node: &Handle) -> Attrs {
    let mut attrs = Attrs {
        tag: tag.to_string(),
        ..Default::default()
    };
    for (name, value) in dom::attributes(node) {
        match name.as_str() {
            "id" => attrs.id = Some(value),
            "class" => attrs.class = Some(value),
            "src" => attrs.src = Some(value),
            "href" => attrs.href = Some(value),
            "alt" => attrs.alt = Some(value),
            "width" => attrs.width = Some(value),
            "height" => attrs.height = Some(value),
            _ => {}
        }
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
    fn build(mut self, document: Handle) -> BlockTree {
        let root = self.push(BlockKind::Root, (0, 0), Attrs::default());

        // The `<body>` is the content root; `<head>` (title, stylesheets) is
        // not part of the chapter text.
        //
        // Both `document` and `body` must stay live for the whole walk.
        // `markup5ever_rcdom`'s `Drop for Node` drains the *descendants* of a
        // dropped node, so dropping the document root — or the body handle —
        // while a descendant is still being read would empty that descendant's
        // children mid-walk.
        let body = dom::find_element(&document, "body");
        let content = match &body {
            Some(body) => dom::children(body),
            None => dom::children(&document),
        };

        let mut children = Vec::new();
        for child in &content {
            if let Some(index) = self.walk(child, false) {
                children.push(index);
            }
        }

        self.nodes[root].children = children;
        self.nodes[root].text_range = (0, self.utf16_len);
        BlockTree {
            nodes: self.nodes,
            text: self.text,
            remote_fetches: 0,
            dropped_scripts: self.dropped_scripts,
        }
    }

    /// Returns the arena index of the node built, or `None` for text/ignored
    /// nodes (text is folded into the shared buffer, not a node).
    fn walk(&mut self, node: &Handle, in_pre: bool) -> Option<usize> {
        if let Some(text) = dom::text(node) {
            // Whitespace between block elements is layout, not content; inside
            // `<pre>` it is significant and kept verbatim.
            if text.is_empty() || (!in_pre && text.chars().all(char::is_whitespace)) {
                return None;
            }
            self.utf16_len += text.encode_utf16().count();
            self.text.push_str(&text);
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

        let kind = kind_of(&name);
        let attrs = attrs_of(&name, node);
        let index = self.push(kind, (self.utf16_len, self.utf16_len), attrs);

        let in_pre = in_pre || name == "pre";
        let mut children = Vec::new();
        for child in dom::children(node) {
            if let Some(child_index) = self.walk(&child, in_pre) {
                children.push(child_index);
            }
        }
        self.nodes[index].children = children;
        // The node's range now spans every descendant text node appended.
        self.nodes[index].text_range.1 = self.utf16_len;
        Some(index)
    }

    fn push(&mut self, kind: BlockKind, text_range: (usize, usize), attrs: Attrs) -> usize {
        self.nodes.push(BlockNode {
            kind,
            text_range,
            children: Vec::new(),
            attrs,
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
        assert!(kinds.contains(&BlockKind::Heading(1)));
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
            .find(|n| matches!(n.kind, BlockKind::Heading(_)))
            .expect("heading");
        assert_eq!(heading.kind, BlockKind::Heading(3));
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
    fn whitespace_between_blocks_is_not_content_but_pre_is_kept() {
        assert_eq!(text_of("<body>\n  <p>a</p>\n  <p>b</p>\n</body>"), "ab");
        assert_eq!(text_of("<body><pre>  x  </pre></body>"), "  x  ");
    }

    #[test]
    fn utf16_slice_handles_non_bmp() {
        assert_eq!(utf16_slice("A\u{1F600}B", 0, 4), "A\u{1F600}B");
        assert_eq!(utf16_slice("A\u{1F600}B", 0, 3), "A\u{1F600}");
        assert_eq!(utf16_slice("A\u{1F600}B", 3, 4), "B");
    }
}
