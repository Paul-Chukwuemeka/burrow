//! The first-party CSS cascade: selector matching, specificity ordering,
//! inheritance, and presentational hints, resolved onto the block tree.
//!
//! There is no drop-in Rust cascade (research §3.4), so the cascade is built
//! here on top of `selectors`' matcher. The `selectors` tree trait is
//! implemented over the flat [`BlockTree`] arena (see [`BlockElement`]); everything else —
//! ordering, inheritance, computed values — is ours.
//!
//! Origins and precedence (lowest to highest) after this module:
//! UA defaults < author rules & presentational hints < inline `style=""` <
//! `!important` author declarations < `!important` inline declarations.
//! Within an origin group, higher specificity wins, then later source order.
//!
//! Inherited properties (font, colour, text-align, …) flow from a parent to its
//! children; non-inherited ones (margins, width, …) reset per element.

use std::collections::{HashMap, HashSet};

use selectors::attr::{AttrSelectorOperation, CaseSensitivity, NamespaceConstraint};
use selectors::bloom::BloomFilter;
use selectors::context::{
    MatchingContext, MatchingForInvalidation, MatchingMode, NeedsSelectorFlags, QuirksMode,
    SelectorCaches,
};
use selectors::matching::{matches_selector, ElementSelectorFlags};
use selectors::parser::Selector;
use selectors::{Element, OpaqueElement};

use crate::epub::block;
use crate::epub::container::{resolve_href, EpubArchive};
use crate::epub::css::{self, Atom, BurrowSelectorImpl, Declaration, PseudoClass, Stylesheet};
use crate::epub::dom;
use crate::epub::model::{BlockNode, BlockTree, EpubError, FontFaceDto};

/// The HTML5 suggested-rendering defaults (design D10/D12).
///
/// Written entirely in longhand so no shorthand expansion is needed. These
/// declarations resolve onto the tree (so a future paginator sees real
/// defaults) but are *not* marked as author-declared, so the phase-1 flat-run
/// projection can keep reproducing today's style-only output.
const UA_STYLESHEET: &str = r#"
html, body, div, p, h1, h2, h3, h4, h5, h6, ul, ol, li, blockquote, pre,
figure, figcaption, section, article, aside, header, footer, nav, main, center,
table, dl, dt, dd { display: block; }
li { display: list-item; }
img { display: inline; }
h1 { font-size: 2em; font-weight: bold; margin-top: 0.67em; margin-bottom: 0.67em; }
h2 { font-size: 1.5em; font-weight: bold; margin-top: 0.83em; margin-bottom: 0.83em; }
h3 { font-size: 1.17em; font-weight: bold; margin-top: 1em; margin-bottom: 1em; }
h4 { font-size: 1em; font-weight: bold; margin-top: 1.33em; margin-bottom: 1.33em; }
h5 { font-size: 0.83em; font-weight: bold; margin-top: 1.67em; margin-bottom: 1.67em; }
h6 { font-size: 0.67em; font-weight: bold; margin-top: 2.33em; margin-bottom: 2.33em; }
p { margin-top: 1em; margin-bottom: 1em; }
blockquote { margin-top: 1em; margin-bottom: 1em; margin-left: 40px; margin-right: 40px; }
pre { font-family: monospace; white-space: pre; margin-top: 1em; margin-bottom: 1em; }
b, strong { font-weight: bold; }
i, em, cite, var { font-style: italic; }
u, ins { text-decoration: underline; }
s, strike, del { text-decoration: line-through; }
center { text-align: center; }
"#;

/// Cascade groups, lowest precedence first.
const GROUP_UA: u8 = 0;
const GROUP_AUTHOR: u8 = 1;
const GROUP_INLINE: u8 = 2;
const GROUP_UA_IMPORTANT: u8 = 3;
const GROUP_AUTHOR_IMPORTANT: u8 = 4;
const GROUP_INLINE_IMPORTANT: u8 = 5;

/// Where a declaration came from (only the two origins we have).
#[derive(Clone, Copy, PartialEq, Eq)]
enum Origin {
    UserAgent,
    Author,
}

/// Properties that inherit from a parent element to its children.
const INHERITED: &[&str] = &[
    "font-family",
    "font-size",
    "font-weight",
    "font-style",
    "color",
    "line-height",
    "letter-spacing",
    "word-spacing",
    "text-align",
    "text-indent",
    "text-transform",
    "white-space",
    "list-style-type",
    "list-style-position",
    "direction",
    "visibility",
];

