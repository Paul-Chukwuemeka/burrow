//! Flat-run projection: the block tree + computed styles lowered into today's
//! `ChapterDto` (spec D4/D6/D12, Phase-A contract).
//!
//! The projection reproduces the *shape* of the existing Dart `Chapter` — a
//! flat `body` string with `\u{FFFC}` image placeholders, `StyleRun`s over that
//! body, and `ImageRun` sizing/reference metadata — from the structured block
//! tree. Offsets are **Dart UTF-16 code units** (D4), images become a single
//! placeholder each, and `%` box lengths stay symbolic (`CssLengthDto::is_percent`)
//! so `max-width: 100%` is never resolved at parse time.
//!
//! Two contracts are deliberate:
//!
//! * **Whitespace** is collapsed exactly like Dart's `_RichTextBuilder` (block
//!   tags insert newlines that collapse to at most two; horizontal whitespace
//!   collapses to one space and is dropped around line breaks), so an unstyled
//!   book's body is byte-identical to the Dart engine's.
//! * **UTF-16 offsets** are emitted, not Rust byte offsets: `units.rs` converts
//!   the byte offsets recorded while building the body once it is final, so a
//!   non-BMP character does not shift the runs and images after it (Review
//!   Focus #1).
//!
//! The `css` on a run is built only from properties the element actually
//! *declared* (author rule / presentational hint / inline style); UA defaults
//! stay on the block tree (D12), which is what keeps an unstyled book's flat
//! output style-free.

use crate::epub::block::utf16_slice;
use crate::epub::cascade::ComputedStyle;
use crate::epub::container::{decode_percent, resolve_href, EpubArchive};
use crate::epub::model::{BlockKind, BlockTree};
use crate::epub::units;

use std::collections::HashMap;
use std::collections::HashSet;

/// A whole chapter projected into the flat-run model.
///
/// `blocks` is the block-tree arena in its original UTF-16 coordinates (an
/// additive field per D17); `body`/`runs`/`images` are the phase-1 render
/// contract and are unchanged from the Dart engine's output shape.
///
/// Phase-A policy (final fix): chapters produced by [`split_chapters`] — the
/// path behind the `chapter()` FFI — carry an **empty** `blocks`. The arena
/// was cloned once per split chapter and discarded by the Dart adapter, so
/// crossing it cost O(chapters × tree) for no consumer. The tree itself stays
/// reachable through the dedicated `block_tree()` FFI (which returns the real
/// [`BlockTree`](crate::epub::model::BlockTree)); `blocks` here is reserved
/// for Phase B landing it on the domain `Chapter` with a cache-schema bump.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct ChapterDto {
    pub title: String,
    pub body: String,
    pub runs: Vec<StyleRunDto>,
    pub images: Vec<ImageRunDto>,
    pub blocks: Vec<BlockDto>,
    /// Resolved in-book links: chapter-local UTF-16 ranges jumping to global
    /// chapter indices. Empty for the txt/cbz legs; see [`resolve_split_links`].
    pub links: Vec<LinkDto>,
}

/// A tappable in-book link, projection-local (UTF-16 code units against the
/// chapter's own body): `target` is the global chapter index it jumps to.
/// Links that resolve nowhere (external http(s), missing anchors) never cross
/// the FFI.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct LinkDto {
    pub start: u32,
    pub end: u32,
    pub target: u32,
}

/// A structural block, projected so a future paginator can reach the tree
/// through the same call as the flat runs. `text_range` indexes the tree's own
/// text buffer (UTF-16), not the flat body.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct BlockDto {
    pub kind: BlockKind,
    pub heading_level: Option<u8>,
    pub text_range: (u32, u32),
    pub children: Vec<u32>,
}

/// One styled range over [`ChapterDto::body`].
///
/// `start`/`end` are UTF-16 code units (Dart `String.substring` indices) and are
/// half-open. `bold`/`italic`/`quote` carry the emphasis/blockquote flags; `css`
/// carries author-declared typography (never UA defaults).
#[derive(Debug, Clone, PartialEq, Default)]
pub struct StyleRunDto {
    pub start: u32,
    pub end: u32,
    pub bold: bool,
    pub italic: bool,
    pub quote: bool,
    pub css: Option<CssStyleDto>,
}

/// One inline image, occupying a single `\u{FFFC}` at `offset` in the body.
///
/// `source_key` is the normalised archive entry the image resolves to (the
/// reference Dart hydrates bytes from, D15); it is `None` when the `src` does
/// not resolve to an entry. `intrinsic_w`/`intrinsic_h` are read from the image
/// header, `0` when unknown. No bytes cross the FFI here.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct ImageRunDto {
    pub offset: u32,
    pub intrinsic_w: u32,
    pub intrinsic_h: u32,
    pub alt: String,
    pub full_width: bool,
    pub source_key: Option<String>,
    pub img_src: String,
    pub img_class: String,
    pub element_id: String,
    pub html_w: Option<f64>,
    pub html_h: Option<f64>,
    pub css: Option<CssStyleDto>,
}

/// A box length that is either absolute pixels or a percentage of the
/// containing block (mirrors `CssLength`).
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct CssLengthDto {
    pub value: f64,
    pub is_percent: bool,
}

/// The typography a run/image carries, mirroring `CssStyle` field for field so
/// the Dart adapter can reconstruct it with the existing `CssStyle.fromJson`.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct CssStyleDto {
    pub font_size: Option<f64>,
    pub color: Option<u32>,
    pub text_align: Option<String>,
    pub text_indent: Option<f64>,
    pub margin_left: Option<f64>,
    pub margin_right: Option<f64>,
    pub margin_top: Option<f64>,
    pub margin_bottom: Option<f64>,
    pub font_weight: Option<f64>,
    pub font_style: Option<String>,
    pub text_decoration: Option<String>,
    pub font_family: Option<String>,
    pub line_height: Option<f64>,
    pub letter_spacing: Option<f64>,
    pub word_spacing: Option<f64>,
    pub text_transform: Option<String>,
    pub white_space: Option<String>,
    pub width: Option<CssLengthDto>,
    pub height: Option<CssLengthDto>,
    pub max_width: Option<CssLengthDto>,
    pub max_height: Option<CssLengthDto>,
}

impl CssStyleDto {
    /// True when no property was set (so no run is worth emitting).
    pub fn is_empty(&self) -> bool {
        *self == CssStyleDto::default()
    }

    /// Overlays `other` on `self`: every property `other` sets wins (the same
    /// rule as `CssStyle.merge`, applied outer-first).
    pub fn merge(&self, other: &CssStyleDto) -> CssStyleDto {
        macro_rules! pick {
            ($field:ident) => {
                other.$field.clone().or_else(|| self.$field.clone())
            };
        }
        CssStyleDto {
            font_size: pick!(font_size),
            color: pick!(color),
            text_align: pick!(text_align),
            text_indent: pick!(text_indent),
            margin_left: pick!(margin_left),
            margin_right: pick!(margin_right),
            margin_top: pick!(margin_top),
            margin_bottom: pick!(margin_bottom),
            font_weight: pick!(font_weight),
            font_style: pick!(font_style),
            text_decoration: pick!(text_decoration),
            font_family: pick!(font_family),
            line_height: pick!(line_height),
            letter_spacing: pick!(letter_spacing),
            word_spacing: pick!(word_spacing),
            text_transform: pick!(text_transform),
            white_space: pick!(white_space),
            width: pick!(width),
            height: pick!(height),
            max_width: pick!(max_width),
            max_height: pick!(max_height),
        }
    }

    /// True when any image-sizing property was declared (used to decide whether
    /// an `<img>`'s CSS belongs on its [`ImageRunDto`]).
    pub fn has_image_sizing(&self) -> bool {
        self.width.is_some()
            || self.height.is_some()
            || self.max_width.is_some()
            || self.max_height.is_some()
    }
}

/// One table-of-contents entry targeting a spine document, in document order.
///
/// This is the projection's view of [`TocEntryDto`](crate::epub::model::TocEntryDto):
/// `fragment` is the raw (still percent-encoded) anchor id, or `None` when the
/// entry targets the whole document.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct SplitEntry {
    pub fragment: Option<String>,
    pub title: String,
}

/// Projects a styled chapter into a [`ChapterDto`].
///
/// `chapter_key` is the chapter's normalised archive key (its directory is the
/// base for resolving image `src`s); `archive` supplies image bytes for the
/// intrinsic-size read. `cover_hrefs` are the OPF-declared cover keys (see
/// `Navigation::cover_hrefs`): an image resolving to one is full-width, exactly
/// like Dart's `coverHrefs` check alongside the id/filename "cover" match.
pub fn project_tree(
    tree: &BlockTree,
    title: String,
    archive: &EpubArchive,
    chapter_key: &str,
    cover_hrefs: &HashSet<String>,
) -> ChapterDto {
    let base_dir = dir_of(chapter_key);
    project_with(tree, title, cover_hrefs, |src| {
        let key = resolve_href(&base_dir, src);
        let bytes = archive.read_by_key(&key);
        (key, bytes)
    })
}

/// Projects one spine document into one chapter per TOC anchor, in document
/// order (mirroring Dart's `DocumentParser.splitByAnchors`).
///
/// `entries` are the TOC entries targeting this document. Each entry whose
/// fragment resolves to an anchor becomes its own chapter; text before the
/// first anchor becomes an untitled leading chapter; entries whose fragment is
/// absent are ignored. When `entries` is empty the document stays whole under
/// `fallback_title` (no heading strip, matching the Dart engine whose title is
/// empty there). Every other chapter drops a leading body line repeating its
/// title (Dart's `_stripDuplicateHeading`), and runs/images are rebased to
/// slice-local offsets (Dart's `_sliceRuns`/`_sliceImages`). All offsets stay
/// Dart UTF-16 code units.
pub fn project_split(
    tree: &BlockTree,
    fallback_title: String,
    entries: &[SplitEntry],
    archive: &EpubArchive,
    chapter_key: &str,
    cover_hrefs: &HashSet<String>,
) -> Vec<ChapterDto> {
    let base_dir = dir_of(chapter_key);
    project_split_with(tree, fallback_title, entries, cover_hrefs, |src| {
        let key = resolve_href(&base_dir, src);
        let bytes = archive.read_by_key(&key);
        (key, bytes)
    })
}

/// [`project_split`] carrying the link-resolution inputs ([`SplitDoc`]).
pub fn project_split_ext(
    tree: &BlockTree,
    fallback_title: String,
    chapter_key: &str,
    entries: &[SplitEntry],
    archive: &EpubArchive,
    cover_hrefs: &HashSet<String>,
) -> SplitDoc {
    let base_dir = dir_of(chapter_key);
    project_split_ext_with(tree, fallback_title, chapter_key, entries, cover_hrefs, |src| {
        let key = resolve_href(&base_dir, src);
        let bytes = archive.read_by_key(&key);
        (key, bytes)
    })
}

/// [`project_split`] with an injectable resource reader, so the anchor-split
/// behaviour is testable without a real archive.
pub fn project_split_with<F>(
    tree: &BlockTree,
    fallback_title: String,
    entries: &[SplitEntry],
    cover_hrefs: &HashSet<String>,
    read: F,
) -> Vec<ChapterDto>
where
    F: Fn(&str) -> (String, Option<Vec<u8>>),
{
    project_split_ext_with(
        tree,
        fallback_title,
        "",
        entries,
        cover_hrefs,
        read,
    )
    .chapters
}

