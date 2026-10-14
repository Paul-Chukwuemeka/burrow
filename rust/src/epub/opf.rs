//! OPF package parsing: Dublin Core metadata, Calibre/EPUB3 series hints, and
//! the manifest/cover.
//!
//! The field-extraction rules intentionally match
//! `DocumentParser._parseOpfMetadata` / `_extractCover` so the Rust and Dart
//! metadata paths agree field by field (spec D14, criterion 12). Any future
//! divergence must be a classified ledger entry, not an accident.

use std::cmp::Ordering;
use std::collections::HashMap;

use quick_xml::events::Event;
use quick_xml::reader::Reader;

use super::container::{self, normalize_key, resolve_href, EpubArchive};
use super::css;
use super::model::{EpubError, FontFaceDto, MetadataDto, TocEntryDto};
use super::nav;

/// Extracts metadata and cover bytes from `path` without parsing chapters.
pub fn read_metadata(path: &str) -> Result<MetadataDto, EpubError> {
    let archive = container::open(path)?;
    read_metadata_from(&archive)
}

/// Extracts metadata from an already-open container.
pub fn read_metadata_from(archive: &EpubArchive) -> Result<MetadataDto, EpubError> {
    let opf_path = container::container_rootfile(archive)?;
    let opf_bytes = archive
        .read_by_key(&normalize_key(&opf_path))
        .ok_or_else(|| EpubError::Invalid("Not a valid EPUB file".to_string()))?;
    let opf = parse_opf(&String::from_utf8_lossy(&opf_bytes));

    // Derive everything that borrows `opf` before moving its fields out.
    let cover_bytes = extract_cover(archive, &opf, &opf_path);
    let genre = pick_genre(&opf.subjects);
    let isbn = pick_isbn(&opf.identifiers);
    let (series_name, series_index) = pick_series(&opf.metas);
    let font_faces = extract_font_faces(archive, &opf, &opf_path);

    Ok(MetadataDto {
        title: opf.title,
        author: opf.author,
        description: opf.description,
        publisher: opf.publisher,
        isbn,
        language: opf.language,
        publication_date: opf.publication_date,
        rights: opf.rights,
        genre,
        series_name,
        series_index,
        cover_bytes,
        font_faces,
    })
}

/// The resolved document structure of an EPUB: manifest, spine, and TOC.
///
/// Produced by [`read_navigation`]/[`read_navigation_from`]. Keys are the
/// *normalised* archive paths (percent-decoded, lowercased), never manifest
/// ids — see bug class `#116` in `PLAN.md`.
#[derive(Debug, Clone, Default)]
pub struct Navigation {
    /// Manifest `id` -> normalised archive key.
    pub manifest: HashMap<String, String>,
    /// Chapter documents in reading order, as normalised archive keys.
    pub spine: Vec<String>,
    /// Table-of-contents entries, in document order.
    pub toc: Vec<TocEntryDto>,
}

/// Reads the manifest, spine order, and TOC from `path`.
pub fn read_navigation(path: &str) -> Result<Navigation, EpubError> {
    let archive = container::open(path)?;
    read_navigation_from(&archive)
}

/// Reads the manifest, spine order, and TOC from an already-open container.
pub fn read_navigation_from(archive: &EpubArchive) -> Result<Navigation, EpubError> {
    let opf_path = container::container_rootfile(archive)?;
    let opf_bytes = archive
        .read_by_key(&normalize_key(&opf_path))
        .ok_or_else(|| EpubError::Invalid("Not a valid EPUB file".to_string()))?;
    let opf = parse_opf(&String::from_utf8_lossy(&opf_bytes));
    Ok(parse_navigation(archive, &opf, &opf_path))
}

