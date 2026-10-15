import 'dart:convert';
import 'dart:typed_data';

/// Comic/zip archive helpers shared by the reader and the metadata paths.
///
/// Moved verbatim out of the retired Dart parser (`_isImage`,
/// `_naturalCompare`, `_RichTextBuilder._decodeImageDimensions` and its SVG
/// helpers) so callers no longer depend on the Dart parse engine.
/// Pure Dart.

const _imageExtensions = {
  '.jpg',
  '.jpeg',
  '.png',
  '.gif',
  '.webp',
  '.bmp',
};

/// True when [name] ends in a known comic image extension.
bool isImageEntry(String name) {
  final lower = name.toLowerCase();
  for (final ext in _imageExtensions) {
    if (lower.endsWith(ext)) return true;
  }
  return false;
}

/// Natural sort comparator for filenames ("2.jpg" before "10.jpg").
int naturalCompare(String a, String b) {
  return _naturalCompareImpl(a.toLowerCase(), b.toLowerCase());
}

int _naturalCompareImpl(String a, String b) {
  final aRunes = a.runes.toList();
  final bRunes = b.runes.toList();
  var ia = 0;
  var ib = 0;
  while (ia < aRunes.length && ib < bRunes.length) {
    final ca = aRunes[ia];
    final cb = bRunes[ib];
    if (ca >= 0x30 && ca <= 0x39 && cb >= 0x30 && cb <= 0x39) {
      // Both digits: compare numeric run.
      var numA = 0;
      var numB = 0;
      while (ia < aRunes.length && aRunes[ia] >= 0x30 && aRunes[ia] <= 0x39) {
        numA = numA * 10 + (aRunes[ia] - 0x30);
        ia++;
      }
      while (ib < bRunes.length && bRunes[ib] >= 0x30 && bRunes[ib] <= 0x39) {
        numB = numB * 10 + (bRunes[ib] - 0x30);
        ib++;
      }
      if (numA != numB) return numA.compareTo(numB);
    } else {
      if (ca != cb) return ca.compareTo(cb);
      ia++;
      ib++;
    }
  }
  return aRunes.length.compareTo(bRunes.length);
}

/// Reads width/height from common image headers (PNG/JPEG/GIF/BMP/WebP/SVG).
/// Falls back to 0×0 on failure, which callers treat as "unknown".
(int, int) decodeImageDimensions(Uint8List bytes) {
  if (bytes.length >= 24 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    // PNG: width at offset 16, height at offset 20 (big-endian uint32).
    final w =
        (bytes[16] << 24 | bytes[17] << 16 | bytes[18] << 8 | bytes[19]);
    final h =
        (bytes[20] << 24 | bytes[21] << 16 | bytes[22] << 8 | bytes[23]);
    return (w, h);
  }
  if (bytes.length >= 10 &&
      bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46) {
    // GIF: logical screen width/height, little-endian uint16 at 6/8.
    return (bytes[6] | (bytes[7] << 8), bytes[8] | (bytes[9] << 8));
  }
  if (bytes.length >= 26 && bytes[0] == 0x42 && bytes[1] == 0x4D) {
    // BMP: int32 LE width at 18, height at 22 (may be negative top-down).
    final w =
        bytes[18] | (bytes[19] << 8) | (bytes[20] << 16) | (bytes[21] << 24);
    final h =
        bytes[22] | (bytes[23] << 8) | (bytes[24] << 16) | (bytes[25] << 24);
    return (w.abs(), h.abs());
  }
  if (bytes.length >= 30 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    // WebP: RIFF container; parse the first chunk's canvas size.
    final fourcc = String.fromCharCodes(bytes.sublist(12, 16));
    if (fourcc == 'VP8X') {
      final w = 1 + (bytes[24] | (bytes[25] << 8) | (bytes[26] << 16));
      final h = 1 + (bytes[27] | (bytes[28] << 8) | (bytes[29] << 16));
      return (w, h);
    }
    if (fourcc == 'VP8L' && bytes.length >= 25) {
      final b0 = bytes[21], b1 = bytes[22], b2 = bytes[23], b3 = bytes[24];
      final w = 1 + (((b1 & 0x3F) << 8) | b0);
      final h = 1 + (((b3 & 0x0F) << 10) | (b2 << 2) | ((b1 & 0xC0) >> 6));
      return (w, h);
    }
    if (fourcc == 'VP8 ' && bytes.length >= 30) {
      final w = (bytes[26] | (bytes[27] << 8)) & 0x3FFF;
      final h = (bytes[28] | (bytes[29] << 8)) & 0x3FFF;
      return (w, h);
    }
  }
  if (_looksLikeSvg(bytes)) {
    final (w, h) = _decodeSvgDimensions(bytes);
    if (w > 0 && h > 0) return (w, h);
  }
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8) {
    // JPEG: scan for SOF0–SOF15 marker (0xFFC0–0xFFCF).
    var i = 2;
    while (i + 9 < bytes.length) {
      if (bytes[i] != 0xFF) {
        i++;
        continue;
      }
      final marker = bytes[i + 1];
      if (marker >= 0xC0 &&
          marker <= 0xCF &&
          marker != 0xC4 &&
          marker != 0xC8 &&
          marker != 0xCC) {
        final h = (bytes[i + 5] << 8) | bytes[i + 6];
        final w = (bytes[i + 7] << 8) | bytes[i + 8];
        return (w, h);
      }
      final len = (bytes[i + 2] << 8) | bytes[i + 3];
      i += 2 + len;
    }
  }
  return (0, 0);
}

/// True when the bytes open as XML/SVG (ignoring a UTF-8 BOM and whitespace).
bool _looksLikeSvg(Uint8List bytes) {
  for (var i = 0; i < bytes.length && i < 64; i++) {
    final b = bytes[i];
    if (b == 0x3C) return true; // '<'
    if (b != 0x20 &&
        b != 0x09 &&
        b != 0x0A &&
        b != 0x0D &&
        b != 0xEF &&
        b != 0xBB &&
        b != 0xBF) {
      return false;
    }
  }
  return false;
}

/// Best-effort SVG dimensions from `viewBox`, then `width`/`height`.
(int, int) _decodeSvgDimensions(Uint8List bytes) {
  const limit = 8192;
  final slice = bytes.length > limit ? bytes.sublist(0, limit) : bytes;
  final text = utf8.decode(slice, allowMalformed: true);

  final viewBox = RegExp(
    r'''viewBox\s*=\s*["']([^"']+)["']''',
  ).firstMatch(text);
  if (viewBox != null) {
    final parts = viewBox.group(1)!.trim().split(RegExp(r'[\s,]+'));
    if (parts.length == 4) {
      final w = double.tryParse(parts[2]);
      final h = double.tryParse(parts[3]);
      if (w != null && h != null && w > 0 && h > 0) {
        return (w.round(), h.round());
      }
    }
  }
  final wm = RegExp(r'''\bwidth\s*=\s*["']([\d.]+)''').firstMatch(text);
  final hm = RegExp(r'''\bheight\s*=\s*["']([\d.]+)''').firstMatch(text);
  final w = wm == null ? null : double.tryParse(wm.group(1)!);
  final h = hm == null ? null : double.tryParse(hm.group(1)!);
  if (w != null && h != null && w > 0 && h > 0) {
    return (w.round(), h.round());
  }
  return (0, 0);
}
