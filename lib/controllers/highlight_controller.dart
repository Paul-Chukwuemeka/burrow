import 'package:flutter/foundation.dart';

import '../db/database.dart' as db;
import '../models/book.dart';
import '../services/library_service.dart';
import '../utils/highlight_locator.dart';
import '../utils/pdf_highlight_geometry.dart';

/// Loads and mutates the highlights for one book.
///
/// The reader owns one instance per open book. The database is read once on
/// [load]; page rendering filters the in-memory list, never the database.
class HighlightController extends ChangeNotifier {
  HighlightController({required this.library, required this.book});

  final LibraryService library;
  final Book book;

  List<db.HighlightRow> _highlights = const [];
  Map<int, List<db.HighlightRow>> _byChapter = const {};
  Map<int, List<({PdfHighlightRect rect, int color})>> _pdfRectsByPage =
      const {};
  bool _disposed = false;

  List<db.HighlightRow> get highlights => List.unmodifiable(_highlights);

  Future<void> load() async {
    _highlights = await library.getHighlights(book.id);
    _byChapter = _groupByChapter(_highlights);
    _pdfRectsByPage = _groupPdfRects(_highlights);
    if (!_disposed) notifyListeners();
  }

  static Map<int, List<db.HighlightRow>> _groupByChapter(
    List<db.HighlightRow> rows,
  ) {
    final map = <int, List<db.HighlightRow>>{};
    for (final row in rows) {
      final start = row.chapter;
      if (start == null) continue;
      final end = row.endChapter ?? start;
      for (var chapter = start; chapter <= end; chapter++) {
        map.putIfAbsent(chapter, () => []).add(row);
      }
    }
    return map;
  }

  static Map<int, List<({PdfHighlightRect rect, int color})>> _groupPdfRects(
    List<db.HighlightRow> rows,
  ) {
    final map = <int, List<({PdfHighlightRect rect, int color})>>{};
    for (final row in rows) {
      for (final segment in decodePdfSegments(row.segments)) {
        final list = map.putIfAbsent(segment.page, () => []);
        for (final rect in segment.rects) {
          list.add((rect: rect, color: row.color));
        }
      }
    }
    return map;
  }

  Future<db.HighlightRow?> addReflowable({
    required String text,
    required int start,
    required int end,
    required List<int> charsBefore,
    required int color,
    String note = '',
  }) async {
    final locator = reflowableLocatorFromFlat(
      start: start,
      end: end,
      charsBefore: charsBefore,
    );
    final id = await library.addHighlight(
      bookId: book.id,
      text: text,
      note: note,
      color: color,
      chapter: locator.chapter,
      startOffset: locator.startOffset,
      endChapter: locator.endChapter,
      endOffset: locator.endOffset,
    );
    return _afterWrite(id);
  }

  Future<db.HighlightRow?> addPdf({
    required String text,
    required int page,
    required String segments,
    required int color,
    String note = '',
  }) async {
    final id = await library.addHighlight(
      bookId: book.id,
      text: text,
      note: note,
      color: color,
      page: page,
      segments: segments,
    );
    return _afterWrite(id);
  }

  Future<void> updateNote(String id, String note) async {
    await library.updateHighlightNote(id, note);
    await load();
  }

  Future<void> updateColor(String id, int color) async {
    await library.updateHighlightColor(id, color);
    await load();
  }

  Future<void> delete(String id) async {
    await library.deleteHighlight(id);
    await load();
  }

  Future<db.HighlightRow?> restore(db.HighlightRow row) async {
    final id = await library.addHighlight(
      bookId: book.id,
      text: row.quote,
      note: row.note,
      color: row.color,
      chapter: row.chapter,
      startOffset: row.startOffset,
      endChapter: row.endChapter,
      endOffset: row.endOffset,
      page: row.page,
      segments: row.segments,
    );
    return _afterWrite(id);
  }

  /// Highlights whose range overlaps [chapter], precomputed on load.
  List<db.HighlightRow> forChapter(int chapter) =>
      _byChapter[chapter] ?? const [];

  /// Highlight rectangles for one PDF page, precomputed on load.
  List<({PdfHighlightRect rect, int color})> pdfRectsForPage(int page) =>
      _pdfRectsByPage[page] ?? const [];

  Future<db.HighlightRow?> _afterWrite(String id) async {
    if (id.isEmpty) return null;
    await load();
    for (final row in _highlights) {
      if (row.id == id) return row;
    }
    return null;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
