//! Plain-text (TXT) parsing: decode + chapter split.
//!
//! A direct port of Dart's `DocumentParser._parseTxt` + `chapterizeTxt`
//! (`lib/services/document_parser.dart`): UTF-8 with a Latin-1 fallback when
//! replacement chars dominate, then the same heading-regex / 3-blank-line-run
//! chapter split with the duplicate-heading strip. TXT chapters carry no runs
//! or images, so every offset concern is the body's own text (already UTF-8,
//! sliced only on ASCII boundaries).
//!
//! Two Dart-`RegExp` semantics are reproduced exactly rather than via Rust's
//! defaults (both are pinned by `tests/txt_fixtures.rs`):
//!
//! * **Whitespace** is ECMA-262 `\s` (what Dart implements without the
//!   `unicode` flag): Rust's `char::is_whitespace` plus U+FEFF minus U+0085.
//!   This matters because Dart's `trim()` strips a leading BOM while Rust's
//!   does not — a lone-BOM file is "empty" on both sides.
//! * **`\d`** is ASCII-only (`[0-9]`): Dart's non-unicode `\d` never matches
//!   non-ASCII digits, while the `regex` crate's `\d` would.

use crate::epub::project::ChapterDto;
use crate::epub::units;

use regex::Regex;
use std::collections::BTreeSet;
use std::sync::OnceLock;

/// Maximum TXT size, matching Dart's `100 * 1024 * 1024` guard.
pub const MAX_TXT_BYTES: u64 = 100 * 1024 * 1024;

/// ECMA-262 `\s`: TAB VT FF SP NBSP ZWNBSP LS PS plus every Unicode space
/// separator (Zs). Written out because the `regex` crate's unicode `\s` is
/// wider (it adds NEL) and narrower (it drops ZWNBSP) than Dart's.
const DART_WS_CLASS: &str =concat!(
    r"\t\n\x0B\f\r ",
    r"\u{A0}\u{FEFF}\u{1680}\u{2000}-\u{200A}",
    r"\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}",
);

/// Dart's `RegExp(r'^(?:Chapter|Ch(?:apter)?\.?)\s+\d+|^PART\s+[IVX\d]+',
/// caseSensitive: false, multiLine: true)`.
fn heading_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(&format!(
            "(?im:^(?:Chapter|Ch(?:apter)?\\.?)[{ws}]+[0-9]+|^PART[{ws}]+[IVX0-9]+)",
            ws = DART_WS_CLASS,
        ))
        .expect("heading regex")
    })
}

/// Dart's `RegExp(r'\n\s*\n\s*\n[ \t]*\n*')` (3+ consecutive blank lines).
fn blank_run_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(&format!(
            "\n[{ws}]*\n[{ws}]*\n[ \t]*\n*",
            ws = DART_WS_CLASS,
        ))
        .expect("blank-run regex")
    })
}

/// Dart `RegExp(r'\s+')` / `trim()` whitespace (see the module docs).
fn is_dart_ws(c: char) -> bool {
    c == '\u{FEFF}' || (c.is_whitespace() && c != '\u{0085}')
}

fn trim_dart(s: &str) -> &str {
    s.trim_matches(is_dart_ws)
}

fn trim_end_dart(s: &str) -> &str {
    s.trim_end_matches(is_dart_ws)
}

fn trim_start_dart(s: &str) -> &str {
    s.trim_start_matches(is_dart_ws)
}

/// Decodes TXT bytes: UTF-8 with a Latin-1 fallback when replacement chars
/// dominate (a port of `_parseTxt`'s `allowMalformed` + threshold check).
///
/// Dart compares the replacement count against `text.length` — UTF-16 code
/// units, not chars — so the threshold uses [`units::utf16_len`].
pub fn decode_txt(bytes: &[u8]) -> String {
    let text = String::from_utf8_lossy(bytes).into_owned();
    let replacements = text.chars().filter(|&c| c == '\u{FFFD}').count();
    if replacements as f64 > units::utf16_len(&text) as f64 / 64.0 {
        // `latin1.decode(bytes)`: every byte maps to the same code point.
        return bytes.iter().map(|&b| b as char).collect();
    }
    text
}

