//! Filename-derived titles and comic series inference.
//!
//! A direct port of `cleanBookTitle` (`lib/utils/book_title.dart`),
//! `DocumentParser._titleFromFilename` and `parseComicSeries`
//! (`lib/utils/comic_series.dart`): non-EPUB formats carry no embedded
//! metadata, so both engines derive the title (and, for comics, the series)
//! from the file name. The metadata FFI (`extract_metadata_txt/cbz/cbr/pdf`)
//! computes these here so the Rust and Dart engines agree field by field.
//!
//! Two Dart-`RegExp` semantics are reproduced exactly rather than via Rust's
//! defaults (both are ASCII-only without the `unicode` flag):
//!
//! * **`\s`** is ECMA-262 whitespace (the same class `txt` pins as
//!   `DART_WS_CLASS`): Rust's unicode `\s` would additionally match NEL and
//!   miss ZWNBSP.
//! * **`\d`/`\w`/`\b`/case-folding** are ASCII-only: every pattern below is
//!   compiled with `(?-u)` (keeping `(?i)` for ASCII case-insensitivity), so
//!   `\d` never matches non-ASCII digits and `\b` never treats `é` as a word
//!   char the way unicode mode would.

use std::sync::OnceLock;

use regex::Regex;

use super::units;

/// ECMA-262 `\s`, shared with [`crate::epub::txt`] (see its module docs).
const WS: &str = concat!(
    r"\t\n\x0B\f\r ",
    r"\u{A0}\u{FEFF}\u{1680}\u{2000}-\u{200A}",
    r"\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}",
);

/// Dart `String.trim()`: ASCII whitespace plus the ECMA extras above.
///
/// `str::trim` would also strip NEL (U+0085), which Dart's trim keeps.
fn is_dart_ws(c: char) -> bool {
    c == '\u{FEFF}' || (c.is_whitespace() && c != '\u{0085}')
}

fn trim_dart(s: &str) -> &str {
    s.trim_matches(is_dart_ws)
}

/// The file name component of `path`, mirroring Dart's
/// `path.split(Platform.pathSeparator).last`.
///
/// `std::path::Path::file_name` splits on the platform separator, which is
/// exactly what Dart's `Platform.pathSeparator` split does on each platform.
fn file_name(path: &str) -> String {
    std::path::Path::new(path)
        .file_name()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_default()
}

/// Cleans a raw filename-derived title (a port of `cleanBookTitle`).
pub fn clean_book_title(raw: &str) -> String {
    let mut s = trim_dart(raw).to_string();
    if s.is_empty() {
        return s;
    }

    // Strip the extension when a full filename was passed in.
    if let Some(dot) = s.rfind('.') {
        if dot > 0 && is_known_extension(&s[dot + 1..]) {
            s.truncate(dot);
        }
    }

    s = site_noise_re().replace_all(&s, " ").into_owned();
    s = format_tag_re().replace_all(&s, " ").into_owned();
    s = underscore_re().replace_all(&s, " ").into_owned();

    // Drop a "by John A. Doe" author tail, mirroring Dart's guard: only when
    // enough title remains (`start >= 6` UTF-16 units) and the tail looks like
    // a real author credit (>= 2 name tokens, or filename-cruft signals).
    if let Some(m) = by_suffix_re().find(&s) {
        if units::utf16_len(&s[..m.start()]) >= 6 {
            let tail = by_prefix_re().replace(&s[m.start()..], "").to_string();
            let tail = trim_dart(&tail);
            let tokens = if tail.is_empty() {
                0
            } else {
                ws_run_re().split(tail).count()
            };
            let had_cruft = underscore_re().is_match(raw)
                || site_noise_re().is_match(raw)
                || format_tag_re().is_match(raw);
            if tokens >= 2 || had_cruft {
                s.truncate(m.start());
            }
        }
    }

    s = lead_glue_re().replace(&s, "").into_owned();
    s = glue_re().replace(&s, "").into_owned();
    s = space_run_re().replace_all(&s, " ").into_owned();
    s = trim_dart(&s).to_string();
    s = edge_punct_re().replace_all(&s, "").into_owned();

    // All-caps scraped titles are unreadable; sentence-case them.
    if units::utf16_len(&s) > 3 && s.to_uppercase() == s && caps_run_re().is_match(&s) {
        let mut chars = s.chars();
        if let Some(first) = chars.next() {
            let rest: String = chars.collect();
            return format!("{first}{}", rest.to_lowercase());
        }
    }
    s
}

