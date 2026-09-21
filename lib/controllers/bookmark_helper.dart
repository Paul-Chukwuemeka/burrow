import 'package:flutter/material.dart';

import '../db/database.dart' as db;
import '../models/book.dart';
import '../services/library_service.dart';

class BookmarkHelper extends ChangeNotifier {
  BookmarkHelper({
    required this.library,
    required this.book,
    required this.getCurrentPosition,
    required this.isPdf,
  });

  final LibraryService library;
  final Book book;
  final ({int chapter, int offset, String? snippet})? Function()
  getCurrentPosition;
  final bool isPdf;

  List<db.Bookmark> _bookmarks = [];
  bool _isCurrentPageBookmarked = false;
  bool _disposed = false;

  List<db.Bookmark> get bookmarks => List.unmodifiable(_bookmarks);
  bool get isCurrentPageBookmarked => _isCurrentPageBookmarked;

  Future<void> checkBookmarkState() => _checkBookmarkState();

  Future<void> loadBookmarks() async {
    _bookmarks = await library.getBookmarks(book.id);
    if (!_disposed) notifyListeners();
    await _checkBookmarkState();
  }

  Future<void> _checkBookmarkState() async {
    final pos = getCurrentPosition();
    if (pos == null) {
      _isCurrentPageBookmarked = false;
      if (!_disposed) notifyListeners();
      return;
    }

    if (isPdf) {
      final found = _bookmarks.any((bm) => bm.chapter == pos.chapter);
      _isCurrentPageBookmarked = found;
      if (!_disposed) notifyListeners();
      return;
    }

    final found = await library.isBookmarked(
      bookId: book.id,
      chapter: pos.chapter,
      offset: pos.offset,
    );
    _isCurrentPageBookmarked = found;
    if (!_disposed) notifyListeners();
  }

  Future<void> toggleBookmark() async {
    final pos = getCurrentPosition();
    if (pos == null) return;

    if (isPdf) {
      if (_isCurrentPageBookmarked) {
        for (final bm in _bookmarks) {
          if (bm.chapter == pos.chapter) {
            await library.deleteBookmark(bm.id);
            break;
          }
        }
      } else {
        await library.addBookmark(
          bookId: book.id,
          chapter: pos.chapter,
          offset: 0,
          snippet: pos.snippet ?? 'Page ${pos.chapter}',
        );
      }
      await loadBookmarks();
      return;
    }

    if (_isCurrentPageBookmarked) {
      for (final bm in _bookmarks) {
        if (bm.chapter == pos.chapter && bm.offset == pos.offset) {
          await library.deleteBookmark(bm.id);
          break;
        }
      }
    } else {
      await library.addBookmark(
        bookId: book.id,
        chapter: pos.chapter,
        offset: pos.offset,
        snippet: pos.snippet ?? '',
      );
    }
    await loadBookmarks();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
