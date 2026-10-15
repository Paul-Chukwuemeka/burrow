//! CBZ comic parsing: image entries as full-page chapters.
//!
//! A direct port of the CBZ branch of Dart's `DocumentParser._parseComicBook`
//! (`lib/services/document_parser.dart`): image entries (and only image
//! entries) are natural-sorted, each becomes a chapter holding a single
//! full-width [`ImageRun`](crate::epub::project::ImageRunDto)-shaped page,
//! and the first page doubles as the cover. Unlike the EPUB path, page bytes
//! cross the FFI by value: comics have no OPF handle for on-demand hydration,
//! so the DTO carries them.
//!
//! Two Dart helpers are ported verbatim because `comic_page_provider.dart`
//! shares them: [`is_image_entry`] (`_isImage`) and
//! [`decode_image_dimensions`] (`_decodeImageDimensions`, PNG/JPEG/GIF/
//! BMP/WebP/SVG header sniffing with a `(0, 0)` unknown fallback).

use std::sync::OnceLock;

use regex::Regex;

use super::container::EpubArchive;
use super::opf::natural_compare;

/// Image extensions the Dart parser recognises (lowercased, with the dot).
const IMAGE_EXTS: [&str; 6] = [".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp"];

/// One comic page: the equivalent of a Dart `Chapter`'s single
/// full-page `ImageRun` (title, raw entry name, bytes, intrinsic size).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ComicPageDto {
    pub title: String,
    pub entry_name: String,
    pub image_bytes: Vec<u8>,
    pub width: u32,
    pub height: u32,
}

/// A parsed CBZ: natural-sorted pages plus the cover (the first page's bytes,
/// matching Dart's `_parseComicBook`, which returns the cover un-downscaled
/// on the parse path).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ParsedComicDto {
    pub pages: Vec<ComicPageDto>,
    pub cover_bytes: Vec<u8>,
}

/// True when `name` ends in a recognised image extension (case-insensitive).
///
/// A port of `DocumentParser._isImage`: a bare `lower.endsWith(ext)` per
/// extension, so `.svg`, `.tiff` and extension-less names are not pages.
pub fn is_image_entry(name: &str) -> bool {
    let lower = name.to_lowercase();
    IMAGE_EXTS.iter().any(|ext| lower.ends_with(ext))
}

/// The entry's file name without its extension (a port of
/// `DocumentParser._filenameWithoutExtension`: splits on `/` only, strips at
/// the last `.` when it is not the first char).
pub fn filename_without_extension(path: &str) -> String {
    let name = path.rsplit('/').next().unwrap_or(path);
    match name.rfind('.') {
        Some(dot) if dot > 0 => name[..dot].to_string(),
        _ => name.to_string(),
    }
}

/// Parses a CBZ file into natural-sorted pages (the `parse_cbz` behind the
/// FFI).
///
/// Error strings match `DocumentParser._parseComicBook`'s `FormatException`
/// messages verbatim so the Dart adapter can translate them back.
pub fn parse_cbz(path: &str) -> Result<ParsedComicDto, String> {
    let archive = EpubArchive::open_comic(path).map_err(|e| e.to_string())?;
    let mut names: Vec<String> = archive
        .entry_names()
        .iter()
        .filter(|name| is_image_entry(name))
        .cloned()
        .collect();
    // Natural sort: "page2.png" before "page10.png" (Review Focus #3).
    names.sort_by(|a, b| natural_compare(a, b));
    if names.is_empty() {
        return Err("No images found in comic archive".to_string());
    }

    let mut pages = Vec::with_capacity(names.len());
    for (index, name) in names.iter().enumerate() {
        let bytes = archive
            .read(name)
            .ok_or_else(|| format!("Entry not found: {name}"))?;
        let (width, height) = decode_image_dimensions(&bytes);
        let stem = filename_without_extension(name);
        let title = if stem.is_empty() {
            format!("Page {}", index + 1)
        } else {
            stem
        };
        pages.push(ComicPageDto {
            title,
            entry_name: name.clone(),
            image_bytes: bytes,
            width,
            height,
        });
    }
    let cover_bytes = pages[0].image_bytes.clone();
    Ok(ParsedComicDto { pages, cover_bytes })
}

