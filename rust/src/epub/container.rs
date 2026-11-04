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

use unicode_normalization::UnicodeNormalization;
use zip::ZipArchive;

use super::model::EpubError;

/// Maximum compressed EPUB size, mirroring `DocumentParser`'s 100 MB guard.
pub const MAX_COMPRESSED_BYTES: u64 = 100 * 1024 * 1024;

/// Maximum total decompressed size, mirroring `DocumentParser`'s 512 MB guard.
///
/// A highly compressible archive can inflate far past its on-disk size, so the
/// real OOM guard is on the sum of the entries' uncompressed sizes.
pub const MAX_DECOMPRESSED_BYTES: u128 = 512 * 1024 * 1024;

/// Maximum compressed CBZ size, mirroring
/// `DocumentParser.maxComicCompressedBytes` (comics legitimately run larger
/// than EPUBs, so the cap is 500 MB rather than 100 MB).
pub const MAX_COMIC_COMPRESSED_BYTES: u64 = 500 * 1024 * 1024;

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
        Self::open_with(
            path,
            MAX_COMPRESSED_BYTES,
            "EPUB file too large (limit 100 MB)",
            "Not a valid EPUB file",
            |e| EpubError::Io(format!("Cannot open EPUB: {e}")),
        )
    }

    /// Opens a CBZ comic archive, reusing the same ZIP reader and size guards
    /// with the comic's limits and messages.
    ///
    /// Error strings match `DocumentParser._parseComicBook`'s `FormatException`
    /// messages verbatim: unreadable files are "Not a valid CBZ file" (Dart
    /// catches the read failure the same way), unparseable bytes are "Not a
    /// valid CBZ/ZIP archive", and the decompressed-size message is shared
    /// with the EPUB path.
    pub fn open_comic(path: &str) -> Result<Self, EpubError> {
        Self::open_with(
            path,
            MAX_COMIC_COMPRESSED_BYTES,
            "CBZ file too large (limit 500 MB)",
            "Not a valid CBZ/ZIP archive",
            |_| EpubError::Invalid("Not a valid CBZ file".to_string()),
        )
    }

    /// The shared ZIP opener behind [`EpubArchive::open`] and
    /// [`EpubArchive::open_comic`]: `too_large_msg`/`invalid_msg` are the
    /// format's verbatim Dart messages, and `io_error` maps an OS failure to
    /// the format's "unreadable file" error.
    fn open_with(
        path: &str,
        max_compressed: u64,
        too_large_msg: &str,
        invalid_msg: &str,
        io_error: impl FnOnce(std::io::Error) -> EpubError,
    ) -> Result<Self, EpubError> {
        let file = File::open(path).map_err(io_error)?;
        let compressed = file.metadata().map(|m| m.len()).unwrap_or(0);
        if compressed > max_compressed {
            return Err(EpubError::TooLarge(too_large_msg.to_string()));
        }

        let archive =
            ZipArchive::new(file).map_err(|_| EpubError::Invalid(invalid_msg.to_string()))?;

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

    /// Reads one resource entry by reference (spec D15).
    ///
    /// `key` is a normalised archive key such as an `ImageRunDto::source_key`
    /// or a `FontFaceDto::src`; it is normalised again so a mixed-case or
    /// percent-encoded caller cannot miss. Returns `None` when the entry is
    /// absent — the caller (projection or lazy hydration) degrades to a sized
    /// placeholder / skipped font instead of failing the book.
    pub fn read_resource(&self, key: &str) -> Option<Vec<u8>> {
        self.read_by_key(&normalize_key(key))
    }

    /// Resolves `href` against `base_dir` (an archive directory such as
    /// `OEBPS`), then reads the matching entry. Percent-decoding and the
    /// directory walk are tolerant, matching the Dart parser.
    pub fn read_href(&self, base_dir: &str, href: &str) -> Option<Vec<u8>> {
        let key = resolve_href(base_dir, href);
        self.read_by_key(&key)
    }

    /// Reads one raw zip entry by its exact stored name.
    ///
    /// The entry is read through a hard cap: the central directory's size is
    /// attacker-controlled, so a header that under-reports its size must not be
    /// able to inflate an unbounded amount of memory.
    pub fn read(&self, raw_name: &str) -> Option<Vec<u8>> {
        let Ok(mut archive) = self.archive.lock() else {
            return None;
        };
        let mut file = archive.by_name(raw_name).ok()?;
        let declared = file.size();
        if declared > MAX_DECOMPRESSED_BYTES as u64 {
            return None;
        }
        // Do not trust the declared size for the allocation either; start
        // small and let `read_to_end` grow only as real bytes arrive.
        let capacity = declared.min(16 * 1024 * 1024) as usize;
        let mut buf = Vec::with_capacity(capacity);
        let mut limited = file.by_ref().take(MAX_DECOMPRESSED_BYTES as u64 + 1);
        limited.read_to_end(&mut buf).ok()?;
        if buf.len() as u128 > MAX_DECOMPRESSED_BYTES {
            return None;
        }
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

/// Lowercase + percent-decode + NFC-normalise an archive path for use as a
/// lookup key.
///
/// Backslashes are treated as separators: some Windows-produced EPUBs store
/// `Text\ch1.xhtml` in both the manifest and the ZIP.
pub fn normalize_key(path: &str) -> String {
    decode_percent(path)
        .replace('\\', "/")
        .nfc()
        .collect::<String>()
        .to_lowercase()
}

/// Resolves `href` against `base_dir` into a normalised lookup key.
///
/// Handles fragments, `..`/`.` segments, percent-encoding, backslash
/// separators, Unicode normalisation, and indirection through nested
/// directories. Never panics on malformed escapes.
///
/// The result is **lowercased** to match [`normalize_key`], which is how the
/// key map is stored. Returning a mixed-case path here was a bug: the stored
/// keys are lowercased, so lookups silently missed unless the fallback scan
/// happened to find the entry.
pub fn resolve_href(base_dir: &str, href: &str) -> String {
    let clean = href
        .split('#')
        .next()
        .unwrap_or("")
        .trim()
        .replace('\\', "/");
    let decoded = decode_percent(&clean);
    let joined = if base_dir.is_empty() {
        decoded
    } else {
        format!("{base_dir}/{decoded}")
    };
    normalize_key(&normalize_path(&joined))
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

/// Percent-decodes `s`, decoding every valid `%XX` escape and leaving a stray
/// `%` literal.
///
/// The old all-or-nothing behaviour (mirroring Dart's `_safeDecode`) meant a
/// single literal `%` in a filename — `100%_cover.xhtml` — left *every* other
/// escape encoded, so the href no longer matched the archive entry. Decoding
/// the valid escapes keeps the common case working; the invalid `%` survives
/// as a literal, which matches the entry name.
pub fn decode_percent(s: &str) -> String {
    if !s.contains('%') {
        return s.to_string();
    }
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%'
            && index + 2 < bytes.len()
            && bytes[index + 1].is_ascii_hexdigit()
            && bytes[index + 2].is_ascii_hexdigit()
        {
            let high = (bytes[index + 1] as char).to_digit(16).unwrap();
            let low = (bytes[index + 2] as char).to_digit(16).unwrap();
            out.push((high * 16 + low) as u8);
            index += 3;
        } else {
            out.push(bytes[index]);
            index += 1;
        }
    }
    String::from_utf8_lossy(&out).into_owned()
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
    fn resolve_href_walks_directories_and_lowercases() {
        // The result is a lookup key, so it must be lowercased like the key map.
        assert_eq!(resolve_href("OEBPS", "Images/cover.png"), "oebps/images/cover.png");
        assert_eq!(resolve_href("OEBPS", "../Images/c.png"), "images/c.png");
        assert_eq!(resolve_href("", "Text/ch1.xhtml"), "text/ch1.xhtml");
        assert_eq!(
            resolve_href("OEBPS", "Images/Cover%20Art.png"),
            "oebps/images/cover art.png"
        );
    }
}