/// Resolves the parsed OPF into manifest/spine/TOC, reading the TOC document.
fn parse_navigation(archive: &EpubArchive, opf: &Opf, opf_path: &str) -> Navigation {
    let base = opf_dir(opf_path);
    let key_of = |href: &str| resolve_href(&base, href);

    // Manifest: id -> resolved href. The `properties="nav"` item is the EPUB3
    // table of contents.
    let mut manifest = HashMap::new();
    let mut nav_key: Option<String> = None;
    for item in &opf.items {
        let Some(href) = &item.href else { continue };
        let key = key_of(href);
        if !item.id.is_empty() {
            manifest.insert(item.id.clone(), key.clone());
        }
        if has_property(item.properties.as_deref(), "nav") {
            nav_key = Some(key);
        }
    }

    // Spine order. An idref is resolved through the manifest to its href, not
    // treated as a path (bug class #116).
    let mut spine: Vec<String> = Vec::new();
    for idref in &opf.spine {
        if let Some(key) = manifest.get(idref) {
            if !spine.contains(key) {
                spine.push(key.clone());
            }
        }
    }
    if spine.is_empty() {
        // Fallback: every XHTML/HTML manifest entry, in natural order. This
        // covers both an absent `<spine>` and a spine whose idrefs all miss.
        spine = html_manifest_keys(opf, &base);
    }

    // TOC: the EPUB3 nav document first, then the EPUB2 NCX, then a last-resort
    // scan for any document that actually contains a `<nav>`.
    let mut toc = Vec::new();
    if let Some(key) = &nav_key {
        if let Some(bytes) = archive.read_by_key(key) {
            toc = nav::parse_nav(&String::from_utf8_lossy(&bytes), key, false);
        }
    }
    if toc.is_empty() {
        let ncx_key = opf
            .toc_id
            .as_ref()
            .and_then(|id| manifest.get(id).cloned())
            .or_else(|| {
                let mut ncx: Vec<String> = opf
                    .items
                    .iter()
                    .filter_map(|i| i.href.as_ref())
                    .map(|h| key_of(h))
                    .filter(|k| k.ends_with(".ncx"))
                    .collect();
                ncx.sort();
                ncx.into_iter().next()
            });
        if let Some(key) = ncx_key {
            if let Some(bytes) = archive.read_by_key(&key) {
                toc = nav::parse_ncx(&String::from_utf8_lossy(&bytes), &key);
            }
        }
    }
    if toc.is_empty() {
        // Last resort for books that never flag their nav document. Iterate the
        // HTML entries in natural order and require a real `<nav>` so a stray
        // link in a chapter is not mistaken for the contents.
        for key in html_manifest_keys(opf, &base) {
            if let Some(bytes) = archive.read_by_key(&key) {
                let entries = nav::parse_nav(&String::from_utf8_lossy(&bytes), &key, true);
                if !entries.is_empty() {
                    toc = entries;
                    break;
                }
            }
        }
    }

    Navigation {
        manifest,
        spine,
        toc,
    }
}

/// XHTML/HTML manifest entries as normalised keys, natural-sorted and deduped.
fn html_manifest_keys(opf: &Opf, base: &str) -> Vec<String> {
    let mut keys: Vec<String> = opf
        .items
        .iter()
        .filter_map(|i| i.href.as_ref())
        .map(|h| resolve_href(base, h))
        .filter(|k| is_html_key(k))
        .collect();
    keys.sort_by(|a, b| natural_compare(a, b));
    keys.dedup();
    keys
}

fn is_html_key(key: &str) -> bool {
    key.ends_with(".xhtml") || key.ends_with(".html") || key.ends_with(".htm")
}

fn has_property(properties: Option<&str>, want: &str) -> bool {
    properties
        .map(|p| p.split_whitespace().any(|t| t == want))
        .unwrap_or(false)
}

/// The chapter list's titles, in reading order.
///
/// TOC entries targeting a spine document supply its titles (one chapter per
/// entry, so anchors split a document); a spine document with no entry — and
/// every document in a book with no TOC at all — falls back to its own
/// `<title>`/`<h1>`. Dart's `splitByAnchors` leaves those titles empty; this is
/// a deliberate improvement (spec D11), not an accidental divergence.
pub fn chapter_titles(archive: &EpubArchive, navigation: &Navigation) -> Vec<String> {
    let mut out = Vec::new();
    for key in &navigation.spine {
        let entries: Vec<&TocEntryDto> = navigation
            .toc
            .iter()
            .filter(|e| &e.file_key == key)
            .collect();
        if entries.is_empty() {
            out.push(chapter_title_for(archive, key));
        } else {
            out.extend(entries.into_iter().map(|e| e.title.clone()));
        }
    }
    out
}