/// The filename-derived title, matching `DocumentParser._titleFromFilename`.
pub fn title_from_filename(path: &str) -> String {
    let base = file_name(path);
    let stem = match base.rfind('.') {
        Some(dot) if dot > 0 => &base[..dot],
        _ => base.as_str(),
    };
    clean_book_title(stem)
}

/// Infers a comic series name and issue index from `path` (a port of
/// `parseComicSeries`).
pub fn parse_comic_series(path: &str) -> (Option<String>, Option<f64>) {
    let mut base = file_name(path);
    if let Some(dot) = base.rfind('.') {
        if dot > 0 {
            base.truncate(dot);
        }
    }
    if base.is_empty() {
        return (None, None);
    }

    base = leading_tag_re().replacen(&base, 1, "").into_owned();
    base = base.replace('_', " ");
    base = trim_dart(&base).to_string();
    base = strip_trailing_tags(&base);
    if base.is_empty() {
        return (None, None);
    }

    if let Some(caps) = issue_keyword_re().captures(&base) {
        let name = clean_series_name(&caps[1]);
        if name.is_some() {
            return (name, caps[2].parse::<f64>().ok());
        }
    }
    if let Some(caps) = trailing_number_re().captures(&base) {
        let name = clean_series_name(&caps[1]);
        if name.is_some() {
            return (name, caps[2].parse::<f64>().ok());
        }
    }
    if let Some(caps) = glued_number_re().captures(&base) {
        let name = clean_series_name(&caps[1]);
        if name.is_some() {
            return (name, caps[2].parse::<f64>().ok());
        }
    }
    (None, None)
}

fn strip_trailing_tags(s: &str) -> String {
    let mut result = s.to_string();
    loop {
        let next = trim_dart(&trailing_tag_re().replacen(&result, 1, "").into_owned()).to_string();
        if next == result {
            break;
        }
        result = next;
    }
    result
}

fn clean_series_name(raw: &str) -> Option<String> {
    let stripped = trailing_sep_re().replace(raw, "").into_owned();
    let name = clean_book_title(trim_dart(&stripped));
    if name.is_empty() {
        None
    } else {
        Some(name)
    }
}

fn is_known_extension(ext: &str) -> bool {
    matches!(
        ext.to_ascii_lowercase().as_str(),
        "epub" | "pdf" | "txt" | "mobi" | "azw" | "azw3" | "rtf" | "doc" | "docx"
    )
}

fn site_noise_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(
            r"(?i:oceanofpdf\.com|oceanofpdf|z-lib\.org|z-library|libgen\.li|libgen\.is|libgen\.rs|pdfroom\.com|annas-archive\.org|annas-archive|ebookhunter\.net|vk\.com)",
        )
        .expect("site noise regex")
    })
}

fn format_tag_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(&format!(
            r"(?i:[\[\({{][{ws}]*[^]\)\}}]*(?:pdf|epub|mobi|azw|rtf|lit)[^]\)\}}]*[\]\)\}}])",
            ws = WS,
        ))
        .expect("format tag regex")
    })
}

fn underscore_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"[_＿]+").expect("underscore regex"))
}

fn by_suffix_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(&format!(
            r"(?i:[{ws}]+by[{ws}]+(?:[A-Z][A-Za-z0-9_.'\-]*[{ws}]+){{0,4}}[A-Z][A-Za-z0-9_.'\-]*\.?[{ws}]*$)",
            ws = WS,
        ))
        .expect("by-suffix regex")
    })
}

fn by_prefix_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(&format!(r"(?i:^[{ws}]+by[{ws}]+)", ws = WS)).expect("by-prefix regex")
    })
}

fn lead_glue_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(&format!(
            r"^[{ws}]*[-\u{{2013}}\u{{2014}}:|]+[{ws}]*",
            ws = WS
        ))
        .expect("lead glue regex")
    })
}

