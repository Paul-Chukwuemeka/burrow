import 'package:burrow/utils/pdf_highlight_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const segments = [
    PdfHighlightSegment(
      page: 12,
      rects: [
        PdfHighlightRect(left: 74.1, top: 700.2, right: 412.8, bottom: 688.0),
        PdfHighlightRect(left: 74.1, top: 686.1, right: 300.4, bottom: 673.9),
      ],
    ),
    PdfHighlightSegment(
      page: 13,
      rects: [PdfHighlightRect(left: 10, top: 20, right: 30, bottom: 10)],
    ),
  ];

  test('round-trips segments in order', () {
    final decoded = decodePdfSegments(encodePdfSegments(segments));
    expect(decoded, segments);
  });

  test('keeps top greater than bottom', () {
    final decoded = decodePdfSegments(encodePdfSegments(segments));
    expect(decoded.first.rects.first.top, 700.2);
    expect(decoded.first.rects.first.bottom, 688.0);
  });

  test('invalid JSON returns an empty list', () {
    expect(decodePdfSegments('{'), isEmpty);
    expect(decodePdfSegments(null), isEmpty);
    expect(decodePdfSegments('{}'), isEmpty);
  });

  test('skips malformed entries', () {
    final decoded = decodePdfSegments(
      '[{"page":1,"rects":[[1,2,3,4]]},{"page":"x","rects":[]}]',
    );
    expect(decoded, hasLength(1));
    expect(decoded.single.page, 1);
  });

  test('filters by page', () {
    final json = encodePdfSegments(segments);
    final rects = pdfRectsForPage(json, 13);
    expect(rects, hasLength(1));
    expect(rects.single.left, 10);
    expect(pdfRectsForPage(json, 99), isEmpty);
  });
}