/// A resolved style for one element.
///
/// Values are kept as CSS text with units intact (`1.3em`, `100%`, `12px`) —
/// the same symbolic contract as `CssStyle`/`CssLength` (design D4). `declared`
/// lists the properties an author rule, presentational hint, or inline style
/// set on *this* element (not inherited, not UA defaults), which the flat-run
/// projection uses to preserve today's output.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ComputedStyle {
    pub display: Option<String>,
    pub font_family: Option<String>,
    pub font_size: Option<String>,
    pub font_weight: Option<String>,
    pub font_style: Option<String>,
    pub color: Option<String>,
    pub line_height: Option<String>,
    pub letter_spacing: Option<String>,
    pub word_spacing: Option<String>,
    pub text_align: Option<String>,
    pub text_indent: Option<String>,
    pub text_decoration: Option<String>,
    pub text_transform: Option<String>,
    pub white_space: Option<String>,
    pub margin_top: Option<String>,
    pub margin_right: Option<String>,
    pub margin_bottom: Option<String>,
    pub margin_left: Option<String>,
    pub padding_top: Option<String>,
    pub padding_right: Option<String>,
    pub padding_bottom: Option<String>,
    pub padding_left: Option<String>,
    pub width: Option<String>,
    pub height: Option<String>,
    pub max_width: Option<String>,
    pub max_height: Option<String>,
    pub vertical_align: Option<String>,
    /// Properties set by an author rule/hint/inline style on this element.
    pub declared: Vec<String>,
}

impl ComputedStyle {
    /// Reads a property by its CSS name.
    pub fn get(&self, property: &str) -> Option<&str> {
        match property {
            "display" => self.display.as_deref(),
            "font-family" => self.font_family.as_deref(),
            "font-size" => self.font_size.as_deref(),
            "font-weight" => self.font_weight.as_deref(),
            "font-style" => self.font_style.as_deref(),
            "color" => self.color.as_deref(),
            "line-height" => self.line_height.as_deref(),
            "letter-spacing" => self.letter_spacing.as_deref(),
            "word-spacing" => self.word_spacing.as_deref(),
            "text-align" => self.text_align.as_deref(),
            "text-indent" => self.text_indent.as_deref(),
            "text-decoration" => self.text_decoration.as_deref(),
            "text-transform" => self.text_transform.as_deref(),
            "white-space" => self.white_space.as_deref(),
            "margin-top" => self.margin_top.as_deref(),
            "margin-right" => self.margin_right.as_deref(),
            "margin-bottom" => self.margin_bottom.as_deref(),
            "margin-left" => self.margin_left.as_deref(),
            "padding-top" => self.padding_top.as_deref(),
            "padding-right" => self.padding_right.as_deref(),
            "padding-bottom" => self.padding_bottom.as_deref(),
            "padding-left" => self.padding_left.as_deref(),
            "width" => self.width.as_deref(),
            "height" => self.height.as_deref(),
            "max-width" => self.max_width.as_deref(),
            "max-height" => self.max_height.as_deref(),
            "vertical-align" => self.vertical_align.as_deref(),
            _ => None,
        }
    }

    /// Writes a property by its CSS name, returning `false` for unsupported
    /// properties.
    fn set_value(&mut self, property: &str, value: &str) -> bool {
        let slot = match property {
            "display" => &mut self.display,
            "font-family" => &mut self.font_family,
            "font-size" => &mut self.font_size,
            "font-weight" => &mut self.font_weight,
            "font-style" => &mut self.font_style,
            "color" => &mut self.color,
            "line-height" => &mut self.line_height,
            "letter-spacing" => &mut self.letter_spacing,
            "word-spacing" => &mut self.word_spacing,
            "text-align" => &mut self.text_align,
            "text-indent" => &mut self.text_indent,
            "text-decoration" => &mut self.text_decoration,
            "text-transform" => &mut self.text_transform,
            "white-space" => &mut self.white_space,
            "margin-top" => &mut self.margin_top,
            "margin-right" => &mut self.margin_right,
            "margin-bottom" => &mut self.margin_bottom,
            "margin-left" => &mut self.margin_left,
            "padding-top" => &mut self.padding_top,
            "padding-right" => &mut self.padding_right,
            "padding-bottom" => &mut self.padding_bottom,
            "padding-left" => &mut self.padding_left,
            "width" => &mut self.width,
            "height" => &mut self.height,
            "max-width" => &mut self.max_width,
            "max-height" => &mut self.max_height,
            "vertical-align" => &mut self.vertical_align,
            _ => return false,
        };
        *slot = Some(value.to_string());
        true
    }