/// [`project_split`] carrying what the link resolver needs: the document's
/// own key, per-chapter href links, the chapter starts, and the anchor map.
pub fn project_split_ext_with<F>(
    tree: &BlockTree,
    fallback_title: String,
    chapter_key: &str,
    entries: &[SplitEntry],
    cover_hrefs: &HashSet<String>,
    read: F,
) -> SplitDoc
where
    F: Fn(&str) -> (String, Option<Vec<u8>>),
{
    let (mut full, anchors, links) = project_full_with(tree, String::new(), cover_hrefs, read);
    if entries.is_empty() {
        // Whole document: one chapter under the fallback title, no heading
        // strip (matching the Dart engine, whose title is empty there). The
        // chapter-local link offsets equal the full-document ones.
        full.title = fallback_title;
        let doc_len = units::utf16_len(&full.body);
        return SplitDoc {
            key: chapter_key.to_string(),
            chapters: vec![full],
            links: vec![slice_links(&links, 0, doc_len)],
            starts: vec![0],
            anchors,
        };
    }
    let (pairs, starts) = split_chapters_ext(full, &links, entries, &anchors);
    let mut chapters = Vec::with_capacity(pairs.len());
    let mut links_ch = Vec::with_capacity(pairs.len());
    for (ch, links) in pairs {
        chapters.push(ch);
        links_ch.push(links);
    }
    SplitDoc {
        key: chapter_key.to_string(),
        chapters,
        links: links_ch,
        starts,
        anchors,
    }
}

/// Projection with an injectable resource reader, so the string behaviour is
/// testable without a real archive. `read(src)` returns the resolved archive
/// key and its bytes (if any).
pub fn project_with<F>(
    tree: &BlockTree,
    title: String,
    cover_hrefs: &HashSet<String>,
    read: F,
) -> ChapterDto
where
    F: Fn(&str) -> (String, Option<Vec<u8>>),
{
    project_full_with(tree, title, cover_hrefs, read).0
}

/// The full-document projection plus its anchor map and its raw link list.
///
/// The body/runs/images are the unsplit document (Task 7 output); `anchors`
/// maps every `id`/`<a name>` id to the UTF-16 offset of the first visible
/// character following it — the split positions [`split_chapters`] uses.
/// `links` are the collected `<a href>` extents (see [`RawLink`]); they attach
/// to chapters after [`split_chapters`] slices them.
fn project_full_with<F>(
    tree: &BlockTree,
    title: String,
    cover_hrefs: &HashSet<String>,
    read: F,
) -> (ChapterDto, HashMap<String, u32>, Vec<RawLink>)
where
    F: Fn(&str) -> (String, Option<Vec<u8>>),
{
    let mut projector = Projector {
        tree,
        read,
        cover_hrefs,
        body: String::new(),
        runs: Vec::new(),
        images: Vec::new(),
        anchors: HashMap::new(),
        pending_anchors: Vec::new(),
        node_start: vec![None; tree.nodes.len()],
        node_end: vec![0; tree.nodes.len()],
        open: Vec::new(),
        links: Vec::new(),
        pending_newlines: 0,
        pending_space: false,
        last_char: None,
        bold: 0,
        italic: 0,
        quote: 0,
    };
    projector.walk();
    projector.finish(title)
}

/// The directory part of a normalised archive key, or `""` at the root.
fn dir_of(key: &str) -> String {
    match key.rfind('/') {
        Some(index) => key[..index].to_string(),
        None => String::new(),
    }
}

/// Block tags whose open/close each contribute a (collapsible) newline.
///
/// This is intentionally the *Dart* `_blockTagNames` set, not [`BlockKind`]:
/// the projection reproduces the Dart renderer's wrapping, where e.g. `<ul>`
/// and `<pre>` are transparent and only `li` breaks.
const BLOCK_TAGS: &[&str] = &[
    "p",
    "div",
    "h1",
    "h2",
    "h3",
    "h4",
    "h5",
    "h6",
    "li",
    "tr",
    "br",
    "section",
    "article",
    "blockquote",
];

fn is_block_tag(tag: &str) -> bool {
    BLOCK_TAGS.contains(&tag)
}

/// True for whitespace that right-trims the body, matching Dart's `_isWs`.
fn is_trim_ws(ch: char) -> bool {
    matches!(ch, ' ' | '\t' | '\n' | '\r')
}

/// True for HTML collapsible whitespace (space, tab, CR, LF, FF, VT), the
/// class the body tokenizer splits on.
///
/// A newline inside a text node is *not* a block break: EPUB XHTML is routinely
/// hard-wrapped mid-paragraph, and browsers collapse those source newlines to a
/// single space. Leaving `\n` out of this class made a `"\nword"` token look
/// like pending whitespace and dropped `word` entirely.
fn is_ws_token_char(ch: char) -> bool {
    matches!(ch, ' ' | '\t' | '\n' | '\r' | '\u{0C}' | '\u{0B}')
}

/// An action on the explicit walk stack (keeps deep nesting off the call stack).
enum Action {
    Enter(usize),
    Exit(usize),
    /// Emit the given UTF-16 range of the tree's text buffer.
    Text(u32, u32),
}

/// A run recorded mid-walk, in *byte* offsets until [`Projector::finish`].
#[derive(Debug)]
struct RawRun {
    start: usize,
    end: usize,
    bold: bool,
    italic: bool,
    quote: bool,
    css: Option<CssStyleDto>,
}

/// A not-yet-emitted image, in *byte* offsets until [`Projector::finish`].
struct RawImage {
    offset: usize,
    intrinsic_w: u32,
    intrinsic_h: u32,
    alt: String,
    full_width: bool,
    source_key: Option<String>,
    img_src: String,
    img_class: String,
    element_id: String,
    html_w: Option<f64>,
    html_h: Option<f64>,
    css: Option<CssStyleDto>,
}

/// A node currently on the open path, with the byte offset of its first text.
/// `href` carries the target of an open `<a href>` for the link-extent seal.
struct OpenNode {
    index: usize,
    start: Option<usize>,
    href: Option<String>,
}

/// An in-book link collected from an `<a href>` extent, in UTF-16 code units
/// against the projected body (`href` is the raw attribute value). Still
/// unresolved: `resolve_split_links` maps each to a global chapter index.
#[derive(Debug, Clone)]
struct RawLink {
    start: u32,
    end: u32,
    href: String,
}

struct Projector<'a, F> {
    tree: &'a BlockTree,
    read: F,
    /// OPF-declared cover keys (Dart's `coverHrefs`), for full-width marking.
    cover_hrefs: &'a HashSet<String>,
    body: String,
    runs: Vec<RawRun>,
    images: Vec<RawImage>,
    /// `id`/`<a name>` ids to the byte offset of the first visible character
    /// following them (converted to UTF-16 in [`Projector::finish`]).
    anchors: HashMap<String, usize>,
    /// Ids seen but not yet resolved to an offset (Dart's `_pendingAnchors`).
    pending_anchors: Vec<String>,
    node_start: Vec<Option<usize>>,
    node_end: Vec<usize>,
    open: Vec<OpenNode>,
    /// `<a href>` extents as body-byte offsets, sealed at [`Projector::exit`]
    /// and converted to UTF-16 in [`Projector::finish`].
    links: Vec<(usize, usize, String)>,
    pending_newlines: usize,
    pending_space: bool,
    last_char: Option<char>,
    bold: u32,
    italic: u32,
    quote: u32,
}

