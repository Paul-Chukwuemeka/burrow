import 'package:flutter/foundation.dart';

import '../db/database.dart' as db;
import '../models/book.dart';
import '../services/library_service.dart';
import '../utils/highlight_locator.dart';

/// Loads and mutates the highlights for one book.
///
/// The reader owns one instance per open book. The database is read once on
/// [load]; page rendering filters the in-memory list, never the database.
class HighlightController extends ChangeNotifier {
  HighlightController({required this.library, required this.book});

  final LibraryService library;
  final Book book;

  List<db.HighlightRow> _highlights = const [];
  bool _disposed = false;

  List<db.HighlightRow> get highlights => List.unmodifiable(_highlights);

  Future<void> load() async {
    _highlights = await library.getHighlights(book.id);
    if (!_disposed) notifyListeners();
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

  /// Highlights whose range overlaps [chapter].
  List<db.HighlightRow> forChapter(int chapter) => _highlights
      .where(
        (row) =>
            row.chapter != null &&
            row.chapter! <= chapter &&
            (row.endChapter ?? row.chapter!) >= chapter,
      )
      .toList(growable: false);

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