fn glue_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(&format!(
            r"[{ws}]*[-\u{{2013}}\u{{2014}}:|]+[{ws}]*$",
            ws = WS
        ))
        .expect("glue regex")
    })
}

fn space_run_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(&format!(r"[{ws}]{{2,}}", ws = WS)).expect("space run regex"))
}

fn ws_run_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(&format!(r"[{ws}]+", ws = WS)).expect("whitespace regex"))
}

fn edge_punct_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        // Dart's `[\W_]` without the unicode flag: anything but ASCII word chars.
        Regex::new(r"^[^A-Za-z0-9]+|[^A-Za-z0-9]+$").expect("edge punct regex")
    })
}

fn caps_run_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"[A-Z]{4}").expect("caps run regex"))
}

fn trailing_tag_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(&format!(
            r"[{ws}]*[\(\[][{ws}]*[^\)\]]*[{ws}]*[\)\]][{ws}]*$",
            ws = WS,
        ))
        .expect("trailing tag regex")
    })
}

fn leading_tag_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(&format!(r"^[{ws}]*[\[\(][^\]\)]*[\]\)][{ws}]*", ws = WS))
            .expect("leading tag regex")
    })
}

fn issue_keyword_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(&format!(
            r"(?i:^(.*?)[{ws}\-\u{{2013}}\u{{2014}}:]*(?:#|issue|iss|chapter|ch|no|number|nr|part|pt)[{ws}]*\.?[{ws}]*([0-9]+(?:\.[0-9]+)?)(?:[^0-9A-Za-z_]|$))",
            ws = WS,
        ))
        .expect("issue keyword regex")
    })
}

fn trailing_number_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(&format!(
            r"(?i:^(.*?)[{ws}\-\u{{2013}}\u{{2014}}:]+([0-9]{{1,4}}(?:\.[0-9]+)?)[{ws}]*$)",
            ws = WS,
        ))
        .expect("trailing number regex")
    })
}

fn glued_number_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(&format!(
            r"(?i:^(.*?[A-Za-z])([0-9]{{1,4}})[{ws}]*$)",
            ws = WS,
        ))
        .expect("glued number regex")
    })
}

fn trailing_sep_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(&format!(r"[{ws}\-\u{{2013}}\u{{2014}}:]+$", ws = WS))
            .expect("trailing separator regex")
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn title_strips_extension_and_underscores() {
        assert_eq!(title_from_filename("/books/notes.txt"), "notes");
        assert_eq!(
            title_from_filename("/books/The_Forever_Hero.pdf"),
            "The Forever Hero"
        );
    }

    #[test]
    fn title_drops_site_noise_and_author_tail() {
        assert_eq!(
            clean_book_title("_OceanofPDF.com_The_Forever_Hero_by_John_Doe"),
            "The Forever Hero"
        );
    }

    #[test]
    fn title_sentence_cases_all_caps() {
        assert_eq!(clean_book_title("THE FOREVER HERO"), "The forever hero");
    }

    #[test]
    fn series_keyword_forms() {
        assert_eq!(
            parse_comic_series("/c/Batman 001 (2016).cbz"),
            (Some("Batman".to_string()), Some(1.0))
        );
        assert_eq!(
            parse_comic_series("/c/Saga #054.cbz"),
            (Some("Saga".to_string()), Some(54.0))
        );
        assert_eq!(
            parse_comic_series("/c/[Group] Invincible 012.cbz"),
            (Some("Invincible".to_string()), Some(12.0))
        );
    }

    #[test]
    fn series_plain_name_has_no_series() {
        assert_eq!(parse_comic_series("/c/mini.cbz"), (None, None));
    }

    #[test]
    fn series_trailing_and_glued_numbers() {
        assert_eq!(
            parse_comic_series("/c/The Walking Dead - 100.cbz"),
            (Some("The Walking Dead".to_string()), Some(100.0))
        );
        assert_eq!(
            parse_comic_series("/c/Batman001.cbz"),
            (Some("Batman".to_string()), Some(1.0))
        );
    }
}