impl<'a, F> Projector<'a, F>
where
    F: Fn(&str) -> (String, Option<Vec<u8>>),
{
    fn walk(&mut self) {
        let mut stack = vec![Action::Enter(0)];
        while let Some(action) = stack.pop() {
            match action {
                Action::Enter(index) => self.enter(index, &mut stack),
                Action::Exit(index) => self.exit(index),
                Action::Text(start, end) => self.emit_text_slice(start, end),
            }
        }
    }

    /// Opens node `index`: applies its tag's whitespace/emphasis effect and
    /// schedules its direct text and children in document order.
    fn enter(&mut self, index: usize, stack: &mut Vec<Action>) {
        let (tag, id, name, text_range, children) = {
            let node = &self.tree.nodes[index];
            (
                node.attrs.tag.clone(),
                node.attrs.id.clone(),
                node.attrs.name.clone(),
                node.text_range,
                node.children.clone(),
            )
        };

        // An `<img>` is emitted in place and has no children (and no closing
        // newline): it never joins the open stack.
        if tag == "img" {
            self.emit_image(index);
            return;
        }

        // Anchor targets: `id` on any element, plus legacy `<a name="...">`
        // (matching Dart's `_handleTag`). Registration is deferred: the offset
        // resolves at the next emitted token, after pending breaks, so slicing
        // there never cuts a word and the break belongs to the prior section.
        if let Some(id) = id {
            self.anchor(&id);
        }
        if tag == "a" {
            if let Some(name) = name {
                self.anchor(&name);
            }
        }

        if is_block_tag(&tag) {
            self.newline();
        }
        if tag == "blockquote" {
            self.quote += 1;
        }
        if tag == "b" || tag == "strong" {
            self.flush_space();
            self.bold += 1;
        }
        if tag == "i" || tag == "em" {
            self.flush_space();
            self.italic += 1;
        }

        self.open.push(OpenNode {
            index,
            start: None,
            href: if tag == "a" {
                self.tree.nodes[index].attrs.href.clone()
            } else {
                None
            },
        });
        stack.push(Action::Exit(index));

        // Direct text = the parent's range minus its children's ranges, in order.
        let mut items: Vec<Action> = Vec::new();
        let mut cursor = text_range.0;
        for &child in &children {
            let (child_start, child_end) = {
                let node = &self.tree.nodes[child as usize];
                node.text_range
            };
            if child_start > cursor {
                items.push(Action::Text(cursor, child_start));
            }
            items.push(Action::Enter(child as usize));
            cursor = cursor.max(child_end);
        }
        if text_range.1 > cursor {
            items.push(Action::Text(cursor, text_range.1));
        }
        for item in items.into_iter().rev() {
            stack.push(item);
        }
    }

    /// Closes node `index`: undoes its effects and seals its text extent.
    fn exit(&mut self, index: usize) {
        let tag = self.tree.nodes[index].attrs.tag.clone();
        if tag == "b" || tag == "strong" {
            self.flush_space();
            self.bold = self.bold.saturating_sub(1);
        }
        if tag == "i" || tag == "em" {
            self.flush_space();
            self.italic = self.italic.saturating_sub(1);
        }
        if tag == "blockquote" {
            self.quote = self.quote.saturating_sub(1);
        }
        if is_block_tag(&tag) && tag != "br" {
            self.newline();
        }
        if let Some(node) = self.open.pop() {
            if let Some(start) = node.start {
                self.node_start[node.index] = Some(start);
                self.node_end[node.index] = self.body.len();
                // An `<a href>` whose extent holds visible body text becomes a
                // link candidate: its end seals here (byte offsets; `finish`
                // clamps them against the trimmed body, so a whitespace tail
                // never widens the tap range). The recorded start sits before
                // the lazy-fit collapse; skip the flushed leading space that
                // the collapse folded in there, so the tap range starts at the
                // first linked character. Empty anchors (image-only or pure
                // whitespace) produce nothing.
                if tag == "a" && node.href.is_some() {
                    let mut bytes = self.body.as_bytes();
                    let mut first_text = start;
                    while first_text < bytes.len()
                        && matches!(bytes[first_text], b' ' | b'\n')
                    {
                        first_text += 1;
                    }
                    if first_text < bytes.len() {
                        self.links.push((first_text, self.body.len(), node.href.unwrap()));
                    }
                }
            }
        }
    }

    /// Emits one tree-text range, applying the Dart whitespace collapse.
    fn emit_text_slice(&mut self, start: u32, end: u32) {
        let tree = self.tree;
        let raw: &str = utf16_slice(&tree.text, start as usize, end as usize);
        if raw.is_empty() {
            return;
        }
        let mut tokens: Vec<&str> = Vec::new();
        let mut run_start = 0usize;
        let mut run_is_ws: Option<bool> = None;
        for (index, ch) in raw.char_indices() {
            let is_ws = is_ws_token_char(ch);
            match run_is_ws {
                None => {
                    run_start = index;
                    run_is_ws = Some(is_ws);
                }
                Some(previous) if previous != is_ws => {
                    tokens.push(&raw[run_start..index]);
                    run_start = index;
                    run_is_ws = Some(is_ws);
                }
                _ => {}
            }
        }
        if run_is_ws.is_some() {
            tokens.push(&raw[run_start..]);
        }
        for token in tokens {
            self.emit_token(token);
        }
    }

    /// Emits one whitespace-collapsed token, applying pending-space/newline.
    fn emit_token(&mut self, token: &str) {
        let Some(head) = token.chars().next() else {
            return;
        };
        if is_ws_token_char(head) {
            self.pending_space = true;
            return;
        }
        if self.pending_newlines > 0 && !self.body.is_empty() {
            let count = self.pending_newlines.min(2);
            self.push_newlines(count);
        }
        self.pending_newlines = 0;
        if self.pending_space && !self.body.is_empty() && self.last_char != Some('\n') {
            self.emit(" ");
        }
        self.pending_space = false;
        // Newlines and the separating space belong to the preceding text, not
        // to the anchored section (matching Dart's `text()`).
        self.resolve_pending();
        self.emit(token);
    }

    /// Records an anchor id, resolved to the offset of the next visible
    /// character. First declaration wins, matching how browsers treat
    /// duplicate ids (and Dart's `anchor()`).
    fn anchor(&mut self, id: &str) {
        if id.is_empty() || self.anchors.contains_key(id) {
            return;
        }
        self.pending_anchors.push(id.to_string());
    }

    /// Resolves every pending anchor to the current body end.
    fn resolve_pending(&mut self) {
        if self.pending_anchors.is_empty() {
            return;
        }
        let at = self.body.len();
        for id in std::mem::take(&mut self.pending_anchors) {
            self.anchors.insert(id, at);
        }
    }

    /// Emits an `<img>`: flushes pending whitespace, writes the `\u{FFFC}`
    /// placeholder, and records the image's reference and sizing metadata.
    fn emit_image(&mut self, index: usize) {
        let attrs = self.tree.nodes[index].attrs.clone();
        // The image's own `id` anchors the placeholder itself: Dart registers
        // the id when the tag opens, before `image()` resolves it.
        if let Some(id) = attrs.id.as_deref() {
            self.anchor(id);
        }
        let Some(src) = attrs.src.clone().filter(|s| !s.is_empty()) else {
            return;
        };

        self.flush_space();
        if self.pending_newlines > 0 && !self.body.is_empty() {
            let count = self.pending_newlines.min(2);
            self.push_newlines(count);
        }
        self.pending_newlines = 0;
        self.pending_space = false;
        self.resolve_pending();

        let offset = self.body.len();
        self.body.push('\u{FFFC}');
        self.last_char = Some('\u{FFFC}');

        let (key, bytes) = (self.read)(&src);
        // Resolve the OPF-cover check before `key` moves into `source_key`.
        let is_opf_cover = self.cover_hrefs.contains(&key);
        let source_key = bytes.as_ref().map(|_| key);
        let (intrinsic_w, intrinsic_h) = bytes.as_deref().map(image_dimensions).unwrap_or((0, 0));

        let file_name = src
            .split('?')
            .next()
            .unwrap_or("")
            .rsplit('/')
            .next()
            .unwrap_or("")
            .to_lowercase();
        let id_cover = attrs
            .id
            .as_deref()
            .map(|id| id.to_lowercase().contains("cover"))
            .unwrap_or(false);
        // Dart's cover rule: id or filename containing "cover", or the image
        // resolving to an OPF-declared cover href. `key` is the resolved
        // normalised archive key, directly comparable to `cover_hrefs`.
        let full_width = id_cover || file_name.contains("cover") || is_opf_cover;

        let css = css_style_from_declared(&self.tree.nodes[index].style)
            .filter(CssStyleDto::has_image_sizing);

        self.images.push(RawImage {
            offset,
            intrinsic_w,
            intrinsic_h,
            alt: attrs.alt.clone().unwrap_or_default(),
            full_width,
            source_key,
            img_src: src,
            img_class: attrs.class.clone().unwrap_or_default(),
            element_id: attrs.id.clone().unwrap_or_default(),
            html_w: attrs.width.as_deref().and_then(parse_plain_number),
            html_h: attrs.height.as_deref().and_then(parse_plain_number),
            css,
        });
    }

    /// A block/line break: collapses with adjacent breaks, drops pending space.
    fn newline(&mut self) {
        self.pending_newlines += 1;
    }

    /// Writes `count` literal newlines (not a run, matching Dart's builder).
    fn push_newlines(&mut self, count: usize) {
        for _ in 0..count {
            self.body.push('\n');
        }
        self.last_char = Some('\n');
    }

    /// Emits any pending space now, stamped with the *current* style.
    fn flush_space(&mut self) {
        if !self.pending_space {
            return;
        }
        if !self.body.is_empty() && self.last_char != Some('\n') {
            self.emit(" ");
        }
        self.pending_space = false;
    }

    /// Appends a rendered token, crediting every open node and recording any
    /// emphasis run it falls in.
    fn emit(&mut self, token: &str) {
        let start = self.body.len();
        for node in &mut self.open {
            if node.start.is_none() {
                node.start = Some(start);
            }
            self.node_end[node.index] = start + token.len();
        }
        self.body.push_str(token);
        self.last_char = token.chars().last();

        if self.bold > 0 || self.italic > 0 || self.quote > 0 {
            let (bold, italic, quote) = (self.bold > 0, self.italic > 0, self.quote > 0);
            let end = start + token.len();
            if let Some(last) = self.runs.last_mut() {
                if last.end == start
                    && last.css.is_none()
                    && (last.bold, last.italic, last.quote) == (bold, italic, quote)
                {
                    last.end = end;
                    return;
                }
            }
            self.runs.push(RawRun {
                start,
                end,
                bold,
                italic,
                quote,
                css: None,
            });
        }
    }

    /// Trims the body, converts byte offsets to UTF-16, and assembles the DTO,
    /// plus the anchor map in UTF-16 coordinates.
    fn finish(mut self, title: String) -> (ChapterDto, HashMap<String, u32>, Vec<RawLink>) {
        let end = self.body.trim_end_matches(is_trim_ws).len();
        self.body.truncate(end);

        // Trailing anchors had no following text; park them at the very end so
        // they resolve to an empty slice and get dropped rather than
        // mis-titling the preceding section (matching Dart's `finish()`).
        for id in std::mem::take(&mut self.pending_anchors) {
            self.anchors.insert(id, end);
        }

        // Promote a large standalone image to full width (mirrors Dart).
        for image in &mut self.images {
            if !image.full_width && image.offset < end {
                let largest = image.intrinsic_w.max(image.intrinsic_h);
                if largest >= 400 && is_standalone(&self.body, image.offset) {
                    image.full_width = true;
                }
            }
        }

        let offsets = units::utf16_offsets(&self.body);

        let base = std::mem::take(&mut self.runs);
        let css_runs = self.declared_css_runs(end);
        let merged = merge_runs(base, css_runs, end);

        let runs = merged
            .into_iter()
            .map(|run| StyleRunDto {
                start: offsets[run.start],
                end: offsets[run.end],
                bold: run.bold,
                italic: run.italic,
                quote: run.quote,
                css: run.css,
            })
            .collect();

        let images = self
            .images
            .into_iter()
            .filter(|image| image.offset < end)
            .map(|image| ImageRunDto {
                offset: offsets[image.offset],
                intrinsic_w: image.intrinsic_w,
                intrinsic_h: image.intrinsic_h,
                alt: image.alt,
                full_width: image.full_width,
                source_key: image.source_key,
                img_src: image.img_src,
                img_class: image.img_class,
                element_id: image.element_id,
                html_w: image.html_w,
                html_h: image.html_h,
                css: image.css,
            })
            .collect();

        let blocks = self
            .tree
            .nodes
            .iter()
            .map(|node| BlockDto {
                kind: node.kind,
                heading_level: node.heading_level,
                text_range: node.text_range,
                children: node.children.clone(),
            })
            .collect();

        let anchors = self
            .anchors
            .into_iter()
            .map(|(id, byte)| (id, offsets[byte]))
            .collect();

        // Link extents share the runs' byte→UTF-16 promotion; clamped against
        // the trimmed body so a whitespace tail does not widen the range.
        let links = self
            .links
            .into_iter()
            .filter_map(|(start, end, href)| {
                let end = end.min(self.body.len());
                if end <= start {
                    return None;
                }
                Some(RawLink {
                    start: offsets[start],
                    end: offsets[end],
                    href,
                })
            })
            .collect();

        (
            ChapterDto {
                title,
                body: self.body,
                runs,
                images,
                blocks,
                links: Vec::new(),
            },
            anchors,
            links,
        )
    }

    /// Author-declared styles over each node's body extent, as runs.
    ///
    /// This replaces the Dart engine's `body.indexOf(element.text)` heuristic
    /// with the node's real extent, so repeated identical paragraphs and
    /// descendant combinators style the *correct* instance (spec D11, Review
    /// Focus #2). Elements with no declared CSS produce nothing.
    fn declared_css_runs(&self, limit: usize) -> Vec<RawRun> {
        let mut out = Vec::new();
        for (index, start) in self.node_start.iter().enumerate() {
            let Some(start) = *start else { continue };
            let end = self.node_end[index].min(limit);
            if start >= end {
                continue;
            }
            if let Some(css) = css_style_from_declared(&self.tree.nodes[index].style) {
                if !css.is_empty() {
                    out.push(RawRun {
                        start,
                        end,
                        bold: false,
                        italic: false,
                        quote: false,
                        css: Some(css),
                    });
                }
            }
        }
        out
    }
}

