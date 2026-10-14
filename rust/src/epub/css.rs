//! CSS parsing: rule sets, declarations, and `@font-face` extraction.
//!
//! `cssparser` tokenises the stylesheet; `selectors` compiles each comma-part
//! of a rule's prelude into a matcher over the block tree (see
//! [`super::cascade`], which implements the `selectors` tree trait). This
//! module owns only *parsing*: it produces a [`Stylesheet`] of
//! selector + declarations pairs and the book's `@font-face` list.
//!
//! Scope is the pinned CSS subset (design D10): block/inline typography,
//! margins/padding, colour, width/height. Unsupported selectors are dropped
//! per comma-part rather than failing the stylesheet, matching the Dart
//! parser's tolerance for commercial EPUBs full of `::-webkit-*` and
//! `::first-letter` rules. Shorthand expansion, `@media`, and `@import` are
//! out of scope for phase 1.

use std::fmt;

use cssparser::{
    serialize_identifier, AtRuleParser, CowRcStr, DeclarationParser, ParseError,
    Parser as CssParser, ParserState, QualifiedRuleParser, RuleBodyItemParser, RuleBodyParser,
    StyleSheetParser, ToCss,
};
use precomputed_hash::PrecomputedHash;
use selectors::parser::{
    NonTSPseudoClass as NonTSPseudoClassTrait, ParseRelative, Parser as SelectorParser,
    PseudoElement as PseudoElementTrait, Selector, SelectorImpl, SelectorList,
    SelectorParseErrorKind,
};

use crate::epub::container::resolve_href;
use crate::epub::model::FontFaceDto;

/// A resolved selector value: element local name, id, class, attribute value,
/// or namespace. One newtype covers every `SelectorImpl` associated type (as
/// Servo's own test impl does) because all of them share the same bounds.
#[derive(Clone, Debug, Default, Eq, Hash, PartialEq)]
pub struct Atom(String);

impl Atom {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl<'a> From<&'a str> for Atom {
    fn from(value: &'a str) -> Self {
        Atom(value.to_string())
    }
}

impl AsRef<str> for Atom {
    fn as_ref(&self) -> &str {
        &self.0
    }
}

impl ToCss for Atom {
    fn to_css<W>(&self, dest: &mut W) -> fmt::Result
    where
        W: fmt::Write,
    {
        serialize_identifier(&self.0, dest)
    }
}

impl PrecomputedHash for Atom {
    fn precomputed_hash(&self) -> u32 {
        // FNV-1a: content-based, so equal atoms hash equally. The bloom filter
        // is never used (we match directly), but a content hash is the honest
        // implementation.
        let mut hash: u32 = 0x811c_9dc5;
        for byte in self.0.as_bytes() {
            hash ^= u32::from(*byte);
            hash = hash.wrapping_mul(0x0100_0193);
        }
        hash
    }
}

/// The non-tree-structural pseudo-classes we can answer statically.
///
/// Tree-structural pseudos (`:root`, `:empty`, `:first-child`, `:nth-*`, …)
/// are handled by the `selectors` matcher, not here.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PseudoClass {
    Link,
    Visited,
    Hover,
    Active,
    Focus,
    Target,
    Enabled,
    Disabled,
    Checked,
    Lang(String),
}

impl NonTSPseudoClassTrait for PseudoClass {
    fn is_active_or_hover(&self) -> bool {
        matches!(self, PseudoClass::Active | PseudoClass::Hover)
    }

    fn is_user_action_state(&self) -> bool {
        self.is_active_or_hover()
    }
}