fn chapter_title_for(archive: &EpubArchive, key: &str) -> String {
    archive
        .read_by_key(key)
        .and_then(|bytes| nav::document_title(&String::from_utf8_lossy(&bytes)))
        .unwrap_or_default()
}

/// Natural sort comparator for filenames, mirroring
/// `DocumentParser._naturalCompare`: numeric runs compare numerically, the rest
/// compares code point by code point, and a prefix sorts first.
pub fn natural_compare(a: &str, b: &str) -> Ordering {
    natural_compare_impl(&a.to_lowercase(), &b.to_lowercase())
}

fn natural_compare_impl(a: &str, b: &str) -> Ordering {
    let ar: Vec<char> = a.chars().collect();
    let br: Vec<char> = b.chars().collect();
    let (mut ia, mut ib) = (0usize, 0usize);
    while ia < ar.len() && ib < br.len() {
        let (ca, cb) = (ar[ia], br[ib]);
        if ca.is_ascii_digit() && cb.is_ascii_digit() {
            let mut na: u64 = 0;
            let mut nb: u64 = 0;
            while ia < ar.len() && ar[ia].is_ascii_digit() {
                na = na * 10 + (ar[ia] as u64 - '0' as u64);
                ia += 1;
            }
            while ib < br.len() && br[ib].is_ascii_digit() {
                nb = nb * 10 + (br[ib] as u64 - '0' as u64);
                ib += 1;
            }
            if na != nb {
                return na.cmp(&nb);
            }
        } else {
            if ca != cb {
                return ca.cmp(&cb);
            }
            ia += 1;
            ib += 1;
        }
    }
    ar.len().cmp(&br.len())
}

#[derive(Debug, Default)]
struct Opf {
    title: String,
    author: String,
    description: Option<String>,
    language: Option<String>,
    publisher: Option<String>,
    publication_date: Option<String>,
    rights: Option<String>,
    subjects: Vec<String>,
    identifiers: Vec<(Option<String>, String)>,
    metas: Vec<Meta>,
    items: Vec<Item>,
    /// `<itemref idref>` values, in spine order.
    spine: Vec<String>,
    /// `<spine toc="...">` — the manifest id of the NCX document, if declared.
    toc_id: Option<String>,
}

#[derive(Debug, Default)]
struct Meta {
    name: Option<String>,
    content: Option<String>,
    property: Option<String>,
    text: String,
}

#[derive(Debug, Default)]
struct Item {
    id: String,
    href: Option<String>,
    media_type: Option<String>,
    properties: Option<String>,
}

struct Attr {
    full: String,
    local: String,
    value: String,
}

fn get<'a>(attrs: &'a [Attr], name: &str) -> Option<&'a str> {
    let n = name.to_ascii_lowercase();
    attrs
        .iter()
        .find(|a| a.full == n || a.local == n)
        .map(|a| a.value.as_str())
}

struct Frame {
    name: String,
    attrs: Vec<Attr>,
    text: String,
}

fn frame_of(e: &quick_xml::events::BytesStart<'_>) -> Frame {
    let attrs = e
        .attributes()
        .flatten()
        .map(|a| Attr {
            full: a.key.as_ref().to_ascii_lowercase(),
            local: a.key.local_name().as_ref().to_ascii_lowercase(),
            value: a
                .normalized_value(quick_xml::XmlVersion::Implicit1_0)
                .map(|v| v.into_owned())
                .unwrap_or_else(|_| a.value.to_string()),
        })
        .collect();
    Frame {
        name: e.local_name().as_ref().to_string(),
        attrs,
        text: String::new(),
    }
}

