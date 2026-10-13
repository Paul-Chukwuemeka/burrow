//! OCF container: open the ZIP, enforce the size caps, read `container.xml`,
//! and look up entries by href.
//!
//! Lookups are keyed by the *normalised* entry path — percent-decoded and
//! lowercased — never by a manifest id. That is bug class #116 in `PLAN.md`:
//! the old Dart parser resolved external stylesheets by manifest `id`, which
//! is not an archive path, so every stylesheet silently vanished.

use std::collections::HashMap;
use std::fs::File;
use std::io::Read;
use std::sync::Mutex;

use zip::ZipArchive;

use super::model::EpubError;

/// Maximum compressed EPUB size, mirroring `DocumentParser`'s 100 MB guard.
pub const MAX_COMPRESSED_BYTES: u64 = 100 * 1024 * 1024;

/// Maximum total decompressed size, mirroring `DocumentParser`'s 512 MB guard.
///
/// A highly compressible archive can inflate far past its on-disk size, so the
/// real OOM guard is on the sum of the entries' uncompressed sizes.
pub const MAX_DECOMPRESSED_BYTES: u128 = 512 * 1024 * 1024;

/// An opened EPUB ZIP with a normalised name → raw entry-name index.
pub struct EpubArchive {
    archive: Mutex<ZipArchive<File>>,
    /// normalised key (percent-decoded, lowercased) -> raw zip entry name
    keys: HashMap<String, String>,
    /// non-directory entry names, in central-directory order
    names: Vec<String>,
}

impl EpubArchive {
    /// Opens `path`, rejecting oversized archives before parsing.
    pub fn open(path: &str) -> Result<Self, EpubError> {
        let file = File::open(path)
            .map_err(|e| EpubError::Io(format!("Cannot open EPUB: {e}")))?;
        let compressed = file.metadata().map(|m| m.len()).unwrap_or(0);
        if compressed > MAX_COMPRESSED_BYTES {
            return Err(EpubError::TooLarge(
                "EPUB file too large (limit 100 MB)".to_string(),
            ));
        }

        let archive = ZipArchive::new(file)
            .map_err(|_| EpubError::Invalid("Not a valid EPUB file".to_string()))?;

        if let Some(total) = archive.decompressed_size() {
            if total > MAX_DECOMPRESSED_BYTES {
                return Err(EpubError::TooLarge(
                    "Archive decompressed size exceeds 512 MB".to_string(),
                ));
            }
        }

        let mut names = Vec::with_capacity(archive.len());
        let mut keys = HashMap::with_capacity(archive.len());
        for name in archive.file_names() {
            let Ok(name) = name else { continue };
            let name = name.into_owned();
            if name.is_empty() || name.ends_with('/') {
                continue;
            }
            keys.insert(normalize_key(&name), name.clone());
            names.push(name);
        }

        Ok(Self {
            archive: Mutex::new(archive),
            keys,
            names,
        })
    }

    /// Raw entry names (files only) in central-directory order.
    pub fn entry_names(&self) -> &[String] {
        &self.names
    }

    /// Reads the entry whose normalised key equals `key`.
    pub fn read_by_key(&self, key: &str) -> Option<Vec<u8>> {
        let raw = self.keys.get(key)?;
        self.read(raw)
    }

    /// Resolves `href` against `base_dir` (an archive directory such as
    /// `OEBPS`), then reads the matching entry. Percent-decoding and the
    /// directory walk are tolerant, matching the Dart parser.
    pub fn read_href(&self, base_dir: &str, href: &str) -> Option<Vec<u8>> {
        let key = resolve_href(base_dir, href);
        self.read_by_key(&key)
    }

    /// Reads one raw zip entry by its exact stored name.
    pub fn read(&self, raw_name: &str) -> Option<Vec<u8>> {
        let Ok(mut archive) = self.archive.lock() else {
            return None;
        };
        let mut file = archive.by_name(raw_name).ok()?;
        let mut buf = Vec::with_capacity(file.size() as usize);
        file.read_to_end(&mut buf).ok()?;
        Some(buf)
    }

    /// Fallback cover: the first image entry whose name mentions "cover",
    /// scanning in archive order (mirrors the Dart parser's last resort).
    pub fn cover_fallback(&self) -> Option<Vec<u8>> {
        const IMAGE_EXTS: [&str; 5] = [".jpg", ".jpeg", ".png", ".webp", ".gif"];
        for name in &self.names {
            let lower = name.to_lowercase();
            let Some(dot) = lower.rfind('.') else {
                continue;
            };
            if !IMAGE_EXTS.contains(&&lower[dot..]) {
                continue;
            }
            if lower.contains("cover") {
                if let Some(bytes) = self.read(name) {
                    if !bytes.is_empty() {
                        return Some(bytes);
                    }
                }
            }
        }
        None
    }
}

/// Opens an EPUB container.
pub fn open(path: &str) -> Result<EpubArchive, EpubError> {
    EpubArchive::open(path)
}