impl ToCss for PseudoClass {
    fn to_css<W>(&self, dest: &mut W) -> fmt::Result
    where
        W: fmt::Write,
    {
        match self {
            PseudoClass::Link => dest.write_str(":link"),
            PseudoClass::Visited => dest.write_str(":visited"),
            PseudoClass::Hover => dest.write_str(":hover"),
            PseudoClass::Active => dest.write_str(":active"),
            PseudoClass::Focus => dest.write_str(":focus"),
            PseudoClass::Target => dest.write_str(":target"),
            PseudoClass::Enabled => dest.write_str(":enabled"),
            PseudoClass::Disabled => dest.write_str(":disabled"),
            PseudoClass::Checked => dest.write_str(":checked"),
            PseudoClass::Lang(lang) => {
                dest.write_str(":lang(")?;
                serialize_identifier(lang, dest)?;
                dest.write_char(')')
            }
        }
    }
}

/// No pseudo-elements are supported: `::first-letter`/`::before`/`::-webkit-*`
/// rules parse-fail, so they are dropped per comma-part instead of polluting the
/// cascade (design D10).
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum NeverPseudoElement {}

impl PseudoElementTrait for NeverPseudoElement {}

impl ToCss for NeverPseudoElement {
    fn to_css<W>(&self, _dest: &mut W) -> fmt::Result
    where
        W: fmt::Write,
    {
        match *self {}
    }
}

/// The `selectors` implementation this crate matches against.
#[derive(Clone, Debug)]
pub struct BurrowSelectorImpl;

impl SelectorImpl for BurrowSelectorImpl {
    type ExtraMatchingData<'a> = ();
    type AttrValue = Atom;
    type Identifier = Atom;
    type LocalName = Atom;
    type NamespaceUrl = Atom;
    type NamespacePrefix = Atom;
    type BorrowedNamespaceUrl = Atom;
    type BorrowedLocalName = Atom;
    type NonTSPseudoClass = PseudoClass;
    type PseudoElement = NeverPseudoElement;
}

/// The selector-list prelude parser.
struct BurrowSelectorParser;

impl<'i> SelectorParser<'i> for BurrowSelectorParser {
    type Impl = BurrowSelectorImpl;
    type Error = SelectorParseErrorKind;

    fn parse_is_and_where(&self) -> bool {
        true
    }

    fn parse_non_ts_pseudo_class(
        &self,
        name: CowRcStr<'i>,
    ) -> Result<PseudoClass, ParseError<SelectorParseErrorKind>> {
        match name.to_ascii_lowercase().as_str() {
            "link" | "any-link" | "local-link" => Ok(PseudoClass::Link),
            "visited" => Ok(PseudoClass::Visited),
            "hover" => Ok(PseudoClass::Hover),
            "active" => Ok(PseudoClass::Active),
            "focus" | "focus-visible" | "focus-within" => Ok(PseudoClass::Focus),
            "target" => Ok(PseudoClass::Target),
            "enabled" => Ok(PseudoClass::Enabled),
            "disabled" => Ok(PseudoClass::Disabled),
            "checked" => Ok(PseudoClass::Checked),
            _ => Err(ParseError::custom(
                SelectorParseErrorKind::UnsupportedPseudoClassOrElement,
            )),
        }
    }

    fn parse_non_ts_functional_pseudo_class(
        &self,
        name: CowRcStr<'i>,
        parser: &mut CssParser<'i>,
        _after_part: bool,
    ) -> Result<PseudoClass, ParseError<SelectorParseErrorKind>> {
        if name.eq_ignore_ascii_case("lang") {
            let lang = parser.expect_ident_or_string()?.as_ref().to_string();
            return Ok(PseudoClass::Lang(lang));
        }
        Err(ParseError::custom(
            SelectorParseErrorKind::UnsupportedPseudoClassOrElement,
        ))
    }

    fn parse_pseudo_element(
        &self,
        _name: CowRcStr<'i>,
    ) -> Result<NeverPseudoElement, ParseError<SelectorParseErrorKind>> {
        Err(ParseError::custom(
            SelectorParseErrorKind::UnsupportedPseudoClassOrElement,
        ))
    }

