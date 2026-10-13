//! OPF package parsing: Dublin Core metadata, Calibre/EPUB3 series hints, and
//! the manifest/cover.
//!
//! The field-extraction rules intentionally match
//! `DocumentParser._parseOpfMetadata` / `_extractCover` so the Rust and Dart
//! metadata paths agree field by field (spec D14, criterion 12). Any future
//! divergence must be a classified ledger entry, not an accident.

use quick_xml::events::Event;
use quick_xml::reader::Reader;

use super::container::{self, normalize_key, EpubArchive};
use super::model::{EpubError, MetadataDto};

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
        font_faces: Vec::new(),
    })
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
            if let (Some(id), Some(href)) =
                (get(&frame.attrs, "id"), get(&frame.attrs, "href"))
            {
                out.items.push(Item {
                    id: id.to_string(),
                    href: Some(href.to_string()),
                    media_type: get(&frame.attrs, "media-type").map(str::to_string),
                    properties: get(&frame.attrs, "properties").map(str::to_string),
                });
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

fn opf_dir(path: &str) -> String {
    match path.rfind('/') {
        Some(i) => path[..i].to_string(),
        None => String::new(),
    }
}

/// Strips markup and normalises whitespace, matching the shape of
/// `DocumentParser.htmlToText` closely enough for metadata parity.
fn html_to_text(html: &str) -> String {
    let mut stripped = String::with_capacity(html.len());
    let mut in_tag = false;
    for ch in html.chars() {
        match ch {
            '<' => in_tag = true,
            '>' => in_tag = false,
            c if !in_tag => stripped.push(c),
            _ => {}
        }
    }
    let decoded = decode_entities(&stripped);
    collapse_whitespace(&decoded)
}

fn decode_entities(s: &str) -> String {
    s.replace("&nbsp;", "\u{00A0}")
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&apos;", "'")
}

/// Collapses runs of spaces/tabs to one space and trims; matches the Dart
/// `htmlToText` whitespace pass for single-line metadata.
fn collapse_whitespace(s: &str) -> String {
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
    out.trim().to_string()
}

#[cfg(test)]
mod tests {
    use super::super::container::{container_rootfile, open};
    use super::*;

    /// Fixtures live at the repo root (`test/fixtures/epub/`); `cargo test`
    /// runs with `rust/` as the working directory.
    fn fixture(name: &str) -> String {
        format!("{}/../test/fixtures/epub/{name}", env!("CARGO_MANIFEST_DIR"))
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
}