/// Splits base emphasis runs and CSS runs into a maximal constant-style cover.
///
/// Boundaries of both sets become cut points; each elementary interval takes the
/// covering base run's emphasis and the merged (outer-first) CSS of every
/// covering CSS run, then adjacent equal intervals coalesce. This mirrors the
/// intent of Dart's `_applyCssRanges` while keeping correct node extents.
///
/// Both sets funnel through the same partition even when only one of them is
/// non-empty: `declared_css_runs` emits one run per styled node, so its ranges
/// nest (and sometimes share extents), and a CSS-only chapter must still be
/// partitioned. Returning that raw list would hand consumers overlapping runs;
/// the reader's paginator re-emits duplicated text while measuring and dies
/// inside its first layout pass.
fn merge_runs(mut base: Vec<RawRun>, mut css: Vec<RawRun>, limit: usize) -> Vec<RawRun> {
    for run in base.iter_mut().chain(css.iter_mut()) {
        run.end = run.end.min(limit);
    }
    base.retain(|run| run.start < run.end);
    css.retain(|run| run.start < run.end);

    let mut points: Vec<usize> = Vec::new();
    for run in base.iter().chain(css.iter()) {
        points.push(run.start);
        points.push(run.end);
    }
    points.sort_unstable();
    points.dedup();

    // Outer-first so a nested rule's declaration wins when merging.
    css.sort_by(|a, b| a.start.cmp(&b.start).then(b.end.cmp(&a.end)));

    // Sweep the windows with advancing pointers: a window lies between two
    // consecutive boundaries, so a run either covers it entirely or misses it,
    // and the covering sets change only by pushes/expiries. Scanning both sets
    // per window is O(windows × runs) — quadratic on class-heavy books.
    let mut base_next = 0;
    let mut css_next = 0;
    let mut active: Vec<usize> = Vec::new();
    let mut out: Vec<RawRun> = Vec::new();
    for window in points.windows(2) {
        let (start, end) = (window[0], window[1]);
        if start >= end {
            continue;
        }
        while base_next < base.len() && base[base_next].end <= start {
            base_next += 1;
        }
        let covering_base = base
            .get(base_next)
            .filter(|run| run.start <= start);
        while css_next < css.len() && css[css_next].start <= start {
            active.push(css_next);
            css_next += 1;
        }
        active.retain(|&index| css[index].end > start);
        let mut acc: Option<CssStyleDto> = None;
        for &index in &active {
            if let Some(css) = &css[index].css {
                acc = Some(match acc {
                    None => css.clone(),
                    Some(previous) => previous.merge(css),
                });
            }
        }
        if covering_base.is_none() && acc.is_none() {
            continue;
        }
        let (bold, italic, quote) = covering_base
            .map(|run| (run.bold, run.italic, run.quote))
            .unwrap_or((false, false, false));
        let run = RawRun {
            start,
            end,
            bold,
            italic,
            quote,
            css: acc,
        };
        if let Some(last) = out.last_mut() {
            if last.end == start
                && (last.bold, last.italic, last.quote) == (bold, italic, quote)
                && last.css == run.css
            {
                last.end = end;
                continue;
            }
        }
        out.push(run);
    }
    out
}

/// Cuts one projected spine document into a chapter per TOC entry.
///
/// A direct port of Dart's `DocumentParser.splitByAnchors` into the flat
/// DTO's UTF-16 offset space: `cuts` maps an offset to its title (first entry
/// wins when two anchors land together), entries whose fragment is absent are
/// ignored, text before the first anchor becomes an untitled leading chapter,
/// and empty slices are dropped. When no entry resolves, the document stays
/// whole under the first entry's title. Every surviving chapter drops a
/// leading line repeating its title ([`strip_duplicate_heading`]).
pub fn split_chapters(
    full: ChapterDto,
    entries: &[SplitEntry],
    anchors: &HashMap<String, u32>,
) -> Vec<ChapterDto> {
    split_chapters_ext(full, &[], entries, anchors)
        .0
        .into_iter()
        .map(|(ch, _)| ch)
        .collect()
}

/// [`split_chapters`] also returning each chapter's href-carrying links,
/// rebased to slice-local offsets (and past the heading strip) in lockstep
/// with the chapter itself, plus the chapter starts in the full-document
/// UTF-16 space for the resolver. Target resolution happens later, in
/// [`resolve_split_links`].
fn split_chapters_ext(
    full: ChapterDto,
    links: &[RawLink],
    entries: &[SplitEntry],
    anchors: &HashMap<String, u32>,
) -> (Vec<(ChapterDto, Vec<RawLink>)>, Vec<u32>) {
    let body_len = units::utf16_len(&full.body);
    // offset -> title, first entry wins when two anchors land together.
    let mut cuts: HashMap<u32, String> = HashMap::new();
    for entry in entries {
        let offset = match &entry.fragment {
            None => Some(0),
            Some(fragment) => anchor_offset(anchors, fragment),
        };
        if let Some(offset) = offset {
            cuts.entry(offset.min(body_len))
                .or_insert_with(|| entry.title.clone());
        }
    }

    if cuts.is_empty() {
        // No usable anchors: keep the document whole, titled by its first entry.
        let title = entries.first().map(|e| e.title.clone()).unwrap_or_default();
        let ChapterDto {
            body,
            runs,
            images,
            ..
        } = full;
        let doc_len = units::utf16_len(&body);
        // No split means no cut offsets, but the heading rebase still applies
        // to runs, images, and links alike.
        let (ch, dropped) = strip_duplicate_heading(ChapterDto {
            title,
            body,
            runs,
            images,
            blocks: Vec::new(),
            links: Vec::new(),
        });
        return (
            vec![(
                ChapterDto {
                    title: ch.title,
                    body: ch.body,
                    runs: ch.runs,
                    images: ch.images,
                    blocks: Vec::new(),
                    links: Vec::new(),
                },
                slice_links(links, dropped, doc_len),
            )],
            vec![0],
        );
    }

    let mut offsets: Vec<u32> = cuts.keys().copied().collect();
    offsets.sort_unstable();
    if offsets[0] > 0 {
        offsets.insert(0, 0);
    }

    let full_links: Vec<RawLink> = links.to_vec();
    let mut out: Vec<(ChapterDto, Vec<RawLink>)> = Vec::new();
    let mut starts: Vec<u32> = Vec::new();
    for (i, &start) in offsets.iter().enumerate() {
        let end = if i + 1 < offsets.len() {
            offsets[i + 1]
        } else {
            body_len
        };
        if end <= start {
            continue;
        }
        let slice = utf16_slice(&full.body, start as usize, end as usize);
        if slice.trim().is_empty() {
            continue;
        }
        // The strip runs on the raw slice; its rebase applies to runs, images,
        // and links alike so all offsets index the final emitted body.
        let (stripped, dropped) = strip_duplicate_heading(ChapterDto {
            title: cuts.get(&start).cloned().unwrap_or_default(),
            body: slice.to_string(),
            runs: slice_runs(&full.runs, start, end),
            images: slice_images(&full.images, start, end),
            blocks: Vec::new(),
            links: Vec::new(),
        });
        starts.push(start);
        out.push((
            ChapterDto {
                title: stripped.title,
                body: stripped.body,
                runs: stripped.runs,
                images: stripped.images,
                // Empty by Phase-A policy (see the `ChapterDto` docs): the tree
                // stays reachable via `block_tree()`, and cloning it per slice
                // cost O(chapters × tree) for no consumer.
                blocks: Vec::new(),
                links: Vec::new(),
            },
            // Rebasing and the strip rebase in one clip: links fully inside
            // the dropped heading lose their nothing there.
            slice_links(&full_links, start + dropped, end),
        ));
    }
    if out.is_empty() {
        let title = entries.first().map(|e| e.title.clone()).unwrap_or_default();
        return (
            vec![(
                ChapterDto {
                    title,
                    body: full.body,
                    runs: full.runs,
                    images: full.images,
                    blocks: Vec::new(),
                    links: Vec::new(),
                },
                slice_links(&full_links, 0, body_len),
            )],
            vec![0],
        );
    }
    (out, starts)
}

/// One projected spine document awaiting global link resolution: the split
/// chapters (their `links` fields still empty), the parallel href-carrying
/// link lists (chapter-local UTF-16), the chapter starts in the document's
/// own UTF-16 space, and the full-document anchor map the resolver uses to
/// turn hrefs into chapter targets.
#[derive(Debug, Clone, Default)]
pub struct SplitDoc {
    pub key: String,
    pub chapters: Vec<ChapterDto>,
    pub links: Vec<Vec<RawLink>>,
    pub starts: Vec<u32>,
    pub anchors: HashMap<String, u32>,
}

/// Resolves every [`SplitDoc`]'s raw links into global chapter targets,
/// returning the flat chapter list with [`ChapterDto::links`] filled.
///
/// An href resolves by splitting `path#fragment`: a whole-file link targets
/// the document's first chapter; a fragment targets the chapter containing
/// the anchor (a split anchor is its own chapter; any other registered anchor
/// — e.g. a footnote — targets the chapter it lives in). External http(s)
/// hrefs, hrefs naming no spine document, and fragments with no matching
/// anchor are dropped: they never cross the FFI.
///
/// Paths resolve through the book's normalised key space ([`resolve_href`]:
/// percent-decoded, lowercased, `..`/`.` segments collapsed); fragments reuse
/// the split map's tolerance ([`anchor_offset`]).
pub fn resolve_split_links(docs: Vec<SplitDoc>) -> Vec<ChapterDto> {
    // Base index of each document's first chapter in the flat list.
    let mut bases: Vec<u32> = Vec::with_capacity(docs.len());
    let mut total: u32 = 0;
    for doc in &docs {
        bases.push(total);
        total += doc.chapters.len() as u32;
    }

    let mut resolved: Vec<Vec<LinkDto>> = vec![Vec::new(); total as usize];
    for (di, doc) in docs.iter().enumerate() {
        for (ci, ch_links) in doc.links.iter().enumerate() {
            let mut out_links = Vec::with_capacity(ch_links.len());
            for link in ch_links {
                if let Some(target) = resolve_target(&docs, &bases, di, link) {
                    out_links.push(LinkDto {
                        start: link.start,
                        end: link.end,
                        target,
                    });
                }
            }
            resolved[bases[di] as usize + ci] = out_links;
        }
    }

    let mut out: Vec<ChapterDto> = Vec::with_capacity(total as usize);
    for doc in docs {
        for (ci, mut ch) in doc.chapters.into_iter().enumerate() {
            ch.links = std::mem::take(&mut resolved[out.len()]);
            out.push(ch);
        }
    }
    out
}

/// Maps one link's href to a global chapter index, or `None` to drop it.
fn resolve_target(
    docs: &[SplitDoc],
    bases: &[u32],
    di: usize,
    link: &RawLink,
) -> Option<u32> {
    let (path, fragment) = match link.href.split_once('#') {
        Some((path, fragment)) => (path, Some(fragment)),
        None => (link.href.as_str(), None),
    };
    let trimmed = path.trim();
    let scheme = trimmed.to_lowercase();
    if scheme.starts_with("http://") || scheme.starts_with("https://") {
        return None;
    }
    // Same-document links omit the path entirely.
    let key = if trimmed.is_empty() {
        docs[di].key.clone()
    } else {
        resolve_href(&dir_of(&docs[di].key), trimmed)
    };
    // First spine occurrence wins for duplicate archive keys.
    let ti = docs.iter().position(|d| d.key == key)?;
    let base = bases[ti];
    // The chapter containing the anchor: the last chapter whose start is at
    // or before the anchor offset. Splitting anchors are their own chapter;
    // bare anchors (footnotes) fall inside one.
    let local = match fragment {
        None => 0,
        Some(fragment) => {
            let offset = anchor_offset(&docs[ti].anchors, fragment)?;
            let idx = docs[ti].starts.partition_point(|&start| start <= offset);
            idx.saturating_sub(1) as u32
        }
    };
    Some(base + local)
}