    /// Sets an author-declared property and records it as declared.
    fn set_author(&mut self, property: &str, value: &str) {
        if self.set_value(property, value) && !self.declared.iter().any(|p| p == property) {
            self.declared.push(property.to_string());
        }
    }

    /// Sets a UA-default property (not recorded as declared).
    fn set_default(&mut self, property: &str, value: &str) {
        self.set_value(property, value);
    }

    /// Copies this element's inherited properties from its parent's style.
    fn copy_inherited_from(&mut self, parent: &ComputedStyle) {
        for property in INHERITED {
            if let Some(value) = parent.get(property) {
                self.set_value(property, value);
            }
        }
    }
}

/// A per-chapter table of computed styles, indexed by block-tree node.
pub struct ComputedStyleTable {
    pub styles: Vec<ComputedStyle>,
    pub font_faces: Vec<FontFaceDto>,
    /// Snapshot of each node's `class` attribute, so `nodes_with_class` does not
    /// need to borrow the tree.
    class_attrs: Vec<Option<String>>,
}

impl ComputedStyleTable {
    /// The style computed for node `index`, if in range.
    pub fn style_for(&self, index: usize) -> Option<&ComputedStyle> {
        self.styles.get(index)
    }

    /// The computed styles of every node whose `class` attribute contains
    /// `class` (case-sensitive, per CSS class matching).
    pub fn nodes_with_class<'a>(
        &'a self,
        class: &'a str,
    ) -> impl Iterator<Item = &'a ComputedStyle> + 'a {
        self.class_attrs
            .iter()
            .enumerate()
            .filter(move |(_, attr)| {
                attr.as_deref()
                    .map(|value| value.split_whitespace().any(|token| token == class))
                    .unwrap_or(false)
            })
            .map(move |(index, _)| &self.styles[index])
    }

    /// Writes every computed style into its node's [`BlockNode::style`].
    pub fn attach(&self, tree: &mut BlockTree) {
        for (node, style) in tree.nodes.iter_mut().zip(&self.styles) {
            node.style = style.clone();
        }
    }
}

/// Resolves the computed styles for `tree` from the book's stylesheets.
///
/// `manifest` maps manifest ids to normalised archive keys; every `.css` entry
/// is read through `read_entry`, decoded as UTF-8 with malformed bytes replaced
/// (matching the Dart parser), and parsed. `inline_styles` are the chapter's
/// `<style>` blocks, parsed after the external sheets (document order).
/// External hrefs — including `@font-face` sources and `@import`s — resolve
/// against the CSS file's own directory; `@import`ed sheets are applied
/// before the importing sheet, following the cascade order of the reader.
pub fn resolve_stylesheets<F>(
    manifest: &HashMap<String, String>,
    read_entry: F,
    inline_styles: &[String],
    tree: &BlockTree,
) -> ComputedStyleTable
where
    F: Fn(&str) -> Option<Vec<u8>>,
{
    let mut seen = HashSet::new();
    let mut sheets = Vec::new();

    let mut css_keys: Vec<&str> = manifest
        .values()
        .map(String::as_str)
        .filter(|key| key.ends_with(".css"))
        .collect();
    css_keys.sort_unstable();
    css_keys.dedup();

    for key in css_keys {
        load_external_sheet(key, &read_entry, &mut sheets, 0, &mut seen);
    }

    for inline in inline_styles {
        load_inline_sheet(inline, "", &read_entry, &mut sheets, 0, &mut seen);
    }

    compute(&sheets, tree)
}