/// Parses the OPF package into the raw field set. Malformed XML is tolerated
/// (whatever was parsed before the error is kept) so one bad OPF attribute
/// cannot make a whole book unreadable.
fn parse_opf(xml: &str) -> Opf {
    let mut reader = Reader::from_str(xml);
    reader.config_mut().trim_text(true);

    let mut out = Opf::default();
    let mut stack: Vec<Frame> = Vec::new();
    loop {
        match reader.read_event() {
            Ok(Event::Start(e)) => stack.push(frame_of(&e)),
            Ok(Event::Empty(e)) => handle(&mut out, &frame_of(&e)),
            Ok(Event::Text(e)) => {
                if let Some(top) = stack.last_mut() {
                    top.text.push_str(&e.into_inner());
                }
            }
            Ok(Event::CData(e)) => {
                if let Some(top) = stack.last_mut() {
                    top.text.push_str(&e.into_inner());
                }
            }
            // quick-xml 0.42 emits entities separately from text, so `&amp;`
            // in a title arrives here rather than inside the `Text` event.
            Ok(Event::GeneralRef(e)) => {
                if let Some(top) = stack.last_mut() {
                    append_entity(&mut top.text, &e);
                }
            }
            Ok(Event::End(_)) => {
                if let Some(frame) = stack.pop() {
                    handle(&mut out, &frame);
                    if let Some(parent) = stack.last_mut() {
                        parent.text.push_str(&frame.text);
                    }
                }
            }
            Ok(Event::Eof) => break,
            // Tolerate malformed OPF: keep what parsed.
            Err(_) => break,
            _ => {}
        }
    }
    out
}

/// Resolves a `&name;` / `&#38;` reference event into text.
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

fn handle(out: &mut Opf, frame: &Frame) {
    let text = frame.text.trim();
    match frame.name.as_str() {
        "title" => {
            if out.title.is_empty() && !text.is_empty() {
                out.title = text.to_string();
            }
        }
        "creator" => {
            if out.author.is_empty() && !text.is_empty() {
                out.author = text.to_string();
            }
        }
        "description" => {
            if out.description.is_none() {
                let d = html_to_text(text);
                if !d.is_empty() {
                    out.description = Some(d);
                }
            }
        }
        "language" => set_once(&mut out.language, text),
        "publisher" => set_once(&mut out.publisher, text),
        "date" => set_once(&mut out.publication_date, text),
        "rights" => set_once(&mut out.rights, text),
        "subject" => {
            if !text.is_empty() {
                out.subjects.push(text.to_string());
            }
        }
        "identifier" => out.identifiers.push((
            get(&frame.attrs, "scheme").map(str::to_string),
            text.to_string(),
        )),
        "meta" => out.metas.push(Meta {
            name: get(&frame.attrs, "name").map(str::to_string),
            content: get(&frame.attrs, "content").map(str::to_string),
            property: get(&frame.attrs, "property").map(str::to_string),
            text: text.to_string(),
        }),
        "item" => {
            if let (Some(id), Some(href)) = (get(&frame.attrs, "id"), get(&frame.attrs, "href")) {
                out.items.push(Item {
                    id: id.to_string(),
                    href: Some(href.to_string()),
                    media_type: get(&frame.attrs, "media-type").map(str::to_string),
                    properties: get(&frame.attrs, "properties").map(str::to_string),
                });
            }
        }
        "itemref" => {
            if let Some(idref) = get(&frame.attrs, "idref") {
                out.spine.push(idref.to_string());
            }
        }
        "spine" => {
            if out.toc_id.is_none() {
                out.toc_id = get(&frame.attrs, "toc").map(str::to_string);
            }
        }
        _ => {}
    }
}

fn set_once(slot: &mut Option<String>, text: &str) {
    if slot.is_none() && !text.is_empty() {
        *slot = Some(text.to_string());
    }
}

fn pick_genre(subjects: &[String]) -> Option<String> {
    if subjects.is_empty() {
        None
    } else {
        Some(subjects.join(", "))
    }
}

/// Mirrors Dart: an explicit `scheme="isbn"` wins; otherwise the first
/// identifier matching ISBN-10 (`9 digits + digit/X`) is used.
fn pick_isbn(ids: &[(Option<String>, String)]) -> Option<String> {
    let mut isbn: Option<String> = None;
    for (scheme, raw) in ids {
        let scheme = scheme.as_deref().unwrap_or("").to_lowercase();
        let stripped: String = raw.chars().filter(|c| *c != '-').collect();
        if scheme == "isbn" {
            return Some(raw.clone());
        }
        if isbn.is_none() && is_isbn10(&stripped) {
            isbn = Some(raw.clone());
        }
    }
    isbn
}