/// Clips `links` to `[start, end)` and shifts them to slice-local offsets,
/// mirroring [`slice_runs`] (a link crossing the cut is clipped, one holding
/// visible body text on both cuts is split where it must not survive whole —
/// the clip drops it only when nothing of the text remains).
fn slice_links(links: &[RawLink], start: u32, end: u32) -> Vec<RawLink> {
    if links.is_empty() {
        return Vec::new();
    }
    links
        .iter()
        .filter_map(|link| {
            let s = link.start.max(start);
            let e = link.end.min(end);
            if e <= s {
                return None;
            }
            Some(RawLink {
                start: s - start,
                end: e - start,
                href: link.href.clone(),
            })
        })
        .collect()
}

/// Looks up `fragment` among `anchors`, tolerating percent-encoding
/// differences between the TOC and the document itself (matching Dart's
/// `_anchorOffset`: a direct hit wins, otherwise the decoded fragment is
/// tried; undecodable fragments resolve to nothing).
fn anchor_offset(anchors: &HashMap<String, u32>, fragment: &str) -> Option<u32> {
    if let Some(offset) = anchors.get(fragment) {
        return Some(*offset);
    }
    let decoded = decode_percent(fragment);
    if decoded == fragment {
        return None;
    }
    anchors.get(&decoded).copied()
}

/// Drops a leading body line that merely repeats the chapter title.
///
/// A port of Dart's `_stripDuplicateHeading`: the whole first line must equal
/// the title after collapsing whitespace and case, and a chapter holding
/// nothing but its title is left alone. Returns the chapter with that line
/// removed and the UTF-16 length of the dropped prefix, so runs, images, and
/// links rebase past it (Dart's `_sliceRuns`/`_sliceImages` from the rest
/// offset).
fn strip_duplicate_heading(ch: ChapterDto) -> (ChapterDto, u32) {
    let title = normalize_heading(&ch.title);
    if title.is_empty() {
        return (ch, 0);
    }
    let Some(nl) = ch.body.find('\n') else {
        return (ch, 0);
    };
    if normalize_heading(&ch.body[..nl]) != title {
        return (ch, 0);
    }
    let after = &ch.body[nl + 1..];
    let rest_byte = nl + 1 + (after.len() - after.trim_start().len());
    if ch.body[rest_byte..].is_empty() {
        return (ch, 0);
    }
    let start = units::byte_to_utf16(&ch.body, rest_byte);
    let body_len = units::utf16_len(&ch.body);
    (
        ChapterDto {
            title: ch.title,
            body: ch.body[rest_byte..].to_string(),
            runs: slice_runs(&ch.runs, start, body_len),
            images: slice_images(&ch.images, start, body_len),
            // Empty by Phase-A policy (see the `ChapterDto` docs).
            blocks: Vec::new(),
            links: Vec::new(),
        },
        start,
    )
}

/// Collapses whitespace runs to one space, trims, and lowercases (matching
/// Dart's `_normalizeHeading`).
fn normalize_heading(s: &str) -> String {
    s.split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase()
}

/// Clips `runs` to `[start, end)` and shifts them to slice-local offsets
/// (matching Dart's `_sliceRuns`).
fn slice_runs(runs: &[StyleRunDto], start: u32, end: u32) -> Vec<StyleRunDto> {
    if runs.is_empty() {
        return Vec::new();
    }
    runs.iter()
        .filter_map(|run| {
            let s = run.start.max(start);
            let e = run.end.min(end);
            if e <= s {
                return None;
            }
            Some(StyleRunDto {
                start: s - start,
                end: e - start,
                bold: run.bold,
                italic: run.italic,
                quote: run.quote,
                css: run.css.clone(),
            })
        })
        .collect()
}

/// Clips `images` to `[start, end)` and shifts them to slice-local offsets
/// (matching Dart's `_sliceImages`).
fn slice_images(images: &[ImageRunDto], start: u32, end: u32) -> Vec<ImageRunDto> {
    if images.is_empty() {
        return Vec::new();
    }
    images
        .iter()
        .filter_map(|image| {
            if image.offset < start || image.offset >= end {
                return None;
            }
            let mut clipped = image.clone();
            clipped.offset -= start;
            Some(clipped)
        })
        .collect()
}
/// True when only horizontal whitespace / placeholders / line breaks surround
/// the placeholder at `offset` (mirrors Dart's `_isStandalone`).
fn is_standalone(body: &str, offset: usize) -> bool {
    let placeholder = '\u{FFFC}'.len_utf8();
    let left = body[..offset]
        .chars()
        .rev()
        .find(|ch| !chars_horizontal_ws(*ch) && *ch != '\u{FFFC}');
    if left.is_some_and(|ch| ch != '\n') {
        return false;
    }
    let right = body[offset + placeholder..]
        .chars()
        .find(|ch| !chars_horizontal_ws(*ch) && *ch != '\u{FFFC}');
    if right.is_some_and(|ch| ch != '\n') {
        return false;
    }
    true
}

fn chars_horizontal_ws(ch: char) -> bool {
    matches!(ch, ' ' | '\t' | '\r')
}

/// Builds the run/image `CssStyleDto` from a node's author-declared properties
/// only. UA defaults are skipped so an unstyled book emits no CSS (D12).
fn css_style_from_declared(style: &ComputedStyle) -> Option<CssStyleDto> {
    let mut out = CssStyleDto::default();
    let mut any = false;
    macro_rules! assign {
        ($slot:expr, $value:expr) => {{
            let value = $value;
            if value.is_some() {
                any = true;
            }
            $slot = value;
        }};
    }
    for property in &style.declared {
        let value = style.get(property);
        match property.as_str() {
            "font-size" => assign!(out.font_size, value.and_then(parse_font_size)),
            "color" => assign!(out.color, value.and_then(parse_color)),
            "text-align" => assign!(out.text_align, value.and_then(parse_text_align)),
            "text-indent" => assign!(out.text_indent, value.and_then(parse_length)),
            "margin-left" => assign!(out.margin_left, value.and_then(parse_length)),
            "margin-right" => assign!(out.margin_right, value.and_then(parse_length)),
            "margin-top" => assign!(out.margin_top, value.and_then(parse_length)),
            "margin-bottom" => assign!(out.margin_bottom, value.and_then(parse_length)),
            "font-weight" => assign!(out.font_weight, value.and_then(parse_font_weight)),
            "font-style" => assign!(out.font_style, value.and_then(parse_font_style)),
            "text-decoration" => {
                assign!(out.text_decoration, value.and_then(parse_text_decoration))
            }
            "font-family" => {
                assign!(
                    out.font_family,
                    value.map(parse_font_family).filter(|s| !s.is_empty())
                )
            }
            "line-height" => assign!(out.line_height, value.and_then(parse_line_height)),
            "letter-spacing" => assign!(out.letter_spacing, value.and_then(parse_length)),
            "word-spacing" => assign!(out.word_spacing, value.and_then(parse_length)),
            "text-transform" => assign!(
                out.text_transform,
                value.map(str::to_string).filter(|s| !s.is_empty())
            ),
            "white-space" => assign!(
                out.white_space,
                value.map(str::to_string).filter(|s| !s.is_empty())
            ),
            "width" => assign!(out.width, value.and_then(parse_css_length)),
            "height" => assign!(out.height, value.and_then(parse_css_length)),
            "max-width" => assign!(out.max_width, value.and_then(parse_css_length)),
            "max-height" => assign!(out.max_height, value.and_then(parse_css_length)),
            _ => {}
        }
    }
    any.then_some(out)
}

/// A bare numeric HTML `width`/`height` attribute value.
fn parse_plain_number(value: &str) -> Option<f64> {
    value.trim().parse::<f64>().ok()
}

/// `em`/`rem`/`pt`/unitless lengths as pixels, matching `_parseLength`.
///
/// Percentages are *not* resolved here (Dart treats them as a bare number for
/// these properties, where CSS would resolve them against the font/container).
fn parse_length(value: &str) -> Option<f64> {
    let trimmed = value.trim();
    let number = strip_units(trimmed)?;
    let lower = trimmed.to_lowercase();
    if lower.ends_with("em") || lower.ends_with("rem") {
        Some(number * 16.0)
    } else if lower.ends_with("pt") {
        Some(number * 1.333)
    } else {
        Some(number)
    }
}

/// `font-size`, with percentage and `em` resolution, matching `_parseFontSize`.
fn parse_font_size(value: &str) -> Option<f64> {
    let trimmed = value.trim();
    let number = strip_units(trimmed)?;
    let lower = trimmed.to_lowercase();
    if lower.ends_with('%') {
        Some(number * 16.0 / 100.0)
    } else if lower.ends_with("em") || lower.ends_with("rem") {
        Some(number * 16.0)
    } else if lower.ends_with("pt") {
        Some(number * 1.333)
    } else {
        Some(number)
    }
}

/// `line-height`, matching `_parseLineHeight` (percent and `em` stay multipliers).
fn parse_line_height(value: &str) -> Option<f64> {
    let trimmed = value.trim();
    let lower = trimmed.to_lowercase();
    if let Some(body) = lower.strip_suffix('%') {
        return body.trim().parse::<f64>().ok().map(|n| n / 100.0);
    }
    if let Some(body) = lower
        .strip_suffix("em")
        .or_else(|| lower.strip_suffix("rem"))
    {
        return body.trim().parse::<f64>().ok();
    }
    if let Some(body) = lower.strip_suffix("px") {
        return body.trim().parse::<f64>().ok().map(|n| n / 16.0);
    }
    if let Some(body) = lower.strip_suffix("pt") {
        return body.trim().parse::<f64>().ok().map(|n| n * 1.333 / 16.0);
    }
    if let Ok(number) = trimmed.parse::<f64>() {
        return Some(number);
    }
    parse_length(trimmed)
}

/// Box-model lengths, keeping `%` (and viewport units) symbolic, matching
/// `_parseCssLength`.
fn parse_css_length(value: &str) -> Option<CssLengthDto> {
    let trimmed = value.trim();
    let lower = trimmed.to_lowercase();
    if lower.is_empty()
        || matches!(
            lower.as_str(),
            "auto" | "none" | "initial" | "inherit" | "unset"
        )
    {
        return None;
    }
    if let Some(body) = lower.strip_suffix('%') {
        return body.trim().parse::<f64>().ok().map(|value| CssLengthDto {
            value,
            is_percent: true,
        });
    }
    if let Some(body) = lower
        .strip_suffix("vw")
        .or_else(|| lower.strip_suffix("vh"))
    {
        return body.trim().parse::<f64>().ok().map(|value| CssLengthDto {
            value,
            is_percent: true,
        });
    }
    let number: f64 = strip_trailing_letters(trimmed).parse().ok()?;
    if lower.ends_with("em") || lower.ends_with("rem") {
        Some(CssLengthDto {
            value: number * 16.0,
            is_percent: false,
        })
    } else if lower.ends_with("pt") {
        Some(CssLengthDto {
            value: number * 1.333,
            is_percent: false,
        })
    } else {
        Some(CssLengthDto {
            value: number,
            is_percent: false,
        })
    }
}