/// Resolves the computed styles for `tree` using the chapter's own styling
/// inputs — `<link rel="stylesheet">` and `<style>` — in document order.
///
/// `chapter_key` is the normalised archive key of the chapter document, used
/// as the base directory for resolving relative link and `@import` hrefs. A
/// chapter that declares **no** styling input falls back to every `.css` in
/// the manifest, alphabetically (the pre-link behaviour), so books that never
/// `<link>` a stylesheet stay styled.
pub fn resolve_stylesheets_ordered<F>(
    manifest: &HashMap<String, String>,
    read_entry: F,
    events: &[dom::StyleEvent],
    chapter_key: &str,
    tree: &BlockTree,
) -> ComputedStyleTable
where
    F: Fn(&str) -> Option<Vec<u8>>,
{
    let mut seen = HashSet::new();
    let mut sheets = Vec::new();

    if events.is_empty() {
        // No styling input of the chapter's own: apply the manifest in natural
        // order, as before.
        let mut css_keys: Vec<&str> = manifest
            .values()
            .map(String::as_str)
            .filter(|key| key.ends_with(".css"))
            .collect();
        css_keys.sort_unstable();
        css_keys.dedup();
        for key in css_keys {
            load_external_sheet(key, &read_entry, &mut sheets, 0, &mut seen);
        }
        return compute(&sheets, tree);
    }

    let chapter_base = dir_of(chapter_key);
    for event in events {
        match event {
            dom::StyleEvent::Style(css) => {
                load_inline_sheet(css, chapter_key, &read_entry, &mut sheets, 0, &mut seen);
            }
            dom::StyleEvent::Link(href) => {
                let key = resolve_href(&chapter_base, href);
                load_external_sheet(&key, &read_entry, &mut sheets, 0, &mut seen);
            }
        }
    }

    compute(&sheets, tree)
}

/// Maximum `@import` chain depth (cycles are also broken by `seen`).
const MAX_IMPORT_DEPTH: usize = 4;

fn load_external_sheet<F>(
    key: &str,
    read_entry: &F,
    out: &mut Vec<Stylesheet>,
    depth: usize,
    seen: &mut HashSet<String>,
) where
    F: Fn(&str) -> Option<Vec<u8>>,
{
    if depth > MAX_IMPORT_DEPTH || !seen.insert(key.to_string()) {
        return;
    }
    let Some(bytes) = read_entry(key) else {
        return;
    };
    let css = String::from_utf8_lossy(&bytes);
    load_inline_sheet(&css, key, read_entry, out, depth, seen);
}

fn load_inline_sheet<F>(
    css: &str,
    css_key: &str,
    read_entry: &F,
    out: &mut Vec<Stylesheet>,
    depth: usize,
    seen: &mut HashSet<String>,
) where
    F: Fn(&str) -> Option<Vec<u8>>,
{
    if depth > MAX_IMPORT_DEPTH {
        return;
    }
    let sheet = Stylesheet::parse(css, css_key);
    let base = dir_of(css_key);
    for href in sheet.imports.clone() {
        let import_key = resolve_href(&base, &href);
        load_external_sheet(&import_key, read_entry, out, depth + 1, seen);
    }
    out.push(sheet);
}

fn dir_of(path: &str) -> String {
    match path.rfind('/') {
        Some(index) => path[..index].to_string(),
        None => String::new(),
    }
}

/// Parses `doc_path` into a block tree and attaches its computed styles.
pub fn parse_styled_document(
    archive: &EpubArchive,
    manifest: &HashMap<String, String>,
    doc_path: &str,
) -> Result<BlockTree, EpubError> {
    let (mut tree, events, chapter_key) =
        block::parse_xhtml_document_parts_with_links(archive, doc_path)?;
    let table = resolve_stylesheets_ordered(
        manifest,
        |key| archive.read_by_key(key),
        &events,
        &chapter_key,
        &tree,
    );
    table.attach(&mut tree);
    Ok(tree)
}

/// Extracts `@font-face` declarations from the book's external stylesheets.
pub fn font_faces<F>(manifest: &HashMap<String, String>, read_entry: F) -> Vec<FontFaceDto>
where
    F: Fn(&str) -> Option<Vec<u8>>,
{
    let mut keys: Vec<&str> = manifest
        .values()
        .map(String::as_str)
        .filter(|key| key.ends_with(".css"))
        .collect();
    keys.sort_unstable();
    keys.dedup();

    let mut faces: Vec<FontFaceDto> = Vec::new();
    let mut seen = HashSet::new();
    for key in keys {
        font_faces_from_entry(key, &read_entry, &mut faces, &mut seen, 0);
    }
    faces
}

