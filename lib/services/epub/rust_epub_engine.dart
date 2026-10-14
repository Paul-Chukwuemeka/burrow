import 'dart:io';
import 'dart:typed_data';

import 'package:burrow/models/style_run.dart' show ImageRun;
import 'package:burrow/src/rust/api/epub.dart' as rust;
import 'package:burrow/src/rust/epub/project.dart' show ChapterDto;

import '../../utils/book_title.dart';
import '../document_parser.dart';
import '../epub_css_parser.dart';
import 'epub_dto_mapper.dart';
import 'epub_engine.dart';

/// The [EpubEngine] backed by the native Rust parser.
///
/// Opens one opaque Rust handle per book, then pulls metadata and each spine
/// chapter across the FFI (`chapter(handle, index)`), mapping the flat-run DTOs
/// onto the existing domain types (spec D4). Every offset the engine emits is a
/// Dart UTF-16 code unit, `%` lengths stay symbolic, and image bytes stay empty
/// until on-demand hydration (D15): [hydrateImages]/[hydrateFonts] fetch them
/// through the Rust handle via [readResource] instead of re-reading the
/// archive with Dart.
///
/// Phase A keeps the disk cache Dart-only: Rust writes no cache entry, so
/// [clearCacheFor] is a no-op rather than deleting the Dart engine's entry from
/// under it.
class RustEpubEngine implements EpubEngine {
  const RustEpubEngine();

  @override
  Future<ParsedDocument> parse(String path) async {
    final handle = await rust.openEpub(path: path);
    final metadata = await rust.metadata(handle: handle);
    // One chapter per TOC anchor, not per spine file: `chapterCount` is the
    // flattened anchor-split length, matching Dart's `splitByAnchors`.
    final count = await rust.chapterCount(handle: handle);
    final chapters = <ChapterDto>[];
    for (var index = 0; index < count; index++) {
      chapters.add(await rust.chapter(handle: handle, index: index));
    }
    return EpubDtoMapper.toParsedDocument(
      chapters: chapters,
      metadata: metadata,
      fallbackTitle: titleFromFilename(path),
    );
  }

  @override
  Future<ParsedMetadata> extractMetadata(String path) async {
    final metadata = await rust.readMetadata(path: path);
    return EpubDtoMapper.toParsedMetadata(
      metadata,
      fallbackTitle: titleFromFilename(path),
    );
  }

  /// Reads one archive entry's bytes through the Rust handle (spec D15).
  ///
  /// [key] is a normalised archive key — an [ImageRun.sourceKey] or a
  /// [FontFaceInfo.src]. Throws when the entry is absent; [hydrateImages] and
  /// [hydrateFonts] treat that as "skip".
  Future<Uint8List> readResource(
    rust.DocumentHandle handle,
    String key,
  ) =>
      rust.readResource(handle: handle, key: key);

  /// Fills deferred inline-image bytes from the source EPUB via Rust.
  ///
  /// Runs off the open path (after the first paint). A missing entry leaves
  /// that image's bytes empty — the renderer shows a sized placeholder — so a
  /// moved or damaged source degrades one image instead of failing the whole
  /// open. Never throws; returns [doc] unchanged when nothing is deferred or
  /// the book cannot be opened.
  Future<ParsedDocument> hydrateImages(
    ParsedDocument doc,
    String path,
  ) async {
    final keys = <String>{};
    for (final ch in doc.chapters) {
      for (final img in ch.images) {
        if (img.bytes.isEmpty && img.sourceKey != null) keys.add(img.sourceKey!);
      }
    }
    if (keys.isEmpty) return doc;

    final Map<String, Uint8List> bytes;
    try {
      final handle = await rust.openEpub(path: path);
      bytes = await _readKeys(handle, keys);
    } catch (_) {
      return doc;
    }
    if (bytes.isEmpty) return doc;

    final chapters = <Chapter>[];
    for (final ch in doc.chapters) {
      if (ch.images.isEmpty) {
        chapters.add(ch);
        continue;
      }
      final images = <ImageRun>[];
      for (final img in ch.images) {
        if (img.bytes.isNotEmpty || img.sourceKey == null) {
          images.add(img);
          continue;
        }
        final fetched = bytes[img.sourceKey];
        images.add(fetched == null ? img : img.copyWith(bytes: fetched));
      }
      chapters.add(Chapter(ch.title, ch.body, ch.runs, images));
    }
    return _rebuildDoc(doc, chapters: chapters);
  }