fn is_isbn10(v: &str) -> bool {
    let b = v.as_bytes();
    b.len() == 10
        && b[..9].iter().all(u8::is_ascii_digit)
        && (b[9].is_ascii_digit() || b[9] == b'X' || b[9] == b'x')
}

/// Calibre's `calibre:series` / `calibre:series_index` metas, falling back to
/// the EPUB3 `belongs-to-series` / `group-position` properties.
fn pick_series(metas: &[Meta]) -> (Option<String>, Option<f64>) {
    let mut name: Option<String> = None;
    let mut index: Option<f64> = None;
    for m in metas {
        match m.name.as_deref() {
            Some("calibre:series") => {
                name = m
                    .content
                    .as_deref()
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .map(str::to_string);
            }
            Some("calibre:series_index") => {
                index = m.content.as_deref().and_then(|s| s.trim().parse().ok());
            }
            _ => {}
        }
    }
    if name.is_none() {
        for m in metas {
            match m.property.as_deref() {
                Some("belongs-to-series") => {
                    let t = m.text.trim();
                    if !t.is_empty() {
                        name = Some(t.to_string());
                    }
                }
                Some("group-position") => {
                    if index.is_none() {
                        index = m.text.trim().parse().ok();
                    }
                }
                _ => {}
            }
        }
    }
    (name, index)
}

/// Cover bytes: EPUB3 `properties="cover-image"`, then `meta name="cover"`,
/// then any image entry named like a cover.
fn extract_cover(archive: &EpubArchive, opf: &Opf, opf_path: &str) -> Option<Vec<u8>> {
    let base = opf_dir(opf_path);

    for item in &opf.items {
        let is_cover = item
            .properties
            .as_deref()
            .map(|p| p.split_whitespace().any(|t| t == "cover-image"))
            .unwrap_or(false);
        if is_cover {
            if let Some(href) = &item.href {
                if let Some(bytes) = archive.read_href(&base, href) {
                    if !bytes.is_empty() {
                        return Some(bytes);
                    }
                }
            }
        }
    }

    for meta in &opf.metas {
        let is_cover_meta = meta
            .name
            .as_deref()
            .map(|n| n.eq_ignore_ascii_case("cover"))
            .unwrap_or(false);
        if !is_cover_meta {
            continue;
        }
        let Some(id) = &meta.content else { continue };
        for item in &opf.items {
            if item.id != *id {
                continue;
            }
            let is_image = item
                .media_type
                .as_deref()
                .map(|m| m.starts_with("image/"))
                .unwrap_or(false);
            if !is_image {
                continue;
            }
            if let Some(href) = &item.href {
                if let Some(bytes) = archive.read_href(&base, href) {
                    if !bytes.is_empty() {
                        return Some(bytes);
                    }
                }
            }
        }
    }

    archive.cover_fallback()
}

/// `@font-face` declarations from the book's external stylesheets.
///
/// Mirrors `EpubCssParser`: only manifest `.css` files are scanned (inline
/// `<style>` blocks are not), and each font `url()` resolves against the
/// stylesheet's own directory.
fn extract_font_faces(archive: &EpubArchive, opf: &Opf, opf_path: &str) -> Vec<FontFaceDto> {
    let base = opf_dir(opf_path);
    let mut faces: Vec<FontFaceDto> = Vec::new();
    for item in &opf.items {
        let Some(href) = &item.href else { continue };
        if !href.to_ascii_lowercase().ends_with(".css") {
            continue;
        }
        let key = resolve_href(&base, href);
        if let Some(bytes) = archive.read_by_key(&key) {
            let text = String::from_utf8_lossy(&bytes);
            for face in css::extract_font_faces(&text, &key) {
                if !faces.contains(&face) {
                    faces.push(face);
                }
            }
        }
    }
    faces
}

fn opf_dir(path: &str) -> String {
    match path.rfind('/') {
        Some(i) => path[..i].to_string(),
        None => String::new(),
    }
}

/// Strips markup and normalises whitespace, mirroring
/// `DocumentParser.htmlToText` exactly: block tags become newlines, remaining
/// tags are stripped, entities decoded, whitespace collapsed.
fn html_to_text(html: &str) -> String {
    let s = strip_non_content(html);
    let s = replace_block_tags(&s);
    let s = strip_tags(&s);
    let s = decode_html_entities(&s);
    collapse_html_whitespace(&s)
}