/// Collects the `@font-face` declarations from `key` and, recursively, from
/// every `@import`ed sheet (resolved against the importing sheet's directory,
/// depth-capped).
pub(crate) fn font_faces_from_entry<F>(
    key: &str,
    read_entry: &F,
    faces: &mut Vec<FontFaceDto>,
    seen: &mut HashSet<String>,
    depth: usize,
) where
    F: Fn(&str) -> Option<Vec<u8>>,
{
    if depth > MAX_IMPORT_DEPTH || !seen.insert(key.to_string()) {
        return;
    }
    let Some(bytes) = read_entry(key) else {
        return;
    };
    let css = String::from_utf8_lossy(&bytes);
    let sheet = Stylesheet::parse(&css, key);
    for face in sheet.font_faces {
        if !faces.contains(&face) {
            faces.push(face);
        }
    }
    let base = dir_of(key);
    for href in sheet.imports {
        let import_key = resolve_href(&base, &href);
        font_faces_from_entry(&import_key, read_entry, faces, seen, depth + 1);
    }
}

/// A matched declaration together with its cascade key.
struct MatchedDecl {
    group: u8,
    specificity: u32,
    order: usize,
    decl_index: usize,
    property: String,
    value: String,
    author: bool,
}

/// Parent index for every node, built from the arena's `children`.
fn parents_of(tree: &BlockTree) -> Vec<Option<usize>> {
    let mut parents = vec![None; tree.nodes.len()];
    for (index, node) in tree.nodes.iter().enumerate() {
        for &child in &node.children {
            parents[child as usize] = Some(index);
        }
    }
    parents
}

fn group_for(origin: Origin, important: bool) -> u8 {
    match (origin, important) {
        (Origin::UserAgent, false) => GROUP_UA,
        (Origin::UserAgent, true) => GROUP_UA_IMPORTANT,
        (Origin::Author, false) => GROUP_AUTHOR,
        (Origin::Author, true) => GROUP_AUTHOR_IMPORTANT,
    }
}

/// Presentational HTML hints: `align`, `width`/`height`, and `<center>`.
fn presentational_hints(node: &BlockNode) -> Vec<(String, String)> {
    let mut out = Vec::new();
    if let Some(align) = node.attrs.align.as_deref() {
        let align = align.trim();
        if !align.is_empty() {
            out.push(("text-align".to_string(), align.to_ascii_lowercase()));
        }
    }
    if node.attrs.tag == "center" {
        out.push(("text-align".to_string(), "center".to_string()));
    }
    if let Some(width) = node.attrs.width.as_deref() {
        out.push(("width".to_string(), html_dimension(width)));
    }
    if let Some(height) = node.attrs.height.as_deref() {
        out.push(("height".to_string(), html_dimension(height)));
    }
    out
}

/// An HTML `width`/`height` attribute value: a bare number means pixels.
fn html_dimension(value: &str) -> String {
    let value = value.trim();
    if value.chars().all(|c| c.is_ascii_digit()) && !value.is_empty() {
        format!("{value}px")
    } else {
        value.to_string()
    }
}

