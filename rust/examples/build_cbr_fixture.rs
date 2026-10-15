//! Writes the committed `test/fixtures/epub/mini.cbr` synthetic CBR fixture.
//!
//! RAR encoding is proprietary: no local RAR encoder exists (`7z` only
//! reads), so the fixture is authored with `rars`' own writer
//! (self-round-trip) rather than by `test/fixtures/epub/generate.py`, which
//! only writes ZIPs. Pages mirror `mini.cbz` (Task 2): three PNGs with
//! distinct intrinsic sizes archived out of order (`page10` first) plus a
//! `notes.txt` the image filter must drop, so only a natural sort yields
//! `page1, page2, page10`.
//!
//! Run from the repo root:
//!
//! ```sh
//! cargo run -p rust_lib_burrow --example build_cbr_fixture
//! ```
//!
//! Output must be byte-for-byte deterministic: members are stored
//! uncompressed with no timestamps, so the checked-in `.cbr` only changes
//! when the content (or the `rars` encoder) does.

use std::path::PathBuf;

fn chunk(tag: &[u8; 4], data: &[u8]) -> Vec<u8> {
    // Minimal CRC-free PNG writer: the real encoder is `rars`, and our own
    // header sniffer only reads the IHDR. zlib crc32 without a dependency:
    // a tiny table-driven implementation is overkill here — reuse the
    // adler-free approach of writing correct lengths with zeroed CRCs would
    // produce an invalid PNG. Instead compute CRC32 with a compact
    // implementation below.
    let mut out = Vec::new();
    out.extend_from_slice(&(data.len() as u32).to_be_bytes());
    out.extend_from_slice(tag);
    out.extend_from_slice(data);
    out.extend_from_slice(&crc32(&[tag.as_slice(), data].concat()).to_be_bytes());
    out
}

fn crc32(data: &[u8]) -> u32 {
    let mut crc = 0xFFFF_FFFFu32;
    for &b in data {
        crc ^= b as u32;
        for _ in 0..8 {
            let mask = crc & 1;
            crc >>= 1;
            if mask != 0 {
                crc ^= 0xEDB8_8320;
            }
        }
    }
    !crc
}

fn png(width: u32, height: u32, rgb: (u8, u8, u8)) -> Vec<u8> {
    // Minimal valid RGB PNG, mirroring `generate.py::_png` (deflate via the
    // `flate2` dependency already in the tree would add a dev-dependency;
    // store raw scanlines with compression method 8 requires valid zlib
    // data — so implement a stored (uncompressed) zlib stream manually).
    let mut raw = Vec::new();
    for _ in 0..height {
        raw.extend_from_slice(&[0]);
        for _ in 0..width {
            raw.extend_from_slice(&[rgb.0, rgb.1, rgb.2]);
        }
    }
    let stored = zlib_store(&raw);
    let mut ihdr = Vec::new();
    ihdr.extend_from_slice(&width.to_be_bytes());
    ihdr.extend_from_slice(&height.to_be_bytes());
    ihdr.extend_from_slice(&[8, 2, 0, 0, 0]);
    let mut out = b"\x89PNG\r\n\x1a\n".to_vec();
    out.extend_from_slice(&chunk(b"IHDR", &ihdr));
    out.extend_from_slice(&chunk(b"IDAT", &stored));
    out.extend_from_slice(&chunk(b"IEND", &[]));
    out
}

/// A zlib stream using only stored (uncompressed) blocks.
fn zlib_store(raw: &[u8]) -> Vec<u8> {
    let mut out = vec![0x78, 0x01]; // zlib header (deflate, default window)
    let mut at = 0;
    while at < raw.len() {
        let end = (at + 65535).min(raw.len());
        let piece = &raw[at..end];
        let final_block = end == raw.len();
        out.push(if final_block { 0x01 } else { 0x00 });
        out.extend_from_slice(&(piece.len() as u16).to_le_bytes());
        out.extend_from_slice(&(!piece.len() as u16).to_le_bytes());
        out.extend_from_slice(piece);
        at = end;
    }
    let adler = adler32(raw);
    out.extend_from_slice(&adler.to_be_bytes());
    out
}

fn adler32(data: &[u8]) -> u32 {
    let mut a = 1u32;
    let mut b = 0u32;
    for &byte in data {
        a = (a + byte as u32) % 65521;
        b = (b + a) % 65521;
    }
    (b << 16) | a
}

fn main() {
    let here = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let dest = here.join("../test/fixtures/epub/mini.cbr");
    let mut builder = rars::Builder::new(rars::ArchiveVersion::Rar50);
    // Stored (no compression) and no timestamps: deterministic bytes.
    builder = builder.store(true);
    let members: &[(&str, Vec<u8>)] = &[
        ("page10.png", png(6, 8, (30, 30, 200))),
        ("notes.txt", b"Not a page.\n".to_vec()),
        ("page2.png", png(8, 6, (30, 120, 30))),
        ("page1.png", png(4, 4, (200, 30, 30))),
    ];
    for (name, data) in members {
        builder
            .add_bytes(name.as_bytes().to_vec(), data.clone(), None, None)
            .expect("queue member");
    }
    let bytes = builder.to_bytes().expect("encode RAR");
    std::fs::write(&dest, &bytes).expect("write mini.cbr");
    println!("wrote {} ({} bytes)", dest.display(), bytes.len());
}