/// Strips every ASCII letter and `%` then parses the number, matching the Dart
/// `replaceAll(RegExp(r'[a-zA-Z%]'), '')`.
fn strip_units(value: &str) -> Option<f64> {
    let numeric: String = value
        .chars()
        .filter(|ch| !ch.is_ascii_alphabetic() && *ch != '%')
        .collect();
    numeric.trim().parse::<f64>().ok()
}

/// Strips trailing ASCII letters, matching `replaceAll(RegExp(r'[a-z]+$'), '')`.
fn strip_trailing_letters(value: &str) -> &str {
    value.trim_end_matches(|ch: char| ch.is_ascii_alphabetic())
}

fn parse_text_align(value: &str) -> Option<String> {
    let v = value.trim().to_lowercase();
    matches!(v.as_str(), "left" | "center" | "right" | "justify").then_some(v)
}

fn parse_font_weight(value: &str) -> Option<f64> {
    match value.trim().to_lowercase().as_str() {
        "bold" => Some(700.0),
        "bolder" => Some(800.0),
        "lighter" => Some(300.0),
        "100" => Some(100.0),
        "200" => Some(200.0),
        "300" => Some(300.0),
        "400" => Some(400.0),
        "500" => Some(500.0),
        "600" => Some(600.0),
        "700" => Some(700.0),
        "800" => Some(800.0),
        "900" => Some(900.0),
        _ => None,
    }
}

fn parse_font_style(value: &str) -> Option<String> {
    let v = value.trim().to_lowercase();
    matches!(v.as_str(), "italic" | "oblique").then(|| "italic".to_string())
}

fn parse_text_decoration(value: &str) -> Option<String> {
    let v = value.trim().to_lowercase();
    if v.contains("underline") {
        Some("underline".to_string())
    } else if v.contains("line-through") {
        Some("lineThrough".to_string())
    } else if v.contains("overline") {
        Some("overline".to_string())
    } else {
        None
    }
}

/// Strips `'`/curly double quotes and trims, matching `propsToCssStyle`.
fn parse_font_family(value: &str) -> String {
    value
        .replace(['\'', '\u{201C}', '\u{201D}'], "")
        .trim()
        .to_string()
}

fn parse_color(value: &str) -> Option<u32> {
    let v = value.trim().to_lowercase();
    let named = match v.as_str() {
        "black" => Some(0xFF00_0000),
        "white" => Some(0xFFFF_FFFF),
        "red" => Some(0xFFFF_0000),
        "green" => Some(0xFF00_8000),
        "blue" => Some(0xFF00_00FF),
        "gray" | "grey" => Some(0xFF80_8080),
        "silver" => Some(0xFFC0_C0C0),
        "orange" => Some(0xFFFF_A500),
        "purple" => Some(0xFF80_0080),
        "navy" => Some(0xFF00_0080),
        "teal" => Some(0xFF00_8080),
        "maroon" => Some(0xFF80_0000),
        "olive" => Some(0xFF80_8000),
        "yellow" => Some(0xFFFF_FF00),
        _ => None,
    };
    if let Some(argb) = named {
        return Some(argb);
    }

    if let Some(hex) = v.strip_prefix('#') {
        if hex.chars().all(|c| c.is_ascii_hexdigit()) {
            return match hex.len() {
                3 => {
                    let r = u32::from_str_radix(&hex[0..1].repeat(2), 16).ok()?;
                    let g = u32::from_str_radix(&hex[1..2].repeat(2), 16).ok()?;
                    let b = u32::from_str_radix(&hex[2..3].repeat(2), 16).ok()?;
                    Some(0xFF00_0000 | (r << 16) | (g << 8) | b)
                }
                6 => {
                    let rgb = u32::from_str_radix(hex, 16).ok()?;
                    Some(0xFF00_0000 | rgb)
                }
                8 => u32::from_str_radix(hex, 16).ok(),
                _ => None,
            };
        }
        return None;
    }

    parse_rgb_function(&v)
}

/// `rgb(r,g,b)` / `rgba(r,g,b,a)` — a deliberately small scanner, matching the
/// Dart regex (decimal channels, optional float alpha).
fn parse_rgb_function(value: &str) -> Option<u32> {
    let open = value.find("rgb")?;
    let start = value[open..].find('(')? + open;
    let end = value[start..].find(')')? + start;
    let inner = &value[start + 1..end];
    let parts: Vec<&str> = inner.split(',').map(str::trim).collect();
    if parts.len() < 3 {
        return None;
    }
    let r: u32 = parts[0].parse().ok()?;
    let g: u32 = parts[1].parse().ok()?;
    let b: u32 = parts[2].parse().ok()?;
    let a: u32 = match parts.get(3) {
        Some(raw) => (raw.parse::<f64>().ok()? * 255.0).round() as u32,
        None => 255,
    };
    Some(((a & 0xFF) << 24) | ((r & 0xFF) << 16) | ((g & 0xFF) << 8) | (b & 0xFF))
}

/// True when the bytes open as XML/SVG, mirroring Dart's `_looksLikeSvg`:
/// within the first 64 bytes, the first byte that is not whitespace or a UTF-8
/// BOM byte is `<`. Byte-wise, like Dart (which compares raw bytes, not chars).
fn looks_like_svg(bytes: &[u8]) -> bool {
    for &b in bytes.iter().take(64) {
        if b == b'<' {
            return true;
        }
        if !matches!(b, b' ' | b'\t' | b'\n' | b'\r' | 0xEF | 0xBB | 0xBF) {
            return false;
        }
    }
    false
}

/// Best-effort SVG dimensions from `viewBox`, then `width`/`height`, mirroring
/// Dart's `_decodeSvgDimensions` (viewBox wins; `0` when unresolved).
fn svg_dimensions(bytes: &[u8]) -> (u32, u32) {
    const LIMIT: usize = 8192;
    let slice = if bytes.len() > LIMIT {
        &bytes[..LIMIT]
    } else {
        bytes
    };
    let text = String::from_utf8_lossy(slice);
    if let Some(view_box) = attr_value(&text, "viewBox") {
        let parts: Vec<&str> = view_box
            .split(|c: char| c.is_whitespace() || c == ',')
            .filter(|p| !p.is_empty())
            .collect();
        if parts.len() == 4 {
            if let (Ok(w), Ok(h)) = (parts[2].parse::<f64>(), parts[3].parse::<f64>()) {
                if w > 0.0 && h > 0.0 {
                    return (w.round() as u32, h.round() as u32);
                }
            }
        }
    }
    // Bare leading number of `width`/`height` (`[\d.]+`, like Dart).
    let w = attr_value(&text, "width").and_then(|v| leading_number(&v));
    let h = attr_value(&text, "height").and_then(|v| leading_number(&v));
    match (w, h) {
        (Some(w), Some(h)) if w > 0.0 && h > 0.0 => (w.round() as u32, h.round() as u32),
        _ => (0, 0),
    }
}

/// The value of the first `name="..."` (or `'...'`) attribute whose name starts
/// on a word boundary, or `None`. `viewBox` keeps its case; `width`/`height`
/// match ASCII case-insensitively, like the Dart regexes.
fn attr_value(text: &str, name: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let mut i = 0;
    while i + name.len() <= bytes.len() {
        // `get` keeps every slice on a char boundary (non-ASCII text steps
        // through one byte at a time but never slices mid-char).
        let boundary = text.get(i..).is_some();
        if boundary && (i == 0 || !is_word_byte(bytes[i - 1])) && name_matches_at(text, i, name) {
            let mut j = i + name.len();
            while j < bytes.len() && matches!(bytes[j], b' ' | b'\t' | b'\n' | b'\r') {
                j += 1;
            }
            if bytes.get(j) != Some(&b'=') {
                i += 1;
                continue;
            }
            j += 1;
            while j < bytes.len() && matches!(bytes[j], b' ' | b'\t' | b'\n' | b'\r') {
                j += 1;
            }
            let quote = *bytes.get(j)?;
            if quote != b'"' && quote != b'\'' {
                i += 1;
                continue;
            }
            let start = j + 1;
            let mut end = start;
            while end < bytes.len() && bytes[end] != quote {
                end += 1;
            }
            if end < bytes.len() {
                return Some(text[start..end].to_string());
            }
            return None;
        }
        i += 1;
    }
    None
}

fn name_matches_at(text: &str, at: usize, name: &str) -> bool {
    let Some(tail) = text.get(at..) else {
        return false;
    };
    if name == "viewBox" {
        // Case-sensitive, like the Dart regex.
        tail.starts_with(name)
    } else {
        tail.get(..name.len())
            .is_some_and(|w| w.eq_ignore_ascii_case(name))
    }
}

fn is_word_byte(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'_'
}

/// The leading `[\d.]+` number of an SVG length (`300px` -> `300`).
fn leading_number(value: &str) -> Option<f64> {
    let numeric: String = value
        .chars()
        .take_while(|c| c.is_ascii_digit() || *c == '.')
        .collect();
    if numeric.is_empty() {
        return None;
    }
    numeric.parse::<f64>().ok()
}