    fn parse_functional_pseudo_element(
        &self,
        _name: CowRcStr<'i>,
        _arguments: &mut CssParser<'i>,
    ) -> Result<NeverPseudoElement, ParseError<SelectorParseErrorKind>> {
        Err(ParseError::custom(
            SelectorParseErrorKind::UnsupportedPseudoClassOrElement,
        ))
    }
}

/// One `property: value` pair, with units intact (`1.3em`, `100%`, `12px`).
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Declaration {
    pub property: String,
    pub value: String,
    pub important: bool,
}

/// One selector paired with the declarations of its rule.
///
/// A comma-separated rule produces one of these per selector, so a single
/// unsupported selector in a group drops only that selector.
#[derive(Clone, Debug)]
pub struct StyleRule {
    pub selector: Selector<BurrowSelectorImpl>,
    /// Packed specificity from `selectors` (id << 20 | class << 10 | element).
    pub specificity: u32,
    pub declarations: Vec<Declaration>,
}

/// A parsed stylesheet's rules and `@font-face` list.
#[derive(Clone, Debug, Default)]
pub struct Stylesheet {
    pub rules: Vec<StyleRule>,
    pub font_faces: Vec<FontFaceDto>,
}

impl Stylesheet {
    /// Parses `css`, resolving any `@font-face` `url()` against the directory of
    /// the file at `css_key` (already a normalised archive key).
    pub fn parse(css: &str, css_key: &str) -> Stylesheet {
        let base_dir = dir_of(css_key);
        let mut input = CssParser::new(css);
        let mut parser = StylesheetParserImpl { base_dir };
        let mut sheet = Stylesheet::default();
        {
            let rules = StyleSheetParser::new(&mut input, &mut parser);
            for item in rules {
                match item {
                    Ok(RuleOutput::Style {
                        selectors,
                        declarations,
                    }) => {
                        for (selector, specificity) in selectors {
                            sheet.rules.push(StyleRule {
                                selector,
                                specificity,
                                declarations: declarations.clone(),
                            });
                        }
                    }
                    Ok(RuleOutput::FontFace(face)) => sheet.font_faces.push(face),
                    Ok(RuleOutput::None) | Err(_) => {}
                }
            }
        }
        sheet
    }
}

/// Extracts `@font-face` declarations from `css`, resolving their `src`
/// against the directory of `css_key`.
pub fn extract_font_faces(css: &str, css_key: &str) -> Vec<FontFaceDto> {
    Stylesheet::parse(css, css_key).font_faces
}

/// Parses a bare declaration list (an element's `style=""` attribute).
pub fn parse_inline_declarations(style: &str) -> Vec<Declaration> {
    let mut input = CssParser::new(style);
    let mut parser = StyleDeclarationParser;
    parse_declarations(&mut input, &mut parser)
}

/// The finished output of one top-level rule.
enum RuleOutput {
    None,
    Style {
        selectors: Vec<(Selector<BurrowSelectorImpl>, u32)>,
        declarations: Vec<Declaration>,
    },
    FontFace(FontFaceDto),
}

/// The prelude kind of a top-level at-rule.
enum AtKind {
    FontFace,
    Ignored,
}

struct StylesheetParserImpl {
    base_dir: String,
}

impl<'i> AtRuleParser<'i> for StylesheetParserImpl {
    type Prelude = AtKind;
    type AtRule = RuleOutput;
    type Error = ();

    fn parse_prelude(
        &mut self,
        name: CowRcStr<'i>,
        _input: &mut CssParser<'i>,
    ) -> Result<AtKind, ParseError<()>> {
        if name.eq_ignore_ascii_case("font-face") {
            Ok(AtKind::FontFace)
        } else {
            // `@media`, `@import`, `@page`, `@charset`, … are out of the pinned
            // subset; their blocks are skipped without failing the stylesheet.
            Ok(AtKind::Ignored)
        }
    }

