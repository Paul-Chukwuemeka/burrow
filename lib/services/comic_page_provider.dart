import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'document_parser.dart';

/// Lazy provider for comic book pages from a CBZ archive.
///
/// Keeps the archive structure in memory (lightweight) but only reads
/// individual image bytes on demand. An LRU cache avoids re-reading
/// pages the user is likely to revisit.
class ComicPageProvider {
  ComicPageProvider._({
    required this.pageCount,
    required this.pages,
    required Archive archive,
  }) : _archive = archive;

  final int pageCount;
  final List<ComicPageMeta> pages;
  final Archive _archive;

  static const _maxCacheSize = 15;

  final LinkedHashMap<int, Uint8List> _cache = LinkedHashMap();

  /// Opens a CBZ archive and builds page metadata without reading image bytes.
  static Future<ComicPageProvider> open(String path) async {
    final bytes = await File(path).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);

    final entries = archive.files
        .where((f) => f.isFile && DocumentParser.isImageEntry(f.name))
        .toList();
    entries.sort((a, b) => DocumentParser.naturalCompare(a.name, b.name));

    if (entries.isEmpty) {
      throw const FormatException('No images found in comic archive');
    }

    final pageMetas = <ComicPageMeta>[];
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      final content = entry.content as List<int>;
      final (w, h) = DocumentParser.decodeImageDimensions(Uint8List.fromList(content));
      pageMetas.add(ComicPageMeta(
        index: i,
        entryName: entry.name,
        intrinsicWidth: w,
        intrinsicHeight: h,
      ));
    }

    return ComicPageProvider._(
      pageCount: entries.length,
      pages: pageMetas,
      archive: archive,
    );
  }

  /// Returns cached page bytes, or loads and caches them.
  Future<Uint8List> loadPage(int index) async {
    final cached = _cache.remove(index);
    if (cached != null) {
      // Re-insert at end (most recently used).
      _cache[index] = cached;
      return cached;
    }

    final entry = _archive.files.firstWhere((f) => f.name == pages[index].entryName);
    final bytes = Uint8List.fromList(entry.content as List<int>);
    _put(index, bytes);
    return bytes;
  }

  /// Returns page bytes synchronously if cached, null otherwise.
  Uint8List? peekPage(int index) => _cache[index];

  /// Whether the given page is currently in the in-memory cache.
  bool isCached(int index) => _cache.containsKey(index);

  void _put(int index, Uint8List bytes) {
    _cache[index] = bytes;
    while (_cache.length > _maxCacheSize) {
      _cache.remove(_cache.keys.first);
    }
  }

  /// Evicts pages outside [center ± margin] from the cache.
  void evictOutside(int center, {int margin = 10}) {
    final keep = <int>{for (var i = center - margin; i <= center + margin; i++) i};
    _cache.removeWhere((key, _) => !keep.contains(key));
  }

  void dispose() {
    _cache.clear();
  }
}

/// Metadata for a single comic page (no image bytes).
class ComicPageMeta {
  const ComicPageMeta({
    required this.index,
    required this.entryName,
    required this.intrinsicWidth,
    required this.intrinsicHeight,
  });

  final int index;
  final String entryName;
  final int intrinsicWidth;
  final int intrinsicHeight;
}