/// Parses a TXT file into flat chapters (the `parse_txt` behind the FFI).
pub fn parse_txt(path: &str) -> Result<Vec<ChapterDto>, String> {
    let len = std::fs::metadata(path)
        .map(|meta| meta.len())
        .map_err(|e| format!("Cannot open text file: {e}"))?;
    if len > MAX_TXT_BYTES {
        return Err("Text file too large (limit 100 MB)".to_string());
    }
    let bytes =
        std::fs::read(path).map_err(|e| format!("Cannot open text file: {e}"))?;
    parse_txt_bytes(&bytes)
}

/// In-memory counterpart of [`parse_txt`], for tests.
pub fn parse_txt_bytes(bytes: &[u8]) -> Result<Vec<ChapterDto>, String> {
    let text = decode_txt(bytes);
    if trim_dart(&text).is_empty() {
        return Err("File is empty".to_string());
    }
    Ok(chapterize_txt(&text))
}

/// Splits plain text into chapters (a port of `chapterizeTxt`).
///
/// Split points are heading line-starts and the ends of 3-blank-line runs.
/// Every split point sits on an ASCII boundary (`^` anchors, `\n` scans), so
/// slicing is always on char boundaries.
pub fn chapterize_txt(text: &str) -> Vec<ChapterDto> {
    let heading = heading_re();
    let blank_run = blank_run_re();

    // Merge split points from headings and blank-line runs, sorted.
    let mut split_points = BTreeSet::new();
    for found in heading.find_iter(text) {
        // The start of the line containing the heading.
        let mut line_start = found.start();
        let bytes = text.as_bytes();
        while line_start > 0 && bytes[line_start - 1] != b'\n' {
            line_start -= 1;
        }
        split_points.insert(line_start);
    }
    for found in blank_run.find_iter(text) {
        // Split after the blank run (at the first non-blank content).
        let after_blank = found.end();
        if after_blank < text.len() {
            split_points.insert(after_blank);
        }
    }

    // If no splits found, return single chapter (untrimmed, like Dart).
    if split_points.is_empty() {
        return vec![single_chapter(text)];
    }

    let mut chapters = Vec::new();
    let mut start = 0;
    for &split_at in &split_points {
        if split_at <= start {
            continue;
        }
        let chunk = trim_end_dart(&text[start..split_at]);
        if !trim_dart(chunk).is_empty() {
            chapters.push(ChapterDto {
                title: chapter_title(chunk),
                body: chunk.to_string(),
                ..Default::default()
            });
        }
        start = split_at;
    }

    // Final chunk after last split point.
    if start < text.len() {
        let chunk = trim_dart(&text[start..]);
        if !chunk.is_empty() {
            chapters.push(ChapterDto {
                title: chapter_title(chunk),
                body: chunk.to_string(),
                ..Default::default()
            });
        }
    }

    if chapters.is_empty() {
        return vec![single_chapter(text)];
    }
    chapters.into_iter().map(strip_duplicate_heading).collect()
}

fn single_chapter(text: &str) -> ChapterDto {
    ChapterDto {
        title: String::new(),
        body: text.to_string(),
        ..Default::default()
    }
}

/// The chunk's title: its first line when that line is itself a heading.
fn chapter_title(chunk: &str) -> String {
    let end = chunk.find('\n').unwrap_or(chunk.len());
    let first_line = trim_dart(&chunk[..end]);
    // Dart's `headingRe.hasMatch(firstLine)` is an unanchored search, but the
    // pattern is `^`-anchored (multiline), so only a line start can match.
    if heading_re().is_match(first_line) {
        first_line.to_string()
    } else {
        String::new()
    }
}