  /// Fills deferred `@font-face` bytes from the source EPUB via Rust.
  ///
  /// A font whose file is missing keeps null bytes, which
  /// [EpubCssParser.loadEmbeddedFonts] skips without throwing — a damaged
  /// font degrades to the fallback stack instead of failing the book. Never
  /// throws; returns [doc] unchanged when nothing is deferred or the book
  /// cannot be opened.
  Future<ParsedDocument> hydrateFonts(
    ParsedDocument doc,
    String path,
  ) async {
    if (!_needsFontHydration(doc)) return doc;

    final Map<String, Uint8List> bytes;
    try {
      final handle = await rust.openEpub(path: path);
      bytes = await _readKeys(handle, {
        for (final e in doc.fontFaces.entries)
          if (e.value.bytes == null && e.value.src.isNotEmpty) e.value.src,
      });
    } catch (_) {
      return doc;
    }

    final fontFaces = <String, FontFaceInfo>{};
    for (final e in doc.fontFaces.entries) {
      final info = e.value;
      if (info.bytes != null || info.src.isEmpty) {
        fontFaces[e.key] = info;
        continue;
      }
      final fetched = bytes[info.src];
      fontFaces[e.key] = FontFaceInfo(
        family: info.family,
        src: info.src,
        bytes: fetched,
      );
    }
    return _rebuildDoc(doc, fontFaces: fontFaces);
  }

  /// Reads [keys] through [handle], skipping absent entries.
  Future<Map<String, Uint8List>> _readKeys(
    rust.DocumentHandle handle,
    Set<String> keys,
  ) async {
    final out = <String, Uint8List>{};
    for (final key in keys) {
      try {
        final data = await readResource(handle, key);
        if (data.isNotEmpty) out[key] = data;
      } catch (_) {
        // Missing/unreadable entry: the caller leaves a placeholder.
      }
    }
    return out;
  }

  /// No-op: the Rust engine writes no disk cache in Phase A.
  @override
  void clearCacheFor(String path) {}
}

/// True when at least one font still needs its bytes materialised.
bool _needsFontHydration(ParsedDocument doc) {
  for (final info in doc.fontFaces.values) {
    if (info.bytes == null && info.src.isNotEmpty) return true;
  }
  return false;
}

/// Rebuilds [doc] with replaced chapters and/or font faces, preserving every
/// other field.
ParsedDocument _rebuildDoc(
  ParsedDocument doc, {
  List<Chapter>? chapters,
  Map<String, FontFaceInfo>? fontFaces,
}) {
  return ParsedDocument(
    title: doc.title,
    author: doc.author,
    chapters: chapters ?? doc.chapters,
    coverBytes: doc.coverBytes,
    description: doc.description,
    annotation: doc.annotation,
    genre: doc.genre,
    seriesName: doc.seriesName,
    seriesIndex: doc.seriesIndex,
    publisher: doc.publisher,
    isbn: doc.isbn,
    language: doc.language,
    publicationDate: doc.publicationDate,
    rights: doc.rights,
    type: doc.type,
    source: doc.source,
    titleSort: doc.titleSort,
    authorSort: doc.authorSort,
    fontFaces: fontFaces ?? doc.fontFaces,
  );
}

/// The filename-derived title, matching `DocumentParser._titleFromFilename`.
String titleFromFilename(String path) {
  final base = path.split(Platform.pathSeparator).last;
  final dot = base.lastIndexOf('.');
  return cleanBookTitle(dot > 0 ? base.substring(0, dot) : base);
}