fn compute(sheets: &[Stylesheet], tree: &BlockTree) -> ComputedStyleTable {
    let ua = Stylesheet::parse(UA_STYLESHEET, "");
    let parents = parents_of(tree);

    // Flatten every rule with a global source order. Presentational hints and
    // inline styles are added per node below with a lower/higher group.
    type RuleRef<'a> = (
        &'a Selector<BurrowSelectorImpl>,
        u32,
        usize,
        &'a [Declaration],
        Origin,
    );
    let mut ordered: Vec<RuleRef> = Vec::new();
    let mut order = 1usize;
    for rule in &ua.rules {
        ordered.push((
            &rule.selector,
            rule.specificity,
            order,
            &rule.declarations,
            Origin::UserAgent,
        ));
        order += 1;
    }
    for sheet in sheets {
        for rule in &sheet.rules {
            ordered.push((
                &rule.selector,
                rule.specificity,
                order,
                &rule.declarations,
                Origin::Author,
            ));
            order += 1;
        }
    }

    let mut caches = SelectorCaches::default();
    let mut context = MatchingContext::new(
        MatchingMode::Normal,
        None,
        &mut caches,
        QuirksMode::NoQuirks,
        NeedsSelectorFlags::No,
        MatchingForInvalidation::No,
    );

    let mut matched: Vec<Vec<MatchedDecl>> =
        (0..tree.nodes.len()).map(|_| Vec::new()).collect();
    for (index, node) in tree.nodes.iter().enumerate() {
        let element = BlockElement {
            tree,
            parents: &parents,
            index,
        };
        for (selector, specificity, rule_order, declarations, origin) in &ordered {
            if matches_selector(selector, 0, None, &element, &mut context) {
                let author = !matches!(origin, Origin::UserAgent);
                for (decl_index, declaration) in declarations.iter().enumerate() {
                    matched[index].push(MatchedDecl {
                        group: group_for(*origin, declaration.important),
                        specificity: *specificity,
                        order: *rule_order,
                        decl_index,
                        property: declaration.property.clone(),
                        value: declaration.value.clone(),
                        author,
                    });
                }
            }
        }
        for (property, value) in presentational_hints(node) {
            matched[index].push(MatchedDecl {
                group: GROUP_AUTHOR,
                specificity: 0,
                order: 0,
                decl_index: 0,
                property,
                value,
                author: true,
            });
        }
        if let Some(style) = node.attrs.style.as_deref() {
            for (decl_index, declaration) in
                css::parse_inline_declarations(style).into_iter().enumerate()
            {
                let group = if declaration.important {
                    GROUP_INLINE_IMPORTANT
                } else {
                    GROUP_INLINE
                };
                matched[index].push(MatchedDecl {
                    group,
                    specificity: 0,
                    order: 0,
                    decl_index,
                    property: declaration.property,
                    value: declaration.value,
                    author: true,
                });
            }
        }
    }

    // Pre-order traversal so a parent's computed style exists before its
    // children inherit from it.
    let mut styles: Vec<ComputedStyle> = vec![ComputedStyle::default(); tree.nodes.len()];
    let mut stack = vec![0usize];
    while let Some(index) = stack.pop() {
        let mut style = ComputedStyle::default();
        if let Some(parent) = parents[index] {
            style.copy_inherited_from(&styles[parent]);
        }
        let mut declarations = std::mem::take(&mut matched[index]);
        declarations.sort_by_key(|d| (d.group, d.specificity, d.order, d.decl_index));
        for declaration in declarations {
            if declaration.author {
                style.set_author(&declaration.property, &declaration.value);
            } else {
                style.set_default(&declaration.property, &declaration.value);
            }
        }
        styles[index] = style;
        for &child in tree.nodes[index].children.iter().rev() {
            stack.push(child as usize);
        }
    }

    let mut font_faces: Vec<FontFaceDto> = Vec::new();
    for sheet in sheets {
        for face in &sheet.font_faces {
            if !font_faces.contains(face) {
                font_faces.push(face.clone());
            }
        }
    }

    ComputedStyleTable {
        styles,
        font_faces,
        class_attrs: tree.nodes.iter().map(|n| n.attrs.class.clone()).collect(),
    }
}

/// An element view over one [`BlockTree`] node, for `selectors` matching.
#[derive(Clone, Debug)]
struct BlockElement<'a> {
    tree: &'a BlockTree,
    parents: &'a [Option<usize>],
    index: usize,
}

impl<'a> BlockElement<'a> {
    fn node(&self) -> &'a BlockNode {
        &self.tree.nodes[self.index]
    }

    fn child_at(&self, index: u32) -> BlockElement<'a> {
        BlockElement {
            tree: self.tree,
            parents: self.parents,
            index: index as usize,
        }
    }

    fn attr_value(&self, name: &str) -> Option<&'a str> {
        let attrs = &self.node().attrs;
        match name {
            "id" => attrs.id.as_deref(),
            "class" => attrs.class.as_deref(),
            "src" => attrs.src.as_deref(),
            "href" => attrs.href.as_deref(),
            "alt" => attrs.alt.as_deref(),
            "width" => attrs.width.as_deref(),
            "height" => attrs.height.as_deref(),
            "style" => attrs.style.as_deref(),
            "align" => attrs.align.as_deref(),
            _ => None,
        }
    }
}

impl<'a> Element for BlockElement<'a> {
    type Impl = BurrowSelectorImpl;

    fn opaque(&self) -> OpaqueElement {
        // Identity is the arena index; never dereferenced, only compared. `+ 1`
        // avoids the null pointer (`NonNull` rejects it).
        OpaqueElement::from_non_null_ptr(
            std::ptr::NonNull::new((self.index + 1) as *mut ()).expect("non-null"),
        )
    }

    fn parent_element(&self) -> Option<Self> {
        self.parents[self.index].map(|parent| BlockElement {
            tree: self.tree,
            parents: self.parents,
            index: parent,
        })
    }

    fn parent_node_is_shadow_root(&self) -> bool {
        false
    }

    fn containing_shadow_host(&self) -> Option<Self> {
        None
    }

    fn is_pseudo_element(&self) -> bool {
        false
    }