/// Drops a leading body line that merely repeats the chapter title (a port of
/// Dart's `_stripDuplicateHeading`). TXT chapters carry no runs or images, so
/// only the body is rebased.
fn strip_duplicate_heading(ch: ChapterDto) -> ChapterDto {
    let title = normalize_heading(&ch.title);
    if title.is_empty() {
        return ch;
    }
    let Some(nl) = ch.body.find('\n') else {
        return ch;
    };
    if normalize_heading(&ch.body[..nl]) != title {
        return ch;
    }
    let rest = trim_start_dart(&ch.body[nl + 1..]);
    if rest.is_empty() {
        return ch;
    }
    ChapterDto {
        title: ch.title,
        body: rest.to_string(),
        ..Default::default()
    }
}

/// Dart's `_normalizeHeading`: collapse whitespace runs, trim, lowercase.
fn normalize_heading(s: &str) -> String {
    s.split(is_dart_ws)
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn titles_of(text: &str) -> Vec<String> {
        chapterize_txt(text)
            .into_iter()
            .map(|c| c.title)
            .collect()
    }

    #[test]
    fn splits_on_explicit_chapter_headings() {
        let text = "Chapter 1: The Beginning\nOnce upon a time...\n\n\
            Chapter 2: The Middle\nSomething happened...\n\n\
            Chapter 3: The End\nIt was over.";
        let chapters = chapterize_txt(text);
        assert_eq!(
            titles_of(text),
            vec![
                "Chapter 1: The Beginning",
                "Chapter 2: The Middle",
                "Chapter 3: The End"
            ]
        );
        assert_eq!(chapters[0].body, "Once upon a time...");
    }

    #[test]
    fn single_blank_lines_do_not_split() {
        let text = "First section with some text here.\n\nSecond section.";
        assert_eq!(chapterize_txt(text).len(), 1);
    }

    #[test]
    fn splits_on_three_blank_lines() {
        let text = "First section.\n\n\n\nSecond section.\n\n\n\nThird section.";
        let chapters = chapterize_txt(text);
        assert_eq!(chapters.len(), 3);
        assert!(chapters.iter().all(|c| c.title.is_empty()));
    }

    #[test]
    fn splits_on_part_headings_case_insensitively() {
        let text = "PART I\nBeginning.\n\nPART II\nMiddle.\n\nchapter 3 tail\nEnd.";
        assert_eq!(titles_of(text), vec!["PART I", "PART II", "chapter 3 tail"]);
    }

    #[test]
    fn heading_in_the_middle_of_a_line_does_not_split() {
        let text = "This chapter talks about Chapter 5 of the other book.\nMore text.";
        assert_eq!(chapterize_txt(text).len(), 1);
    }

    #[test]
    fn ch_abbreviation_splits() {
        let text = "Ch. 1 First\nSome text.\n\nCh. 2 Second\nMore text.";
        assert_eq!(titles_of(text), vec!["Ch. 1 First", "Ch. 2 Second"]);
    }

    #[test]
    fn short_text_is_a_single_untitled_chapter() {
        let chapters = chapterize_txt("Just a short paragraph.");
        assert_eq!(chapters.len(), 1);
        assert_eq!(chapters[0].title, "");
        assert_eq!(chapters[0].body, "Just a short paragraph.");
    }

    #[test]
    fn duplicate_heading_line_is_stripped_from_the_body() {
        let chapters = chapterize_txt("Chapter 1\n\nBody text here");
        assert_eq!(chapters.len(), 1);
        assert_eq!(chapters[0].title, "Chapter 1");
        assert_eq!(chapters[0].body, "Body text here");
    }

    #[test]
    fn latin1_fallback_needs_dominant_replacements() {
        // Two bad bytes in a short string: the fallback fires.
        assert_eq!(decode_txt(b"Caf\xe9 cr\xe8me"), "Café crème");
        // One bad byte in a long string: the lossy UTF-8 decode stands.
        let mut bytes = vec![b'a'; 70];
        bytes.push(0xFF);
        assert_eq!(decode_txt(&bytes), format!("{}\u{FFFD}", "a".repeat(70)));
    }

    #[test]
    fn lone_bom_trims_to_empty() {
        assert!(trim_dart("\u{FEFF}").is_empty());
    }
}