/// Reads width/height from common image headers (PNG/JPEG/GIF/BMP/WebP/SVG).
///
/// A port of `DocumentParser._decodeImageDimensions`: falls back to `(0, 0)`
/// on failure, which callers treat as "unknown".
pub fn decode_image_dimensions(bytes: &[u8]) -> (u32, u32) {
    if bytes.len() >= 24
        && bytes[0] == 0x89
        && bytes[1] == 0x50
        && bytes[2] == 0x4E
        && bytes[3] == 0x47
    {
        // PNG: width at offset 16, height at offset 20 (big-endian uint32).
        let w = u32::from_be_bytes([bytes[16], bytes[17], bytes[18], bytes[19]]);
        let h = u32::from_be_bytes([bytes[20], bytes[21], bytes[22], bytes[23]]);
        return (w, h);
    }
    if bytes.len() >= 10 && bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46
    {
        // GIF: logical screen width/height, little-endian uint16 at 6/8.
        let w = u16::from_le_bytes([bytes[6], bytes[7]]) as u32;
        let h = u16::from_le_bytes([bytes[8], bytes[9]]) as u32;
        return (w, h);
    }
    if bytes.len() >= 26 && bytes[0] == 0x42 && bytes[1] == 0x4D {
        // BMP: int32 LE width at 18, height at 22 (may be negative top-down).
        let w =
            i32::from_le_bytes([bytes[18], bytes[19], bytes[20], bytes[21]]).unsigned_abs();
        let h =
            i32::from_le_bytes([bytes[22], bytes[23], bytes[24], bytes[25]]).unsigned_abs();
        return (w, h);
    }
    if bytes.len() >= 30
        && bytes[0] == 0x52
        && bytes[1] == 0x49
        && bytes[2] == 0x46
        && bytes[3] == 0x46
        && bytes[8] == 0x57
        && bytes[9] == 0x45
        && bytes[10] == 0x42
        && bytes[11] == 0x50
    {
        // WebP: RIFF container; parse the first chunk's canvas size.
        let fourcc = &bytes[12..16];
        if fourcc == b"VP8X" {
            let w = 1 + (bytes[24] as u32
                | ((bytes[25] as u32) << 8)
                | ((bytes[26] as u32) << 16));
            let h = 1 + (bytes[27] as u32
                | ((bytes[28] as u32) << 8)
                | ((bytes[29] as u32) << 16));
            return (w, h);
        }
        if fourcc == b"VP8L" {
            let (b0, b1, b2, b3) =
                (bytes[21] as u32, bytes[22] as u32, bytes[23] as u32, bytes[24] as u32);
            let w = 1 + (((b1 & 0x3F) << 8) | b0);
            let h = 1 + (((b3 & 0x0F) << 10) | (b2 << 2) | ((b1 & 0xC0) >> 6));
            return (w, h);
        }
        if fourcc == b"VP8 " {
            let w = (bytes[26] as u32 | ((bytes[27] as u32) << 8)) & 0x3FFF;
            let h = (bytes[28] as u32 | ((bytes[29] as u32) << 8)) & 0x3FFF;
            return (w, h);
        }
    }
    if looks_like_svg(bytes) {
        let (w, h) = decode_svg_dimensions(bytes);
        if w > 0 && h > 0 {
            return (w, h);
        }
    }
    if bytes.len() >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8 {
        // JPEG: scan for SOF0–SOF15 marker (0xFFC0–0xFFCF).
        let mut i = 2usize;
        while i + 9 < bytes.len() {
            if bytes[i] != 0xFF {
                i += 1;
                continue;
            }
            let marker = bytes[i + 1];
            if (0xC0..=0xCF).contains(&marker)
                && marker != 0xC4
                && marker != 0xC8
                && marker != 0xCC
            {
                let h = ((bytes[i + 5] as u32) << 8) | bytes[i + 6] as u32;
                let w = ((bytes[i + 7] as u32) << 8) | bytes[i + 8] as u32;
                return (w, h);
            }
            let len = ((bytes[i + 2] as usize) << 8) | bytes[i + 3] as usize;
            i += 2 + len;
        }
    }
    (0, 0)
}

/// True when the bytes open as XML/SVG, ignoring a UTF-8 BOM and whitespace
/// (a port of `DocumentParser._looksLikeSvg`, first 64 bytes only).
fn looks_like_svg(bytes: &[u8]) -> bool {
    for &b in bytes.iter().take(64) {
        if b == 0x3C {
            return true; // '<'
        }
        if !matches!(b, 0x20 | 0x09 | 0x0A | 0x0D | 0xEF | 0xBB | 0xBF) {
            return false;
        }
    }
    false
}