/// Removes `<!-- -->` comments and whole `head`/`style`/`script` elements, so
/// their bodies never survive tag stripping as raw text (matching Dart's
/// `_stripNonContent`). An unclosed element is left untouched.
fn strip_non_content(html: &str) -> String {
    let mut s = strip_comments(html);
    for tag in ["head", "style", "script"] {
        s = strip_element(&s, tag);
    }
    s
}

fn strip_comments(html: &str) -> String {
    let bytes = html.as_bytes();
    let mut out = String::with_capacity(html.len());
    let mut i = 0;
    while i < bytes.len() {
        if html[i..].starts_with("<!--") {
            if let Some(end) = html[i..].find("-->") {
                i += end + 3;
                continue;
            }
        }
        // Copy one char (byte-safe: the needle is pure ASCII).
        let ch = html[i..].chars().next().unwrap();
        out.push(ch);
        i += ch.len_utf8();
    }
    out
}

/// Removes `<tag ...>...</close>` spans (ASCII case-insensitive), leaving the
/// text untouched when the element never closes.
fn strip_element(html: &str, tag: &str) -> String {
    let mut out = String::with_capacity(html.len());
    let mut rest = html;
    while let Some((open_start, content_start)) = find_open_tag(rest, tag) {
        if let Some(close_end) = find_close_tag(&rest[content_start..], tag) {
            out.push_str(&rest[..open_start]);
            rest = &rest[content_start + close_end..];
        } else {
            break;
        }
    }
    out.push_str(rest);
    out
}

/// Finds `<tag ...>` (ASCII case-insensitive) at or after the start of `s`.
/// Returns the open tag's start and the offset where its content begins.
fn find_open_tag(s: &str, tag: &str) -> Option<(usize, usize)> {
    let mut i = 0;
    while i < s.len() {
        let rel = find_ascii_insensitive(&s[i..], "<")?;
        let mut j = i + rel + 1;
        if matches!(s.as_bytes().get(j), Some(b'/')) {
            i = j + 1;
            continue;
        }
        if ascii_tag_name(&s[j..]) == Some(tag.len())
            && tag_eq_ascii(&s[j..j + tag.len()], tag)
            && is_tag_boundary(s.as_bytes().get(j + tag.len()))
        {
            j += tag.len();
            while j < s.len() && s.as_bytes()[j] != b'>' {
                j += 1;
            }
            if j < s.len() {
                return Some((i + rel, j + 1));
            }
            return None;
        }
        i = j + 1;
    }
    None
}

/// Finds `</tag ...>` (ASCII case-insensitive) and returns the offset just
/// past its `>`, relative to `s`. An unterminated close tag does not match.
fn find_close_tag(s: &str, tag: &str) -> Option<usize> {
    let mut i = 0;
    while i < s.len() {
        let rel = find_ascii_insensitive(&s[i..], "</")?;
        let mut j = i + rel + 2;
        while matches!(s.as_bytes().get(j), Some(b' ' | b'\t' | b'\n' | b'\r')) {
            j += 1;
        }
        if tag_eq_ascii(s.get(j..j + tag.len()).unwrap_or(""), tag)
            && is_tag_boundary(s.as_bytes().get(j + tag.len()))
        {
            j += tag.len();
            while j < s.len() && s.as_bytes()[j] != b'>' {
                j += 1;
            }
            if j < s.len() {
                return Some(j + 1);
            }
            return None;
        }
        i = j + 1;
    }
    None
}

/// Byte offset of `needle` in `haystack`, matching ASCII case-insensitively.
/// Both are pure ASCII here, so byte offsets are char boundaries.
fn find_ascii_insensitive(haystack: &str, needle: &str) -> Option<usize> {
    let h = haystack.as_bytes();
    let n = needle.as_bytes();
    if n.is_empty() || n.len() > h.len() {
        return None;
    }
    (0..=h.len() - n.len()).find(|&i| h[i..i + n.len()].eq_ignore_ascii_case(n))
}

fn tag_eq_ascii(s: &str, tag: &str) -> bool {
    s.as_bytes().eq_ignore_ascii_case(tag.as_bytes())
}

