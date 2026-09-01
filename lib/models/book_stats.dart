import 'book.dart';

/// Aggregated reading statistics for a single book.
class BookStats {
  const BookStats({
    required this.book,
    required this.totalTimeMs,
    required this.totalPages,
    required this.sessionCount,
  });

  final Book book;
  final int totalTimeMs;
  final int totalPages;
  final int sessionCount;

  double get avgSessionMs =>
      sessionCount > 0 ? totalTimeMs / sessionCount : 0;

  /// Pages per hour (or per session-hour), useful for speed display.
  double get pagesPerHour {
    if (totalTimeMs <= 0) return 0;
    return totalPages / (totalTimeMs / 3600000);
  }
}
