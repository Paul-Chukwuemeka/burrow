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
    void Function(int completed, int total)? onProgress,
  }) async {
    final added = <Book>[];
    var failed = 0;
    final pathList = paths.toList();
    final total = pathList.length;
    for (var i = 0; i < total; i++) {
      onProgress?.call(i, total);
      try {
        final book = await library.importFile(pathList[i]);
        if (book != null) added.add(book);
      } on FormatException catch (e) {
        onFormatError?.call(e);
        failed++;
      } catch (e) {
        onError?.call(e);
        failed++;
      }
    }
    onProgress?.call(total, total);
    return (added, failed);
  }

  /// Runs [scan], imports every result and returns the scan paths alongside
  /// the outcome so callers can distinguish "nothing found" from failures.
  static Future<(List<String> paths, List<Book> added, int failed)> runScan(
    LibraryService library,
    Future<List<String>> scan, {
    void Function(FormatException error)? onFormatError,
    void Function(Object error)? onError,
    void Function(int completed, int total)? onProgress,
    void Function(int pathCount)? onScanComplete,
  }) async {
    final paths = await scan;
    onScanComplete?.call(paths.length);
    final (added, failed) = await importPaths(
      library,
      paths,
      onFormatError: onFormatError,
      onError: onError,
      onProgress: onProgress,
    );
    return (paths, added, failed);
  }
}