    fn prev_sibling_element(&self) -> Option<Self> {
        let parent = self.parents[self.index]?;
        let siblings = &self.tree.nodes[parent].children;
        let position = siblings.iter().position(|&c| c as usize == self.index)?;
        (position > 0).then(|| self.child_at(siblings[position - 1]))
    }

    fn next_sibling_element(&self) -> Option<Self> {
        let parent = self.parents[self.index]?;
        let siblings = &self.tree.nodes[parent].children;
        let position = siblings.iter().position(|&c| c as usize == self.index)?;
        siblings.get(position + 1).map(|&c| self.child_at(c))
    }

    fn first_element_child(&self) -> Option<Self> {
        self.node().children.first().map(|&c| self.child_at(c))
    }

    fn is_html_element_in_html_document(&self) -> bool {
        true
    }

    fn has_local_name(&self, local_name: &Atom) -> bool {
        let name = local_name.as_str();
        // The synthetic root carries the `<body>` tag, but CSS authors also
        // target `html` for inherited typography. Treat the root as both.
        if name.eq_ignore_ascii_case("html") {
            return self.index == 0;
        }
        self.node().attrs.tag.eq_ignore_ascii_case(name)
    }

    fn has_namespace(&self, namespace: &Atom) -> bool {
        namespace.as_str().is_empty()
    }

    fn is_same_type(&self, other: &Self) -> bool {
        self.node().attrs.tag.eq_ignore_ascii_case(&other.node().attrs.tag)
    }

    fn attr_matches(
        &self,
        namespace: &NamespaceConstraint<&Atom>,
        local_name: &Atom,
        operation: &AttrSelectorOperation<&Atom>,
    ) -> bool {
        match namespace {
            NamespaceConstraint::Any => {}
            NamespaceConstraint::Specific(url) => {
                if !url.as_str().is_empty() {
                    return false;
                }
            }
        }
        let Some(value) = self.attr_value(local_name.as_str()) else {
            return false;
        };
        operation.eval_str(value)
    }

    fn match_non_ts_pseudo_class(
        &self,
        pseudo_class: &PseudoClass,
        _context: &mut MatchingContext<BurrowSelectorImpl>,
    ) -> bool {
        match pseudo_class {
            PseudoClass::Link | PseudoClass::Visited => self.is_link(),
            // No interactive state exists at parse time.
            PseudoClass::Hover
            | PseudoClass::Active
            | PseudoClass::Focus
            | PseudoClass::Target
            | PseudoClass::Enabled
            | PseudoClass::Disabled
            | PseudoClass::Checked
            | PseudoClass::Lang(_) => false,
        }
    }

    fn match_pseudo_element(
        &self,
        _pseudo_element: &css::NeverPseudoElement,
        _context: &mut MatchingContext<BurrowSelectorImpl>,
    ) -> bool {
        false
    }

    fn apply_selector_flags(&self, _flags: ElementSelectorFlags) {}

    fn is_link(&self) -> bool {
        self.node().attrs.tag == "a" && self.node().attrs.href.is_some()
    }

    fn is_html_slot_element(&self) -> bool {
        false
    }

    fn has_id(&self, id: &Atom, case_sensitivity: CaseSensitivity) -> bool {
        self.node()
            .attrs
            .id
            .as_deref()
            .map(|value| case_sensitivity.eq(value.as_bytes(), id.as_str().as_bytes()))
            .unwrap_or(false)
    }

    fn has_class(&self, name: &Atom, case_sensitivity: CaseSensitivity) -> bool {
        self.node()
            .attrs
            .class
            .as_deref()
            .map(|value| {
                value
                    .split_whitespace()
                    .any(|token| case_sensitivity.eq(token.as_bytes(), name.as_str().as_bytes()))
            })
            .unwrap_or(false)
    }

    fn has_custom_state(&self, _name: &Atom) -> bool {
        false
    }

    fn imported_part(&self, _name: &Atom) -> Option<Atom> {
        None
    }

    fn is_part(&self, _name: &Atom) -> bool {
        false
    }

    fn is_empty(&self) -> bool {
        self.node().children.is_empty() && self.tree.node_text(self.index).trim().is_empty()
    }

    fn is_root(&self) -> bool {
        self.index == 0
    }