/// The length of the ASCII alphanumeric run at the start of `s`, if any.
fn ascii_tag_name(s: &str) -> Option<usize> {
    let len: usize = s.bytes().take_while(u8::is_ascii_alphanumeric).count();
    if len == 0 {
        None
    } else {
        Some(len)
    }
}

/// True when `b` ends a tag name (Dart's `\b`): anything but a word char.
fn is_tag_boundary(b: Option<&u8>) -> bool {
    !matches!(b, Some(c) if c.is_ascii_alphanumeric() || *c == b'_')
}

/// Block tags whose open/close each contribute a newline, mirroring Dart's
/// `_blockTagRe` (`</?(p|div|h[1-6]|li|tr|br|section|article|blockquote)\b[^>]*>`,
/// case-insensitive). An unterminated `<` is kept literally.
fn replace_block_tags(html: &str) -> String {
    let mut out = String::with_capacity(html.len());
    let mut i = 0;
    while i < html.len() {
        let bytes = html.as_bytes();
        if bytes[i] != b'<' {
            let ch = html[i..].chars().next().unwrap();
            out.push(ch);
            i += ch.len_utf8();
            continue;
        }
        let mut j = i + 1;
        if matches!(bytes.get(j), Some(b'/')) {
            j += 1;
        }
        let name_len = ascii_tag_name(html.get(j..).unwrap_or(""));
        let mut matched = false;
        if let Some(len) = name_len {
            let name = html[j..j + len].to_ascii_lowercase();
            if is_block_tag_name(&name) && is_tag_boundary(bytes.get(j + len)) {
                let mut k = j + len;
                while k < html.len() && bytes[k] != b'>' {
                    k += 1;
                }
                if k < html.len() {
                    out.push('\n');
                    i = k + 1;
                    matched = true;
                }
            }
        }
        if !matched {
            out.push('<');
            i += 1;
        }
    }
    out
}

fn is_block_tag_name(name: &str) -> bool {
    matches!(
        name,
        "p" | "div"
            | "h1"
            | "h2"
            | "h3"
            | "h4"
            | "h5"
            | "h6"
            | "li"
            | "tr"
            | "br"
            | "section"
            | "article"
            | "blockquote"
    )
}

/// Removes every `<...>` span; an unterminated `<` is kept (matching Dart's
/// `<[^>]*>` strip).
fn strip_tags(html: &str) -> String {
    let mut out = String::with_capacity(html.len());
    let mut i = 0;
    while i < html.len() {
        if html.as_bytes()[i] != b'<' {
            let ch = html[i..].chars().next().unwrap();
            out.push(ch);
            i += ch.len_utf8();
            continue;
        }
        match html[i..].find('>') {
            Some(rel) => i += rel + 1,
            None => {
                out.push_str(&html[i..]);
                break;
            }
        }
    }
    out
}

/// Decodes the entities Dart's `_decodeEntities` recognises (named + decimal +
/// hex); anything else — including unknown named entities — stays literal.
/// `&nbsp;` becomes a plain space, not U+00A0.
fn decode_html_entities(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(amp) = rest.find('&') {
        out.push_str(&rest[..amp]);
        rest = &rest[amp..];
        let Some(semi) = rest.find(';') else {
            out.push_str(rest);
            break;
        };
        // An intervening `&` or whitespace ends the candidate (Dart's regex
        // only matches `&name;` with no gaps).
        let body = &rest[1..semi];
        if body.contains('&') || body.contains(char::is_whitespace) {
            out.push('&');
            rest = &rest[1..];
            continue;
        }
        match decode_entity_body(body) {
            Some(text) => {
                out.push_str(&text);
                rest = &rest[semi + 1..];
            }
            None => {
                out.push('&');
                rest = &rest[1..];
            }
        }
    }
    out.push_str(rest);
    out
}

