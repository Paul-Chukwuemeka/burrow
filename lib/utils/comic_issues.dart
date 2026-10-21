import '../models/book.dart';
import 'book_title.dart';

/// Ordering and adjacency helpers for navigating a comic's issues in-reader.
///
/// The order mirrors the Series screen's default "Order" sort: ascending
/// `seriesIndex`, books without an index last. Books with equal indexes are
/// tie-broken by title (case-insensitive) so the order is always stable, and
/// value-equal issue numbers sort after smaller ones.
List<Book> orderedComicIssues(Iterable<Book> seriesBooks) {
  final list = List<Book>.of(seriesBooks);
  list.sort((a, b) {
    final ai = a.seriesIndex;
    final bi = b.seriesIndex;
    if (ai == null && bi == null) {
      return a.displayTitle.toLowerCase().compareTo(
            b.displayTitle.toLowerCase(),
          );
    }
    if (ai == null) return 1;
    if (bi == null) return -1;
    final byIndex = ai.compareTo(bi);
    if (byIndex != 0) return byIndex;
    return a.displayTitle.toLowerCase().compareTo(
          b.displayTitle.toLowerCase(),
        );
  });
  return list;
}

/// Finds [current] in the ordered issue list, or null if it is absent.
int _position(List<Book> issues, Book current) {
  for (var i = 0; i < issues.length; i++) {
    if (issues[i].id == current.id) return i;
  }
  return -1;
}

/// The issue preceding [current] within its series, ordered like the Series
/// screen's default sort. Null when [current] is the first issue or not part
/// of the passed list.
Book? previousComicIssue(Iterable<Book> seriesBooks, Book current) {
  final issues = orderedComicIssues(seriesBooks);
  final position = _position(issues, current);
  if (position <= 0) return null;
  return issues[position - 1];
}

/// The issue following [current] within its series, ordered like the Series
/// screen's default sort. Null when [current] is the last issue or not part
/// of the passed list.
Book? nextComicIssue(Iterable<Book> seriesBooks, Book current) {
  final issues = orderedComicIssues(seriesBooks);
  final position = _position(issues, current);
  if (position < 0 || position + 1 >= issues.length) return null;
  return issues[position + 1];
}