    fn rule_without_block(
        &mut self,
        _prelude: AtKind,
        _start: &ParserState,
    ) -> Result<RuleOutput, ()> {
        Ok(RuleOutput::None)
    }

    fn parse_block(
        &mut self,
        prelude: AtKind,
        _start: &ParserState,
        input: &mut CssParser<'i>,
    ) -> Result<RuleOutput, ParseError<()>> {
        match prelude {
            AtKind::FontFace => {
                let mut parser = FontFaceParser::default();
                let _: Vec<()> = parse_declarations(input, &mut parser);
                Ok(parser.finish(&self.base_dir))
            }
            // The block is skipped wholesale; cssparser consumes it on the next
            // `StyleSheetParser::next` call.
            AtKind::Ignored => Ok(RuleOutput::None),
        }
    }
}

impl<'i> QualifiedRuleParser<'i> for StylesheetParserImpl {
    type Prelude = String;
    type QualifiedRule = RuleOutput;
    type Error = ();

    fn parse_prelude(&mut self, input: &mut CssParser<'i>) -> Result<String, ParseError<()>> {
        let start = input.position();
        while input.next().is_ok() {}
        let text = input.slice_from(start).trim();
        if text.is_empty() {
            return Err(ParseError::unexpected_token());
        }
        Ok(text.to_string())
    }

    fn parse_block(
        &mut self,
        prelude: String,
        _start: &ParserState,
        input: &mut CssParser<'i>,
    ) -> Result<RuleOutput, ParseError<()>> {
        let declarations = parse_declarations(input, &mut StyleDeclarationParser);
        if declarations.is_empty() {
            return Ok(RuleOutput::None);
        }
        let selectors = parse_selectors(&prelude);
        if selectors.is_empty() {
            return Ok(RuleOutput::None);
        }
        Ok(RuleOutput::Style {
            selectors,
            declarations,
        })
    }
}

/// Parses one property declaration's value.
struct StyleDeclarationParser;

impl<'i> DeclarationParser<'i> for StyleDeclarationParser {
    type Declaration = Declaration;
    type Error = ();

    fn parse_value(
        &mut self,
        name: CowRcStr<'i>,
        input: &mut CssParser<'i>,
        _declaration_start: &ParserState,
    ) -> Result<Declaration, ParseError<()>> {
        let raw = read_raw_value(input)?;
        let (value, important) = split_important(raw);
        if value.is_empty() {
            return Err(ParseError::unexpected_token());
        }
        Ok(Declaration {
            property: name.to_ascii_lowercase(),
            value: value.to_string(),
            important,
        })
    }
}

impl<'i> AtRuleParser<'i> for StyleDeclarationParser {
    type Prelude = ();
    type AtRule = Declaration;
    type Error = ();
}

impl<'i> QualifiedRuleParser<'i> for StyleDeclarationParser {
    type Prelude = ();
    type QualifiedRule = Declaration;
    type Error = ();
}

impl<'i> RuleBodyItemParser<'i, Declaration, ()> for StyleDeclarationParser {
    fn parse_declarations(&self) -> bool {
        true
    }

    fn parse_qualified(&self) -> bool {
        false
    }
}

#[derive(Default)]
struct FontFaceParser {
    family: Option<String>,
    src: Option<String>,
}

impl FontFaceParser {
    fn finish(self, base_dir: &str) -> RuleOutput {
        let (Some(family), Some(src)) = (self.family, self.src) else {
            return RuleOutput::None;
        };
        let Some(src) = resolve_font_src(base_dir, &src) else {
            return RuleOutput::None;
        };
        if family.is_empty() {
            return RuleOutput::None;
        }
        RuleOutput::FontFace(FontFaceDto { family, src })
    }
}

impl<'i> DeclarationParser<'i> for FontFaceParser {
    type Declaration = ();
    type Error = ();