/// Reads the intrinsic (width, height) from an image header, mirroring Dart's
/// `_decodeImageDimensions`. Unknown formats yield `(0, 0)` ("unknown").
pub fn image_dimensions(bytes: &[u8]) -> (u32, u32) {
    // PNG: IHDR width/height are big-endian u32 at bytes 16/20.
    if bytes.len() >= 24 && bytes[..4] == [0x89, b'P', b'N', b'G'] {
        let w = u32::from_be_bytes([bytes[16], bytes[17], bytes[18], bytes[19]]);
        let h = u32::from_be_bytes([bytes[20], bytes[21], bytes[22], bytes[23]]);
        return (w, h);
    }
    // GIF: logical screen size, little-endian u16 at 6/8.
    if bytes.len() >= 10 && bytes[..3] == *b"GIF" {
        let w = u16::from_le_bytes([bytes[6], bytes[7]]) as u32;
        let h = u16::from_le_bytes([bytes[8], bytes[9]]) as u32;
        return (w, h);
    }
    // BMP: int32 LE width at 18, height at 22.
    if bytes.len() >= 26 && bytes[..2] == *b"BM" {
        let w = i32::from_le_bytes([bytes[18], bytes[19], bytes[20], bytes[21]]);
        let h = i32::from_le_bytes([bytes[22], bytes[23], bytes[24], bytes[25]]);
        return (w.unsigned_abs(), h.unsigned_abs());
    }
    // WebP: RIFF container, first chunk's canvas size.
    if bytes.len() >= 30 && &bytes[..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        match &bytes[12..16] {
            b"VP8X" => {
                let w = 1 + (bytes[24] as u32 | (bytes[25] as u32) << 8 | (bytes[26] as u32) << 16);
                let h = 1 + (bytes[27] as u32 | (bytes[28] as u32) << 8 | (bytes[29] as u32) << 16);
                return (w, h);
            }
            b"VP8L" if bytes.len() >= 25 => {
                let b0 = bytes[21] as u32;
                let b1 = bytes[22] as u32;
                let b2 = bytes[23] as u32;
                let b3 = bytes[24] as u32;
                let w = 1 + (((b1 & 0x3F) << 8) | b0);
                let h = 1 + (((b3 & 0x0F) << 10) | (b2 << 2) | ((b1 & 0xC0) >> 6));
                return (w, h);
            }
            b"VP8 " if bytes.len() >= 30 => {
                let w = (bytes[26] as u32 | (bytes[27] as u32) << 8) & 0x3FFF;
                let h = (bytes[28] as u32 | (bytes[29] as u32) << 8) & 0x3FFF;
                return (w, h);
            }
            _ => {}
        }
    }
    // SVG: sniff the XML for `viewBox`, then `width`/`height`, mirroring Dart's
    // `_decodeSvgDimensions` (viewBox wins; anything unresolved stays unknown).
    if looks_like_svg(bytes) {
        let (w, h) = svg_dimensions(bytes);
        if w > 0 && h > 0 {
            return (w, h);
        }
    }
    // JPEG: scan for a SOF0–SOF15 marker (excluding DHT/JPG/DAC).
    if bytes.len() >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8 {
        let mut i = 2usize;
        while i + 9 < bytes.len() {
            if bytes[i] != 0xFF {
                i += 1;
                continue;
            }
            let marker = bytes[i + 1];
            if (0xC0..=0xCF).contains(&marker) && marker != 0xC4 && marker != 0xC8 && marker != 0xCC
            {
                let h = u16::from_be_bytes([bytes[i + 5], bytes[i + 6]]) as u32;
                let w = u16::from_be_bytes([bytes[i + 7], bytes[i + 8]]) as u32;
                return (w, h);
            }
            let len = u16::from_be_bytes([bytes[i + 2], bytes[i + 3]]) as usize;
            i += 2 + len;
        }
    }
    (0, 0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::epub::block::parse_xhtml;
    use crate::epub::cascade::resolve_stylesheets;
    use std::collections::HashMap;

    /// Parses `xml` and attaches the cascade for the inline `css`.
    fn styled(xml: &str, css: &str) -> BlockTree {
        let mut tree = parse_xhtml(xml);
        let inline: Vec<String> = if css.is_empty() {
            Vec::new()
        } else {
            vec![css.to_string()]
        };
        let table = resolve_stylesheets(&HashMap::new(), |_| None, &inline, &tree);
        table.attach(&mut tree);
        tree
    }

    /// Projects with no readable resources (string behaviour only).
    fn project(tree: &BlockTree) -> ChapterDto {
        project_with(tree, String::new(), &HashSet::new(), |src| {
            (src.to_string(), None)
        })
    }

    #[test]
    fn whitespace_collapse_matches_the_dart_renderer() {
        let tree = styled("<body><h1>One</h1><p>The first chapter.</p></body>", "");
        let dto = project(&tree);
        assert_eq!(dto.body, "One\n\nThe first chapter.");
    }

    #[test]
    fn newlines_inside_text_collapse_to_a_space() {
        // EPUB XHTML is commonly hard-wrapped inside a single text node. A
        // source newline is collapsible whitespace, not a token separator: the
        // word following it must survive, whether or not the wrap is preceded
        // by a space.
        let spaced = styled(
            "<body><p>his middle \nlike a bloated sausage. Below the waterbag</p></body>",
            "",
        );
        assert_eq!(
            project(&spaced).body,
            "his middle like a bloated sausage. Below the waterbag"
        );
        let tight = styled("<body><p>his middle\nlike a bloated sausage</p></body>", "");
        assert_eq!(project(&tight).body, "his middle like a bloated sausage");
    }

    #[test]
    fn form_feed_and_vertical_tab_collapse_to_a_space() {
        let tree = styled("<body><p>a\u{0C}b\u{0B}c</p></body>", "");
        assert_eq!(project(&tree).body, "a b c");
    }

    #[test]
    fn emphasis_runs_cover_their_text_and_spaces() {
        let tree = styled("<body><p>a <em>b</em> c</p></body>", "");
        let dto = project(&tree);
        assert_eq!(dto.body, "a b c");
        assert_eq!(dto.runs.len(), 1);
        let run = &dto.runs[0];
        assert!(run.italic);
        assert_eq!(&dto.body[run.start as usize..run.end as usize], "b");
    }

    #[test]
    fn percent_lengths_stay_symbolic() {
        let tree = styled(
            "<body><p class=\"wide\">x</p></body>",
            ".wide { max-width: 100%; width: 50%; }",
        );
        let dto = project(&tree);
        let css = dto
            .runs
            .iter()
            .find_map(|run| run.css.clone())
            .expect("css");
        assert_eq!(
            css.max_width,
            Some(CssLengthDto {
                value: 100.0,
                is_percent: true
            })
        );
        assert_eq!(
            css.width,
            Some(CssLengthDto {
                value: 50.0,
                is_percent: true
            })
        );
    }

    #[test]
    fn font_and_colour_values_mirror_the_dart_parser() {
        let tree = styled(
            "<body><p class=\"n\">x</p></body>",
            ".n { font-size: 1.3em; color: #336699; font-weight: bold; text-align: justify; }",
        );
        let dto = project(&tree);
        let css = dto
            .runs
            .iter()
            .find_map(|run| run.css.clone())
            .expect("css");
        assert_eq!(css.font_size, Some(1.3 * 16.0));
        assert_eq!(css.color, Some(0xFF33_6699));
        assert_eq!(css.font_weight, Some(700.0));
        assert_eq!(css.text_align.as_deref(), Some("justify"));
    }

    #[test]
    fn blockquote_text_is_quoted() {
        let tree = styled("<body><blockquote><p>q</p></blockquote></body>", "");
        let dto = project(&tree);
        let run = dto.runs.iter().find(|run| run.quote).expect("quote run");
        assert_eq!(&dto.body[run.start as usize..run.end as usize], "q");
    }

    #[test]
    fn image_dimensions_read_png_headers() {
        // 8x4 PNG header.
        let mut png = vec![0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A];
        png.extend_from_slice(&13u32.to_be_bytes());
        png.extend_from_slice(b"IHDR");
        png.extend_from_slice(&8u32.to_be_bytes());
        png.extend_from_slice(&4u32.to_be_bytes());
        assert_eq!(image_dimensions(&png), (8, 4));
        assert_eq!(image_dimensions(b"not an image"), (0, 0));
    }

    #[test]
    fn image_dimensions_read_svg_view_box() {
        // Mirrors Dart's `_decodeSvgDimensions`: viewBox wins, then
        // width/height; an SVG without either stays unknown.
        let svg = br#"<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 300 150" width="300" height="150">
  <rect width="300" height="150"/>
</svg>"#;
        assert_eq!(image_dimensions(svg), (300, 150));
        let bare = br#"<svg xmlns="http://www.w3.org/2000/svg"></svg>"#;
        assert_eq!(image_dimensions(bare), (0, 0));
        // Not XML at all: still unknown, never a panic.
        assert_eq!(image_dimensions(b"\xff\xd8\xff junk"), (0, 0));
    }

    #[test]
    fn opf_declared_cover_is_full_width() {
        let tree = styled(
            "<body><p>See <img id=\"fig1\" src=\"Images/front.png\" alt=\"front\"/> here.</p></body>",
            "",
        );
        let covers: HashSet<String> = ["oebps/images/front.png".to_string()].into_iter().collect();
        let dto = project_with(&tree, String::new(), &covers, |src| {
            // Resolved exactly like `project_tree` with an `oebps` chapter dir.
            (resolve_href("oebps", src), Some(vec![0u8; 8]))
        });
        assert_eq!(dto.images.len(), 1);
        assert!(dto.images[0].full_width);
        // Without the OPF declaration the same image is not full-width.
        let plain = project(&tree);
        assert!(!plain.images[0].full_width);
    }

    /// Splits one document into a chapter per anchor, mirroring the Dart
    /// `splitByAnchors` test of the same name.
    fn split(tree: &BlockTree, entries: &[SplitEntry]) -> Vec<ChapterDto> {
        project_split_with(tree, String::new(), entries, &HashSet::new(), |src| {
            (src.to_string(), None)
        })
    }

    fn entry(fragment: Option<&str>, title: &str) -> SplitEntry {
        SplitEntry {
            fragment: fragment.map(str::to_string),
            title: title.to_string(),
        }
    }

    #[test]
    fn anchors_resolve_to_the_following_text() {
        let tree = styled(
            "<body><p>Intro</p><h2 id=\"two\">Two</h2><p id=\"three\">Three</p></body>",
            "",
        );
        let (full, anchors, _) = project_full_with(&tree, String::new(), &HashSet::new(), |src| {
            (src.to_string(), None)
        });
        // The break belongs to the previous section, not the anchored one.
        assert_eq!(
            utf16_slice(
                &full.body,
                anchors["two"] as usize,
                anchors["two"] as usize + 1
            ),
            "T"
        );
        assert!(
            utf16_slice(&full.body, anchors["three"] as usize, full.body.len())
                .starts_with("Three")
        );
    }

    #[test]
    fn legacy_a_name_anchors_resolve() {
        let tree = styled("<body><p>One</p><a name=\"two\">Two</a></body>", "");
        let (full, anchors, _) = project_full_with(&tree, String::new(), &HashSet::new(), |src| {
            (src.to_string(), None)
        });
        assert!(
            utf16_slice(&full.body, anchors["two"] as usize, full.body.len()).starts_with("Two")
        );
    }

    #[test]
    fn first_declaration_wins_for_duplicate_ids() {
        let tree = styled(
            "<body><p id=\"dup\">First</p><p id=\"dup\">Second</p></body>",
            "",
        );
        let (full, anchors, _) = project_full_with(&tree, String::new(), &HashSet::new(), |src| {
            (src.to_string(), None)
        });
        assert!(
            utf16_slice(&full.body, anchors["dup"] as usize, full.body.len()).starts_with("First")
        );
    }

    #[test]
    fn split_produces_one_chapter_per_anchor() {
        let tree = styled(
            "<body><h2 id=\"a\">One</h2><p>alpha</p>\
             <h2 id=\"b\">Two</h2><p>beta</p>\
             <h2 id=\"c\">Three</h2><p>gamma</p></body>",
            "",
        );
        let chapters = split(
            &tree,
            &[
                entry(Some("a"), "One"),
                entry(Some("b"), "Two"),
                entry(Some("c"), "Three"),
            ],
        );
        assert_eq!(
            chapters
                .iter()
                .map(|c| c.title.as_str())
                .collect::<Vec<_>>(),
            vec!["One", "Two", "Three"]
        );
        // Splitting must not lose or duplicate a character, apart from the
        // in-body headings consumed as titles.
        assert_eq!(
            chapters
                .iter()
                .map(|c| c.body.as_str())
                .collect::<Vec<_>>()
                .join(""),
            "alpha\n\nbeta\n\ngamma"
        );
    }

    #[test]
    fn split_rebases_runs_into_their_slice() {
        let tree = styled(
            "<body><h2 id=\"a\">One</h2><p>plain <em>emph</em></p>\
             <h2 id=\"b\">Two</h2><p><strong>bold</strong> tail</p></body>",
            "",
        );
        let chapters = split(&tree, &[entry(Some("a"), "One"), entry(Some("b"), "Two")]);
        assert_eq!(chapters.len(), 2);
        assert_eq!(chapters[0].runs.len(), 1);
        assert!(chapters[0].runs[0].italic);
        assert_eq!(
            utf16_slice(
                &chapters[0].body,
                chapters[0].runs[0].start as usize,
                chapters[0].runs[0].end as usize
            ),
            "emph"
        );
        assert_eq!(chapters[1].runs.len(), 1);
        assert!(chapters[1].runs[0].bold);
        assert_eq!(
            utf16_slice(
                &chapters[1].body,
                chapters[1].runs[0].start as usize,
                chapters[1].runs[0].end as usize
            ),
            "bold"
        );
    }

    #[test]
    fn text_before_the_first_anchor_becomes_an_untitled_chapter() {
        let tree = styled(
            "<body><p>front matter</p><h2 id=\"b\">Two</h2><p>beta</p></body>",
            "",
        );
        let chapters = split(&tree, &[entry(Some("b"), "Two")]);
        assert_eq!(chapters.len(), 2);
        assert!(chapters[0].title.is_empty());
        assert!(chapters[0].body.contains("front matter"));
        assert_eq!(chapters[1].title, "Two");
    }

    #[test]
    fn unresolvable_entries_keep_the_document_whole() {
        let tree = styled("<body><p>only text</p></body>", "");
        let chapters = split(&tree, &[entry(Some("missing"), "Title")]);
        assert_eq!(chapters.len(), 1);
        assert_eq!(chapters[0].title, "Title");
        assert_eq!(chapters[0].body, "only text");
    }

    #[test]
    fn ghost_entries_are_ignored() {
        let tree = styled(
            "<body><h2 id=\"a\">One</h2><p>alpha</p>\
             <h2 id=\"b\">Two</h2><p>beta</p></body>",
            "",
        );
        let chapters = split(
            &tree,
            &[
                entry(Some("a"), "One"),
                entry(Some("ghost"), "Ghost"),
                entry(Some("b"), "Two"),
            ],
        );
        assert_eq!(
            chapters
                .iter()
                .map(|c| c.title.as_str())
                .collect::<Vec<_>>(),
            vec!["One", "Two"]
        );
    }

    #[test]
    fn fragmentless_entry_titles_the_whole_document() {
        let tree = styled("<body><h2 id=\"a\">One</h2><p>alpha</p></body>", "");
        let chapters = split(&tree, &[entry(None, "Whole")]);
        assert_eq!(chapters.len(), 1);
        assert_eq!(chapters[0].title, "Whole");
        assert_eq!(chapters[0].body, "One\n\nalpha");
    }

    #[test]
    fn percent_encoded_fragment_resolves_to_its_anchor() {
        let tree = styled(
            "<body><h2 id=\"sec 2\">Part Three</h2><p>body</p></body>",
            "",
        );
        let chapters = split(&tree, &[entry(Some("sec%202"), "Part Three")]);
        assert_eq!(chapters.len(), 1);
        assert_eq!(chapters[0].title, "Part Three");
        assert_eq!(chapters[0].body, "body");
    }

    #[test]
    fn strip_drops_a_repeated_heading_and_rebases_runs() {
        let full = ChapterDto {
            title: String::new(),
            body: "CHAPTER ONE\n\nSome text here".to_string(),
            runs: vec![
                StyleRunDto {
                    start: 0,
                    end: 11,
                    bold: true,
                    ..Default::default()
                },
                StyleRunDto {
                    start: 13,
                    end: 17,
                    bold: true,
                    ..Default::default()
                },
            ],
            images: Vec::new(),
            blocks: Vec::new(),
            links: Vec::new(),
        };
        let chapters = split_chapters(full, &[entry(None, "Chapter One")], &HashMap::new());
        assert_eq!(chapters.len(), 1);
        assert_eq!(chapters[0].body, "Some text here");
        assert_eq!(chapters[0].runs.len(), 1);
        assert_eq!(chapters[0].runs[0].start, 0);
        assert_eq!(
            utf16_slice(
                &chapters[0].body,
                chapters[0].runs[0].start as usize,
                chapters[0].runs[0].end as usize
            ),
            "Some"
        );
    }

    #[test]
    fn strip_keeps_a_different_heading_and_a_title_only_body() {
        let kept = strip_duplicate_heading(ChapterDto {
            title: "Chapter One".to_string(),
            body: "Foreword\n\nSome text here".to_string(),
            runs: Vec::new(),
            images: Vec::new(),
            blocks: Vec::new(),
            links: Vec::new(),
        })
        .0;
        assert_eq!(kept.body, "Foreword\n\nSome text here");

        let alone = strip_duplicate_heading(ChapterDto {
            title: "Chapter One".to_string(),
            body: "CHAPTER ONE".to_string(),
            runs: Vec::new(),
            images: Vec::new(),
            blocks: Vec::new(),
            links: Vec::new(),
        })
        .0;
        assert_eq!(alone.body, "CHAPTER ONE");
    }

    #[test]
    fn merge_runs_partitions_css_only_nested_ranges() {
        // Regression (reader "laying out pages" freeze): a chapter with class
        // styling but no emphasis markup used to return the raw per-node CSS
        // list — nested, overlapping, sometimes duplicated ranges. It must come
        // out as a sorted, disjoint partition instead.
        let css = |start: usize, end: usize, size: f64| RawRun {
            start,
            end,
            bold: false,
            italic: false,
            quote: false,
            css: Some(CssStyleDto {
                font_size: Some(size),
                ..Default::default()
            }),
        };
        let out = merge_runs(
            Vec::new(),
            vec![css(0, 20, 10.0), css(0, 20, 12.0), css(5, 10, 14.0)],
            20,
        );

        assert!(out.windows(2).all(|w| w[0].end <= w[1].start), "{out:?}");
        assert_eq!(out.len(), 3);
        assert_eq!((out[0].start, out[0].end), (0, 5));
        assert_eq!((out[1].start, out[1].end), (5, 10));
        assert_eq!((out[2].start, out[2].end), (10, 20));
        // Outer runs merge first; a nested rule's declaration wins per window.
        let size = |run: &RawRun| run.css.as_ref().unwrap().font_size;
        assert_eq!(size(&out[0]), Some(12.0));
        assert_eq!(size(&out[1]), Some(14.0));
        assert_eq!(size(&out[2]), Some(12.0));
    }

    // ---- In-book links ---------------------------------------------------

    /// Projects a document under test key `key`, with the injectable reader.
    fn split_ext(tree: &BlockTree, key: &str, entries: &[SplitEntry]) -> SplitDoc {
        project_split_ext_with(
            tree,
            String::new(),
            key,
            entries,
            &HashSet::new(),
            |src| (src.to_string(), None),
        )
    }

    /// UTF-16 offset of `needle` inside `body` (asserting it exists at all).
    fn at(body: &str, needle: &str) -> u32 {
        utf16_slice(&body, 0, usize::MAX);
        let idx = body.find(needle).expect(needle);
        units::byte_to_utf16(body, idx)
    }

    #[test]
    fn same_document_anchor_link_resolves_to_its_chapter() {
        let tree = styled(
            "<body><h2 id=\"a\">One</h2><p>Read the <a href=\"#b\">second chapter</a> now</p>\
             <h2 id=\"b\">Two</h2><p>beta body</p></body>",
            "",
        );
        let chapters = resolve_split_links(vec![split_ext(
            &tree,
            "doc1.xhtml",
            &[entry(Some("a"), "One"), entry(Some("b"), "Two")],
        )]);
        assert_eq!(chapters.len(), 2);
        // The link's visible text "second chapter" lands on chapter 1 start.
        assert_eq!(chapters[0].links.len(), 1);
        let link = &chapters[0].links[0];
        assert_eq!(link.start, at(&chapters[0].body, "second chapter"));
        assert_eq!(link.end, link.start + 14);
        assert_eq!(link.target, 1);
        assert!(chapters[1].links.is_empty());
    }

    #[test]
    fn cross_document_links_resolve_through_the_book() {
        let d1 = styled(
            "<body><p><a href=\"doc2.xhtml\">skip ahead</a> and <a href=\"doc2.xhtml#y\">jump</a></p></body>",
            "",
        );
        let d2 = styled(
            "<body><p id=\"x\">X part</p><h2 id=\"y\">Y head</h2><p>Y body</p></body>",
            "",
        );
        let chapters = resolve_split_links(vec![
            split_ext(&d1, "doc1.xhtml", &[]),
            split_ext(&d2, "doc2.xhtml", &[entry(Some("y"), "Second")]),
        ]);
        // Doc 2 splits at "y": an untitled leading chapter, then the "y" one.
        assert_eq!(chapters.len(), 3);
        assert_eq!(chapters[0].links.len(), 2);
        // Source order: whole-file link first, then the fragment link.
        assert_eq!(chapters[0].links[0].target, 1);
        assert_eq!(chapters[0].links[0].start, at(&chapters[0].body, "skip ahead"));
        assert_eq!(chapters[0].links[1].target, 2);
        assert_eq!(chapters[0].links[1].start, at(&chapters[0].body, "jump"));
    }

    #[test]
    fn external_and_unresolvable_hrefs_are_dropped() {
        let tree = styled(
            "<body><p><a href=\"https://example.com\">out</a><a href=\"xml.css\">style</a>\
             <a href=\"#ghost\">gone</a><p>text</p></p></body>",
            "",
        );
        let chapters = resolve_split_links(vec![split_ext(&tree, "doc1.xhtml", &[])]);
        assert_eq!(chapters.len(), 1);
        assert!(chapters[0].links.is_empty());
    }

    #[test]
    fn mid_chapter_anchor_targets_the_containing_chapter() {
        let tree = styled(
            "<body><h2 id=\"a\">One</h2><p><a href=\"#mid\">deep link</a></p>\
             <h2 id=\"b\">Two</h2><p>beta <em id=\"mid\">anchor</em> tail</p></body>",
            "",
        );
        let chapters = resolve_split_links(vec![split_ext(
            &tree,
            "doc1.xhtml",
            &[entry(Some("a"), "One"), entry(Some("b"), "Two")],
        )]);
        assert_eq!(chapters.len(), 2);
        // "mid" is not a TOC anchor; the link still lands on chapter 1's start.
        assert_eq!(chapters[0].links.len(), 1);
        assert_eq!(chapters[0].links[0].target, 1);
    }

    #[test]
    fn links_rebase_past_a_stripped_duplicate_heading() {
        let tree = styled(
            "<body><h2 id=\"a\">One</h2><p>One</p><p>go <a href=\"#b\">there</a></p>\
             <h2 id=\"b\">Two</h2><p>beta</p></body>",
            "",
        );
        let chapters = resolve_split_links(vec![split_ext(
            &tree,
            "doc1.xhtml",
            &[entry(Some("a"), "One"), entry(Some("b"), "Two")],
        )]);
        assert_eq!(chapters.len(), 2);
        assert_eq!(chapters[0].title, "One");
        // The leading "One" line was stripped: offsets are final-body offsets.
        assert_eq!(chapters[0].links.len(), 1);
        let link = &chapters[0].links[0];
        assert_eq!(link.start, at(&chapters[0].body, "there"));
        assert_eq!(link.end, link.start + 5);
        assert_eq!(link.target, 1);
    }
}
