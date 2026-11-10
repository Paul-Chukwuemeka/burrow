//! Recon-only helper: dump each chapter's projected body as JSON lines.
//!
//! Usage: cargo run --example dump_text -- <book.epub>

use rust_lib_burrow::api::epub::{chapter, chapter_count, open_epub};

fn main() {
    let path = match std::env::args().nth(1) {
        Some(p) => p,
        None => {
            eprintln!("usage: dump_text <book.epub>");
            std::process::exit(2);
        }
    };
    let handle = open_epub(path).expect("open_epub");
    let count = chapter_count(&handle).expect("chapter_count");
    for index in 0..count {
        let dto = chapter(&handle, index).expect("chapter");
        println!(
            "{}\u{1f}{}\u{1f}{}",
            index,
            serde_json_escape(&dto.title),
            serde_json_escape(&dto.body)
        );
    }
}

fn serde_json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    for ch in s.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}