    fn parse_value(
        &mut self,
        name: CowRcStr<'i>,
        input: &mut CssParser<'i>,
        _declaration_start: &ParserState,
    ) -> Result<(), ParseError<()>> {
        let value = read_raw_value(input)?;
        match name.to_ascii_lowercase().as_str() {
            "font-family" => self.family = Some(unquote(value)),
            "src" if self.src.is_none() => self.src = extract_url(value),
            _ => {}
        }
        Ok(())
    }
}

impl<'i> AtRuleParser<'i> for FontFaceParser {
    type Prelude = ();
    type AtRule = ();
    type Error = ();
}

impl<'i> QualifiedRuleParser<'i> for FontFaceParser {
    type Prelude = ();
    type QualifiedRule = ();
    type Error = ();
}

impl<'i> RuleBodyItemParser<'i, (), ()> for FontFaceParser {
    fn parse_declarations(&self) -> bool {
        true
    }

    fn parse_qualified(&self) -> bool {
        false
    }
}

/// Parses every item of a declaration list, skipping invalid ones.
fn parse_declarations<'i, P, D, E>(input: &mut CssParser<'i>, parser: &mut P) -> Vec<D>
where
    P: RuleBodyItemParser<'i, D, E>,
{
    let body: RuleBodyParser<'_, '_, P, D, E> = RuleBodyParser::new(input, parser);
    let mut out = Vec::new();
    for declaration in body.flatten() {
        out.push(declaration);
    }
    out
}

/// The raw text of a declaration value, units intact.
fn read_raw_value<'i>(input: &mut CssParser<'i>) -> Result<&'i str, ParseError<()>> {
    let start = input.position();
    while input.next().is_ok() {}
    Ok(input.slice_from(start).trim())
}

/// Splits a trailing `!important` off a raw declaration value.
fn split_important(raw: &str) -> (&str, bool) {
    let trimmed = raw.trim();
    let lower = trimmed.to_ascii_lowercase();
    if let Some(index) = lower.rfind("!important") {
        if lower[index..].trim() == "!important" {
            return (trimmed[..index].trim(), true);
        }
    }
    (trimmed, false)
}

/// Strips matching single/double quotes (straight or typographic) from a value.
fn unquote(value: &str) -> String {
    value
        .trim()
        .trim_matches(|c| matches!(c, '\'' | '"' | '\u{2018}' | '\u{2019}' | '\u{201C}' | '\u{201D}'))
        .trim()
        .to_string()
}

/// The first `url(...)` in a `src` descriptor, if any.
fn extract_url(value: &str) -> Option<String> {
    let lower = value.to_ascii_lowercase();
    let start = lower.find("url(")? + "url(".len();
    let rest = &value[start..];
    let end = rest.find(')')?;
    let inner = unquote(rest[..end].trim());
    if inner.is_empty() {
        None
    } else {
        Some(inner)
    }
}

/// Resolves a `@font-face` `src` relative to the stylesheet's directory into a
/// normalised archive key. Absolute/data/http URLs yield `None` (never fetched).
fn resolve_font_src(base_dir: &str, raw: &str) -> Option<String> {
    let clean = raw
        .split('?')
        .next()
        .unwrap_or("")
        .split('#')
        .next()
        .unwrap_or("")
        .trim();
    if clean.is_empty() {
        return None;
    }
    let lower = clean.to_ascii_lowercase();
    if lower.starts_with("data:")
        || lower.starts_with("http://")
        || lower.starts_with("https://")
        || lower.starts_with("//")
        || clean.starts_with('/')
    {
        return None;
    }
    Some(resolve_href(base_dir, clean))
}

/// Parses a comma-separated prelude into individual selectors, dropping the
/// parts that fail to parse.
fn parse_selectors(prelude: &str) -> Vec<(Selector<BurrowSelectorImpl>, u32)> {
    let mut out = Vec::new();
    for part in split_top_level_commas(prelude) {
        let mut input = CssParser::new(part);
        if let Ok(list) = SelectorList::parse(&BurrowSelectorParser, &mut input, ParseRelative::No) {
            for selector in list.slice() {
                out.push((selector.clone(), selector.specificity()));
            }
        }
    }
    out
}