fn viewbox_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r#"viewBox\s*=\s*["']([^"']+)["']"#).expect("viewBox regex")
    })
}

fn svg_width_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    // Dart's `\d` is ASCII-only, hence `[0-9]` (see `txt.rs`).
    RE.get_or_init(|| {
        Regex::new(r#"\bwidth\s*=\s*["']([0-9.]+)"#).expect("svg width regex")
    })
}

fn svg_height_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r#"\bheight\s*=\s*["']([0-9.]+)"#).expect("svg height regex")
    })
}

/// Parses an SVG dimension the way Dart's `double.tryParse` does: finite,
/// positive, rounded half away from zero. `None` when absent or unusable.
fn parse_svg_number(raw: &str) -> Option<u32> {
    let value: f64 = raw.parse().ok()?;
    if !value.is_finite() || value <= 0.0 {
        return None;
    }
    Some(value.round() as u32)
}

/// Best-effort SVG dimensions from `viewBox`, then `width`/`height` (a port
/// of `DocumentParser._decodeSvgDimensions`, first 8192 bytes only).
fn decode_svg_dimensions(bytes: &[u8]) -> (u32, u32) {
    const LIMIT: usize = 8192;
    let end = bytes.len().min(LIMIT);
    // `utf8.decode(allowMalformed: true)`: undecodable bytes become U+FFFD.
    let text = String::from_utf8_lossy(&bytes[..end]);

    if let Some(caps) = viewbox_re().captures(&text) {
        let parts: Vec<&str> = caps[1]
            .split(|c: char| c == ',' || c.is_whitespace())
            .filter(|part| !part.is_empty())
            .collect();
        if parts.len() == 4 {
            if let (Some(w), Some(h)) =
                (parse_svg_number(parts[2]), parse_svg_number(parts[3]))
            {
                return (w, h);
            }
        }
    }
    let w = svg_width_re()
        .captures(&text)
        .and_then(|caps| parse_svg_number(&caps[1]));
    let h = svg_height_re()
        .captures(&text)
        .and_then(|caps| parse_svg_number(&caps[1]));
    match (w, h) {
        (Some(w), Some(h)) => (w, h),
        _ => (0, 0),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn natural_order_puts_page2_before_page10() {
        let mut names = vec![
            "page10.png".to_string(),
            "page2.png".to_string(),
            "page1.png".to_string(),
        ];
        names.sort_by(|a, b| natural_compare(a, b));
        assert_eq!(names, vec!["page1.png", "page2.png", "page10.png"]);
    }

    #[test]
    fn filename_stem_strips_dirs_and_extension() {
        assert_eq!(filename_without_extension("pages/page2.png"), "page2");
        assert_eq!(filename_without_extension("page2.png"), "page2");
        assert_eq!(filename_without_extension("noext"), "noext");
    }

    #[test]
    fn svg_dimensions_prefer_view_box() {
        let svg = br#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 300 150" width="300" height="150"></svg>"#;
        assert_eq!(decode_image_dimensions(svg), (300, 150));
    }

    #[test]
    fn jpeg_sof_marker_gives_dimensions() {
        // SOI + APP0 (length 16) + SOF0 8x6.
        let mut jpeg = vec![
            0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, b'J', b'F', b'I', b'F', 0x00, 0x01,
            0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0xFF, 0xC0, 0x00,
            0x0B, 0x08, 0x00, 0x06, 0x00, 0x08, 0x01, 0x01, 0x11, 0x00,
        ];
        assert_eq!(decode_image_dimensions(&jpeg), (8, 6));
        // Truncated SOF with no room for dimensions: unknown, not a panic.
        jpeg.truncate(24);
        assert_eq!(decode_image_dimensions(&jpeg), (0, 0));
    }

    #[test]
    fn webp_vp8x_gives_canvas_size() {
        let mut webp = vec![0u8; 30];
        webp[0..4].copy_from_slice(b"RIFF");
        webp[8..12].copy_from_slice(b"WEBP");
        webp[12..16].copy_from_slice(b"VP8X");
        // width - 1 = 7, height - 1 = 5 (24-bit LE at 24/27).
        webp[24] = 7;
        webp[27] = 5;
        assert_eq!(decode_image_dimensions(&webp), (8, 6));
    }
}