    fn add_element_unique_hashes(&self, _filter: &mut BloomFilter) -> bool {
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::epub::block::parse_xhtml;

    fn styles_of(xml: &str, css: &str) -> (BlockTree, ComputedStyleTable) {
        let tree = parse_xhtml(xml);
        let sheet = Stylesheet::parse(css, "");
        let table = compute(&[sheet], &tree);
        (tree, table)
    }

    fn node_index(tree: &BlockTree, predicate: impl Fn(&BlockNode) -> bool) -> usize {
        tree.nodes.iter().position(predicate).expect("node")
    }

    #[test]
    fn class_rule_applies_to_every_matching_element() {
        let (tree, table) = styles_of(
            "<body><p class=\"note\">a</p><p class=\"note\">b</p></body>",
            ".note { color: red; }",
        );
        assert_eq!(table.nodes_with_class("note").count(), 2);
        let index = node_index(&tree, |n| n.attrs.class.as_deref() == Some("note"));
        assert_eq!(table.style_for(index).unwrap().color.as_deref(), Some("red"));
    }

    #[test]
    fn element_rule_beats_tag_and_inherits_font_family() {
        let (tree, table) = styles_of(
            "<body><h1 class=\"title\">T</h1><p>P</p></body>",
            "body { font-family: serif; } p { font-size: 12px; } .title { font-size: 24px; }",
        );
        let h1 = node_index(&tree, |n| n.attrs.tag == "h1");
        let p = node_index(&tree, |n| n.attrs.tag == "p");
        // `.title` (class specificity) beats the tag-level UA/default size.
        assert_eq!(table.style_for(h1).unwrap().font_size.as_deref(), Some("24px"));
        assert_eq!(table.style_for(p).unwrap().font_size.as_deref(), Some("12px"));
        // font-family is inherited from `body` to both descendants.
        assert_eq!(
            table.style_for(h1).unwrap().font_family.as_deref(),
            Some("serif")
        );
        assert_eq!(
            table.style_for(p).unwrap().font_family.as_deref(),
            Some("serif")
        );
    }

    #[test]
    fn presentational_align_is_author_level_and_beaten_by_a_rule() {
        let (tree, table) = styles_of(
            "<body><p align=\"center\" class=\"x\">a</p></body>",
            ".x { text-align: left; }",
        );
        let p = node_index(&tree, |n| n.attrs.tag == "p");
        assert_eq!(
            table.style_for(p).unwrap().text_align.as_deref(),
            Some("left")
        );
    }

    #[test]
    fn inline_style_beats_an_author_class_rule() {
        let (tree, table) = styles_of(
            "<body><p class=\"x\" style=\"color: green;\">a</p></body>",
            ".x { color: red; }",
        );
        let p = node_index(&tree, |n| n.attrs.tag == "p");
        assert_eq!(
            table.style_for(p).unwrap().color.as_deref(),
            Some("green")
        );
    }

    #[test]
    fn important_author_beats_inline_normal() {
        let (tree, table) = styles_of(
            "<body><p class=\"x\" style=\"color: green;\">a</p></body>",
            ".x { color: red !important; }",
        );
        let p = node_index(&tree, |n| n.attrs.tag == "p");
        assert_eq!(table.style_for(p).unwrap().color.as_deref(), Some("red"));
    }

    #[test]
    fn structural_pseudo_class_selects_only_the_first_child() {
        let (tree, table) = styles_of(
            "<body><p>first</p><p>second</p></body>",
            "p:first-child { color: red; }",
        );
        let paragraphs: Vec<usize> = tree
            .nodes
            .iter()
            .enumerate()
            .filter(|(_, n)| n.attrs.tag == "p")
            .map(|(i, _)| i)
            .collect();
        assert_eq!(paragraphs.len(), 2);
        assert_eq!(
            table.style_for(paragraphs[0]).unwrap().color.as_deref(),
            Some("red")
        );
        assert!(table.style_for(paragraphs[1]).unwrap().color.is_none());
    }

    #[test]
    fn descendant_combinator_matches_only_nested_elements() {
        let (tree, table) = styles_of(
            "<body><div class=\"box\"><p>in</p></div><p>out</p></body>",
            ".box p { color: blue; }",
        );
        let paragraphs: Vec<usize> = tree
            .nodes
            .iter()
            .enumerate()
            .filter(|(_, n)| n.attrs.tag == "p")
            .map(|(i, _)| i)
            .collect();
        assert_eq!(paragraphs.len(), 2);
        assert_eq!(
            table.style_for(paragraphs[0]).unwrap().color.as_deref(),
            Some("blue")
        );
        assert!(table.style_for(paragraphs[1]).unwrap().color.is_none());
    }
}