/// Splits `text` on commas that are not inside `()`, `[]`, `{}`, or a string.
fn split_top_level_commas(text: &str) -> Vec<&str> {
    let mut out = Vec::new();
    let mut depth: i32 = 0;
    let mut start = 0usize;
    let mut quote: Option<char> = None;
    let mut chars = text.char_indices();
    while let Some((index, ch)) = chars.next() {
        if let Some(q) = quote {
            if ch == '\\' {
                chars.next();
            } else if ch == q {
                quote = None;
            }
            continue;
        }
        match ch {
            '"' | '\'' => quote = Some(ch),
            '(' | '[' | '{' => depth += 1,
            ')' | ']' | '}' => depth -= 1,
            ',' if depth == 0 => {
                out.push(text[start..index].trim());
                start = index + 1;
            }
            _ => {}
        }
    }
    out.push(text[start..].trim());
    out.into_iter().filter(|part| !part.is_empty()).collect()
}

/// The directory part of a normalised archive key, or `""` at the root.
fn dir_of(key: &str) -> String {
    match key.rfind('/') {
        Some(index) => key[..index].to_string(),
        None => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_rules_and_declarations_keeping_units() {
        let sheet = Stylesheet::parse("p { font-size: 1.3em; color: #336699; }", "");
        assert_eq!(sheet.rules.len(), 1);
        assert_eq!(sheet.rules[0].declarations.len(), 2);
        assert_eq!(sheet.rules[0].declarations[0].property, "font-size");
        assert_eq!(sheet.rules[0].declarations[0].value, "1.3em");
    }

    #[test]
    fn important_flag_is_split_off_the_value() {
        let decls = parse_inline_declarations("color: red !important; width: 100%");
        assert_eq!(decls[0].value, "red");
        assert!(decls[0].important);
        assert_eq!(decls[1].value, "100%");
        assert!(!decls[1].important);
    }

    #[test]
    fn a_group_keeps_the_supported_selectors_and_drops_the_rest() {
        let sheet = Stylesheet::parse("h1, p::first-letter, .x { color: red; }", "");
        // `::first-letter` is unsupported; `h1` and `.x` survive.
        assert_eq!(sheet.rules.len(), 2);
    }

    #[test]
    fn class_selector_beats_tag_selector_in_specificity() {
        let sheet = Stylesheet::parse("p { color: red; } .note { color: blue; }", "");
        let tag = sheet.rules[0].specificity;
        let class = sheet.rules[1].specificity;
        assert!(class > tag, "class specificity {class} must beat tag {tag}");
    }

    #[test]
    fn font_face_src_resolves_against_the_css_directory() {
        let faces = extract_font_faces(
            "@font-face { font-family: 'Burrow Serif'; \
             src: url('../fonts/burrow.woff2') format('woff2'); }",
            "oebps/styles/main.css",
        );
        assert_eq!(faces.len(), 1);
        assert_eq!(faces[0].family, "Burrow Serif");
        assert_eq!(faces[0].src, "oebps/fonts/burrow.woff2");
    }

    #[test]
    fn absolute_and_data_font_urls_are_skipped() {
        for src in [
            "url(https://example.com/x.woff2)",
            "url(data:font/woff2;base64,AAAA)",
            "url(/abs/x.woff2)",
        ] {
            let css = format!("@font-face {{ font-family: X; src: {src}; }}");
            assert!(extract_font_faces(&css, "oebps/a.css").is_empty(), "{src}");
        }
    }

    #[test]
    fn split_top_level_commas_respects_nesting_and_strings() {
        assert_eq!(
            split_top_level_commas("a:not(b, c), d[x=\"1,2\"]"),
            vec!["a:not(b, c)", "d[x=\"1,2\"]"]
        );
    }
}