fn decode_entity_body(body: &str) -> Option<String> {
    match body {
        "amp" => Some("&".to_string()),
        "lt" => Some("<".to_string()),
        "gt" => Some(">".to_string()),
        "quot" => Some("\"".to_string()),
        "apos" => Some("'".to_string()),
        "nbsp" => Some(" ".to_string()),
        "mdash" => Some("\u{2014}".to_string()),
        "ndash" => Some("\u{2013}".to_string()),
        "hellip" => Some("\u{2026}".to_string()),
        "lsquo" => Some("\u{2018}".to_string()),
        "rsquo" => Some("\u{2019}".to_string()),
        "ldquo" => Some("\u{201C}".to_string()),
        "rdquo" => Some("\u{201D}".to_string()),
        _ => {
            let digits = body
                .strip_prefix("#x")
                .and_then(|h| u32::from_str_radix(h, 16).ok())
                .or_else(|| body.strip_prefix('#').and_then(|d| d.parse::<u32>().ok()))?;
            if digits <= 0x10FFFF && !(0xD800..=0xDFFF).contains(&digits) {
                char::from_u32(digits).map(|c| c.to_string())
            } else {
                None
            }
        }
    }
}

/// Collapses whitespace exactly like Dart's `htmlToText`: horizontal runs to
/// one space, spaces after newlines dropped, 3+ newlines to two, then trim.
fn collapse_html_whitespace(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut prev_space = false;
    for ch in s.chars() {
        if matches!(ch, ' ' | '\t' | '\r' | '\u{0C}' | '\u{0B}') {
            if !prev_space {
                out.push(' ');
                prev_space = true;
            }
        } else {
            out.push(ch);
            prev_space = false;
        }
    }
    // `\n[ \t]+` -> `\n`.
    let mut nospace = String::with_capacity(out.len());
    let mut chars = out.chars().peekable();
    while let Some(ch) = chars.next() {
        nospace.push(ch);
        if ch == '\n' {
            while matches!(chars.peek(), Some(' ' | '\t')) {
                chars.next();
            }
        }
    }
    // `\n{3,}` -> `\n\n`.
    let mut collapsed = String::with_capacity(nospace.len());
    let mut run = 0;
    for ch in nospace.chars() {
        if ch == '\n' {
            run += 1;
            if run <= 2 {
                collapsed.push(ch);
            }
        } else {
            run = 0;
            collapsed.push(ch);
        }
    }
    collapsed.trim().to_string()
}

#[cfg(test)]
mod tests {
    use super::super::container::{container_rootfile, open};
    use super::*;

    /// Fixtures live at the repo root (`test/fixtures/epub/`); `cargo test`
    /// runs with `rust/` as the working directory.
    fn fixture(name: &str) -> String {
        format!(
            "{}/../test/fixtures/epub/{name}",
            env!("CARGO_MANIFEST_DIR")
        )
    }

    #[test]
    fn reads_opf_path_from_container() {
        let z = open(&fixture("minimal.epub")).unwrap();
        assert_eq!(container_rootfile(&z).unwrap(), "OEBPS/content.opf");
    }

    #[test]
    fn extracts_dublin_core_metadata() {
        let m = read_metadata(&fixture("minimal.epub")).unwrap();
        assert_eq!(m.title, "Minimal Book");
        assert_eq!(m.author, "A. Author");
    }

    #[test]
    fn percent_encoded_paths_do_not_throw() {
        assert!(read_metadata(&fixture("percent-path.epub")).is_ok());
    }

    #[test]
    fn description_with_escaped_block_markup_keeps_paragraph_breaks() {
        // Dart's `htmlToText` turns block tags into newlines; the Rust port
        // must too (parity item 7). `innerText` unescapes the entities first,
        // so `parse_opf` sees literal `<p>` tags here.
        let opf = super::parse_opf(
            r#"<package><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>T</dc:title>
            <dc:description>&lt;p&gt;First para.&lt;/p&gt;&lt;p&gt;Second para.&lt;/p&gt;</dc:description>
            </metadata></package>"#,
        );
        assert_eq!(
            opf.description.as_deref(),
            Some("First para.\n\nSecond para.")
        );
    }

    #[test]
    fn description_entities_match_the_dart_decoder() {
        // `&nbsp;` decodes to a plain space (not U+00A0), like Dart.
        let opf = super::parse_opf(
            r#"<package><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>T</dc:title>
            <dc:description>A&nbsp;B&mdash;C&#65;</dc:description>
            </metadata></package>"#,
        );
        assert_eq!(opf.description.as_deref(), Some("A B\u{2014}CA"));
    }
}
