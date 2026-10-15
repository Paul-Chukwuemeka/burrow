import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:burrow/utils/comic_archive.dart';

/// Read access to comic page bytes, decoupled from how they are fetched so
/// the reader controller can be tested with an in-memory fake.
abstract interface class ComicPageSource {
  int get pageCount;
  List<ComicPageMeta> get pages;
  Future<Uint8List> loadPage(int index);
  Uint8List? peekPage(int index);
  bool isCached(int index);
  void evictOutside(int center, {int margin = 5});
  void dispose();
}

/// Lazy provider for comic book pages from a CBZ archive.
///
/// Memory model: `ZipDecoder().decodeBytes()` decompresses all entries into
/// the [_archive] object, which is held for the provider's lifetime. The raw
/// file bytes are released after [open] returns. The LRU cache holds
/// additional copies of recently viewed pages — keep it small to avoid
/// doubling memory pressure. A full fix requires switching to a ZIP library
/// that supports random-access reads (e.g. reading the central directory
/// without decompressing all entries).
class ComicPageProvider implements ComicPageSource {
  ComicPageProvider._({
    required this.pageCount,
    required this.pages,
    required Archive archive,
  }) : _archive = archive;

  @override
  final int pageCount;

  @override
  final List<ComicPageMeta> pages;

  final Archive _archive;

  /// Small cache: the archive already holds all decompressed data, so this
  /// only avoids the per-read copy cost. Keep low to limit extra copies.
  static const _maxCacheSize = 7;

  final LinkedHashMap<int, Uint8List> _cache = LinkedHashMap();

  /// Maximum compressed CBZ size.
  ///
  /// Kept as a local constant (instead of importing the parser's) so the
  /// reader path can never silently lose its guard if the parser changes.
  static const _maxCompressedBytes = 500 * 1024 * 1024;

  /// Maximum total decompressed bytes.
  static const _maxDecompressedBytes = 512 * 1024 * 1024;

  /// Opens a CBZ archive and builds page metadata without reading image bytes.
  ///
  /// Rejects oversized archives before decoding so a 500 MB CBZ or a
  /// highly-compressible zip-bomb cannot OOM the reader on low-end Android.
  /// (Round 12 added these guards here on the actual reader path.)
  ///
  /// TODO(#38): `ZipDecoder().decodeBytes()` decompresses all entries into
  /// memory upfront. For large CBZ files this is O(archive_size). A proper
  /// fix would use a ZIP library that supports random-access reads of the
  /// central directory, decompressing entries only on demand in [loadPage].
  ///
  /// Known limitation (honest note, not a silent bound): the decompressed-sum
  /// check below necessarily runs *after* full inflation — it bounds what we
  /// retain, but cannot prevent the transient spike during decode. A header-
  /// only central-directory pre-scan would need a ZIP reader that doesn't
  /// inflate on open; `package:archive` offers none, so this stays a TODO
  /// rather than a half-measure that still OOMs.
  static Future<ComicPageProvider> open(String path) async {
    final file = File(path);
    final length = await file.length();
    if (length > _maxCompressedBytes) {
      throw const FormatException('CBZ file too large (limit 500 MB)');
    }
    final bytes = await file.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);

    var decompressed = 0;
    for (final f in archive.files) {
      decompressed += f.size;
      if (decompressed > _maxDecompressedBytes) {
        throw const FormatException(
          'Archive decompressed size exceeds 512 MB',
        );
      }
    }

    final entries = archive.files
        .where((f) => f.isFile && isImageEntry(f.name))
        .toList();
    entries.sort((a, b) => naturalCompare(a.name, b.name));

    if (entries.isEmpty) {
      throw const FormatException('No images found in comic archive');
    }

    final pageMetas = <ComicPageMeta>[];
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      final content = entry.content as List<int>;
      final (w, h) = decodeImageDimensions(
        Uint8List.fromList(content),
      );
      pageMetas.add(
        ComicPageMeta(
          index: i,
          entryName: entry.name,
          intrinsicWidth: w,
          intrinsicHeight: h,
        ),
      );
    }

    return ComicPageProvider._(
      pageCount: entries.length,
      pages: pageMetas,
      archive: archive,
    );
  }

  /// Returns cached page bytes, or loads and caches them.
  @override
  Future<Uint8List> loadPage(int index) async {
    final cached = _cache.remove(index);
    if (cached != null) {
      // Re-insert at end (most recently used).
      _cache[index] = cached;
      return cached;
    }

    final entry = _archive.files.firstWhere(
      (f) => f.name == pages[index].entryName,
      orElse: () => throw FormatException(
        'Archive entry not found: ${pages[index].entryName}',
      ),
    );
    final bytes = Uint8List.fromList(entry.content);
    _put(index, bytes);
    return bytes;
  }

  /// Returns page bytes synchronously if cached, null otherwise.
  @override
  Uint8List? peekPage(int index) => _cache[index];

  /// Whether the given page is currently in the in-memory cache.
  @override
  bool isCached(int index) => _cache.containsKey(index);

  void _put(int index, Uint8List bytes) {
    _cache[index] = bytes;
    while (_cache.length > _maxCacheSize) {
      _cache.remove(_cache.keys.first);
    }
  }

  /// Evicts pages outside [center ± margin] from the cache.
  @override
  void evictOutside(int center, {int margin = 5}) {
    final keep = <int>{
      for (var i = center - margin; i <= center + margin; i++) i,
    };
    _cache.removeWhere((key, _) => !keep.contains(key));
  }

  @override
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
