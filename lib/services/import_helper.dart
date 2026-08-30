import '../models/book.dart';
import 'library_service.dart';

/// Shared book-import pipeline used by the library screen and the onboarding
/// flow so "import what we found" stays in one place.
///
/// Books already in the library are skipped silently; unreadable files are
/// counted as failures and reported via the optional error callbacks so each
/// caller can surface them in its own UI.
abstract final class BookImporter {
  /// Imports every [paths], returning the newly added books and how many files
  /// could not be read.
  static Future<(List<Book> added, int failed)> importPaths(
    LibraryService library,
    Iterable<String> paths, {
    void Function(FormatException error)? onFormatError,
    void Function(Object error)? onError,
  }) async {
    final added = <Book>[];
    var failed = 0;
    for (final path in paths) {
      try {
        final book = await library.importFile(path);
        if (book != null) added.add(book);
      } on FormatException catch (e) {
        onFormatError?.call(e);
        failed++;
      } catch (e) {
        onError?.call(e);
        failed++;
      }
    }
    return (added, failed);
  }

  /// Runs [scan], imports every result and returns the scan paths alongside
  /// the outcome so callers can distinguish "nothing found" from failures.
  static Future<(List<String> paths, List<Book> added, int failed)> runScan(
    LibraryService library,
    Future<List<String>> scan, {
    void Function(FormatException error)? onFormatError,
    void Function(Object error)? onError,
  }) async {
    final paths = await scan;
    final (added, failed) = await importPaths(
      library,
      paths,
      onFormatError: onFormatError,
      onError: onError,
    );
    return (paths, added, failed);
  }
}
