//! UTF-16 offset conversion for the flat-run projection.
//!
//! The block tree stores its text ranges in Dart UTF-16 code units (Task 5,
//! spec D4), but the projection builds its `body` as a Rust `String` and records
//! run/image offsets as **byte** offsets while it grows (that keeps the hot loop
//! allocation-free). Converting those to UTF-16 once, after the body is final,
//! puts every code-unit decision in one place.
//!
//! This matters because a `\u{1F600}` is four UTF-8 bytes but *two* UTF-16 code
//! units: a byte-offset emission shifts every following run and image offset
//! (Review Focus #1).

/// UTF-16 code-unit offset of every byte position in `s`.
///
/// The returned vector has `s.len() + 1` entries; entry `i` is the number of
/// UTF-16 code units before byte `i`. Bytes inside a multi-byte scalar report
/// the offset of that scalar's start (they are not valid slice points, so
/// callers never index them).
pub fn utf16_offsets(s: &str) -> Vec<u32> {
    let mut offsets = vec![0u32; s.len() + 1];
    let mut units = 0u32;
    for (index, ch) in s.char_indices() {
        for entry in &mut offsets[index..index + ch.len_utf8()] {
            *entry = units;
        }
        units += ch.len_utf16() as u32;
    }
    if let Some(last) = offsets.last_mut() {
        *last = units;
    }
    offsets
}

/// Number of UTF-16 code units in `s`.
pub fn utf16_len(s: &str) -> u32 {
    s.chars().map(|c| c.len_utf16() as u32).sum()
}

/// Converts a byte offset in `s` to a UTF-16 code-unit offset.
///
/// A byte inside a multi-byte scalar counts only the scalars that end at or
/// before it, matching [`utf16_offsets`].
pub fn byte_to_utf16(s: &str, byte: usize) -> u32 {
    let byte = byte.min(s.len());
    let mut units = 0u32;
    for (index, ch) in s.char_indices() {
        if index + ch.len_utf8() > byte {
            break;
        }
        units += ch.len_utf16() as u32;
    }
    units
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn counts_a_non_bmp_char_as_two_utf16_units() {
        // "A" (1) + U+1F600 (2) + "B" (1) = 4 UTF-16 units.
        assert_eq!(utf16_len("A\u{1F600}B"), 4);
        assert_eq!(utf16_len("tail"), 4);
    }

    #[test]
    fn offsets_map_every_char_boundary() {
        let s = "A\u{1F600}B";
        let offsets = utf16_offsets(s);
        assert_eq!(offsets.len(), s.len() + 1);
        // byte 0 -> 0, byte 1 (after "A") -> 1, byte 5 (after the emoji) -> 3,
        // byte 6 (end) -> 4. The emoji is four bytes but two units.
        assert_eq!(offsets[0], 0);
        assert_eq!(offsets[1], 1);
        assert_eq!(offsets[5], 3);
        assert_eq!(offsets[6], 4);
        // Slicing the emoji yields its two UTF-16 units.
        assert_eq!(offsets[5] - offsets[1], 2);
    }

    #[test]
    fn byte_to_utf16_agrees_with_the_map() {
        let s = "A\u{1F600}B";
        for byte in 0..=s.len() {
            assert_eq!(byte_to_utf16(s, byte), utf16_offsets(s)[byte]);
        }
    }
}
