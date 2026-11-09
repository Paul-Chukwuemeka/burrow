import 'dart:convert';

/// One rectangle of a PDF highlight, in PDF page coordinates.
///
/// Matches pdfrx's `PdfRect` convention: [top] is greater than [bottom].
class PdfHighlightRect {
  const PdfHighlightRect({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final double left;
  final double top;
  final double right;
  final double bottom;

  @override
  bool operator ==(Object other) =>
      other is PdfHighlightRect &&
      other.left == left &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);
}

/// The rectangles one highlight occupies on a single PDF page.
class PdfHighlightSegment {
  const PdfHighlightSegment({required this.page, required this.rects});

  /// 1-based page number.
  final int page;
  final List<PdfHighlightRect> rects;

  @override
  bool operator ==(Object other) =>
      other is PdfHighlightSegment &&
      other.page == page &&
      _rectListsEqual(other.rects, rects);

  @override
  int get hashCode => Object.hash(page, Object.hashAll(rects));
}

bool _rectListsEqual(List<PdfHighlightRect> a, List<PdfHighlightRect> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Serializes segments as `[{"page": int, "rects": [[l,t,r,b], ...]}]`.
String encodePdfSegments(List<PdfHighlightSegment> segments) => jsonEncode([
  for (final segment in segments)
    {
      'page': segment.page,
      'rects': [
        for (final rect in segment.rects)
          [rect.left, rect.top, rect.right, rect.bottom],
      ],
    },
]);

/// Decodes segments, skipping malformed entries instead of throwing.
List<PdfHighlightSegment> decodePdfSegments(String? json) {
  if (json == null || json.isEmpty) return [];

  Object? raw;
  try {
    raw = jsonDecode(json);
  } on FormatException {
    return [];
  }
  if (raw is! List) return [];

  final segments = <PdfHighlightSegment>[];
  for (final entry in raw) {
    if (entry is! Map) continue;
    final page = entry['page'];
    final rects = entry['rects'];
    if (page is! int || rects is! List) continue;

    final decodedRects = <PdfHighlightRect>[];
    for (final rect in rects) {
      if (rect is! List || rect.length != 4) continue;
      final left = rect[0];
      final top = rect[1];
      final right = rect[2];
      final bottom = rect[3];
      if (left is! num || top is! num || right is! num || bottom is! num) {
        continue;
      }
      decodedRects.add(
        PdfHighlightRect(
          left: left.toDouble(),
          top: top.toDouble(),
          right: right.toDouble(),
          bottom: bottom.toDouble(),
        ),
      );
    }
    segments.add(PdfHighlightSegment(page: page, rects: decodedRects));
  }
  return segments;
}

/// Rectangles for one page, or an empty list when the page has none.
List<PdfHighlightRect> pdfRectsForPage(String? json, int page) {
  for (final segment in decodePdfSegments(json)) {
    if (segment.page == page) return segment.rects;
  }
  return const [];
}