/// Returns the OPF rootfile path declared in `META-INF/container.xml`.
pub fn container_rootfile(archive: &EpubArchive) -> Result<String, EpubError> {
    let bytes = archive
        .read_by_key(&normalize_key("META-INF/container.xml"))
        .ok_or_else(|| EpubError::Invalid("Not a valid EPUB file".to_string()))?;
    let xml = String::from_utf8_lossy(&bytes);
    parse_container_rootfile(&xml)
}

/// Parses the first non-empty `rootfile/@full-path` from container XML.
pub fn parse_container_rootfile(xml: &str) -> Result<String, EpubError> {
    use quick_xml::events::Event;
    use quick_xml::reader::Reader;

    let mut reader = Reader::from_str(xml);
    reader.config_mut().trim_text(true);
    loop {
        match reader.read_event() {
            Ok(Event::Start(e)) | Ok(Event::Empty(e)) => {
                if e.local_name().as_ref() == "rootfile" {
                    if let Some(full) = attr(&e, "full-path") {
                        if !full.is_empty() {
                            return Ok(full);
                        }
                    }
                }
            }
            Ok(Event::Eof) => break,
            Err(_) => break,
            _ => {}
        }
    }
    Err(EpubError::Invalid("Not a valid EPUB file".to_string()))
}

/// Reads an attribute value from an element by full or local name.
pub(crate) fn attr(
    e: &quick_xml::events::BytesStart<'_>,
    name: &str,
) -> Option<String> {
    for a in e.attributes().flatten() {
        let key = a.key.as_ref().to_ascii_lowercase();
        let local = a.key.local_name().as_ref().to_ascii_lowercase();
        if key == name.to_ascii_lowercase() || local == name.to_ascii_lowercase() {
            return Some(
                a.normalized_value(quick_xml::XmlVersion::Implicit1_0)
                    .map(|v| v.into_owned())
                    .unwrap_or_else(|_| a.value.to_string()),
            );
        }
    }
    None
}

/// Lowercase + percent-decode an archive path for use as a lookup key.
pub fn normalize_key(path: &str) -> String {
    decode_percent(path).to_lowercase()
}

/// Resolves `href` against `base_dir` into a normalised lookup key.
///
/// Handles fragments, `..`/`.` segments, percent-encoding, and indirection
/// through nested directories. Never panics on malformed escapes.
pub fn resolve_href(base_dir: &str, href: &str) -> String {
    let clean = href.split('#').next().unwrap_or("").trim();
    let decoded = decode_percent(clean);
    let joined = if base_dir.is_empty() {
        decoded
    } else {
        format!("{base_dir}/{decoded}")
    };
    normalize_path(&joined)
}

/// Collapses `.`/`..`/empty segments and joins with `/`.
fn normalize_path(path: &str) -> String {
    let mut out: Vec<&str> = Vec::new();
    for part in path.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                out.pop();
            }
            other => out.push(other),
        }
    }
    out.join("/")
}

/// Percent-decodes `s`, returning it unchanged when it is not valid
/// percent-encoding (e.g. a literal `%` in `100%_cover.xhtml`).
///
/// This mirrors Dart's all-or-nothing `_safeDecode`: a single stray `%` must
/// not abort the whole book, and decoding must be consistent between the href
/// and the entry name so the two still match.
pub fn decode_percent(s: &str) -> String {
    if !is_valid_percent(s) {
        return s.to_string();
    }
    percent_encoding::percent_decode_str(s)
        .decode_utf8_lossy()
        .into_owned()
}

fn is_valid_percent(s: &str) -> bool {
    let b = s.as_bytes();
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' {
            if i + 2 >= b.len()
                || !b[i + 1].is_ascii_hexdigit()
                || !b[i + 2].is_ascii_hexdigit()
            {
                return false;
            }
            i += 3;
        } else {
            i += 1;
        }
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_key_decodes_and_lowercases() {
        assert_eq!(normalize_key("OEBPS/Text/CH1.XHTML"), "oebps/text/ch1.xhtml");
        assert_eq!(normalize_key("Text/100%25_cover.xhtml"), "text/100%_cover.xhtml");
        // A bare `%` is returned unchanged rather than throwing.
        assert_eq!(normalize_key("Text/100%_cover.xhtml"), "text/100%_cover.xhtml");
    }

    #[test]
    fn resolve_href_walks_directories() {
        assert_eq!(resolve_href("OEBPS", "Images/cover.png"), "OEBPS/Images/cover.png");
        assert_eq!(resolve_href("OEBPS", "../Images/c.png"), "Images/c.png");
        assert_eq!(resolve_href("", "Text/ch1.xhtml"), "Text/ch1.xhtml");
        assert_eq!(
            resolve_href("OEBPS", "Images/Cover%20Art.png"),
            "OEBPS/Images/Cover Art.png"
        );
    }
}
