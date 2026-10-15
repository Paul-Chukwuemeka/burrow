import 'dart:io';
import 'dart:typed_data';

import 'package:burrow/models/style_run.dart' show ImageRun;
import 'package:burrow/src/rust/api/epub.dart' as rust;
import 'package:burrow/src/rust/epub/project.dart' show ChapterDto;

import '../../models/book.dart';
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
    // TXT is parsed natively through the FFI `parseTxt` port of
    // `DocumentParser._parseTxt`/`chapterizeTxt`. Every other non-EPUB format
    // still falls back to the Dart implementation for now.
    if (formatFromExtension(path) == BookFormat.txt) {
      return _parseTxt(path);
    }
    // CBZ/CBR comics are parsed natively through the FFI `parseCbz`/`parseCbr`
    // ports of the `_parseComicBook` branches. PDF is parsed natively through
    // the FFI `parsePdf` port of the `_parseIsolate` PDF stub (rendering stays
    // in `pdfrx`; the engine only returns the empty-chapter stub).
    final format = formatFromExtension(path);
    if (format == BookFormat.cbz || format == BookFormat.cbr) {
      return _parseComic(path, format);
    }
    if (format == BookFormat.pdf) {
      return _parsePdf(path);
    }
    // The reader opens every reflowable format through this seam, so any
    // future non-EPUB format still falls back to the Dart implementation
    // rather than failing as "not a valid EPUB" — mirroring
    // [extractMetadata]. Every known format (TXT/CBZ/CBR/PDF) already routes
    // to Rust above; this is belt and braces behind the factory fallback.
    if (formatFromExtension(path) != BookFormat.epub) {
      return DocumentParser.parse(path);
    }
    try {
      final handle = await rust.openEpub(path: path);
      try {
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
      } finally {
        // The handle owns the inflated archive on the Rust side: release it
        // deterministically instead of waiting on GC finalizers. Best-effort
        // so cleanup can never mask the parse result.
        try {
          await rust.closeDocument(handle: handle);
        } catch (_) {}
      }
    } on FormatException {
      rethrow;
    } catch (e) {
      // Belt and braces behind the factory fallback: a directly-constructed
      // engine (or a late dlopen failure) degrades to Dart rather than
      // bricking the open when the native library is absent.
      if (isRustNotInitializedFailure(e)) return DocumentParser.parse(path);
      if (isRustCorruptEpubFailure(e)) {
        throw FormatException(e.toString());
      }
      rethrow;
    }
  }

  /// Parses a TXT book through the Rust engine.
  ///
  /// Chapters carry no runs or images, so the DTOs map straight onto
  /// [Chapter]; the title is filename-derived exactly like
  /// `DocumentParser._parseTxt`. A missing native library degrades to Dart,
  /// while corrupt TXT (too large / empty) surfaces as a [FormatException]
  /// like the Dart engine.
  Future<ParsedDocument> _parseTxt(String path) async {
    try {
      final chapters = await rust.parseTxt(path: path);
      return ParsedDocument(
        title: titleFromFilename(path),
        author: '',
        chapters: [for (final c in chapters) EpubDtoMapper.toChapter(c)],
      );
    } catch (e) {
      if (isRustNotInitializedFailure(e)) return DocumentParser.parse(path);
      if (isRustCorruptTxtFailure(e)) {
        throw FormatException(e.toString());
      }
      rethrow;
    }
  }

  /// Parses a CBZ/CBR comic through the Rust engine.
  ///
  /// Each image entry becomes a chapter holding a single full-width `ImageRun`
  /// over a lone `\uFFFC`, with the first page's bytes as the cover —
  /// exactly like `DocumentParser._parseComicBook` (whose cover is
  /// un-downscaled on the parse path, so no `prepareCover` here). CBZ entries
  /// come from the Rust ZIP reader, CBR entries from the pure-Rust `rars`
  /// crate; the Dart `rar` plugin is never touched from this path (it stays
  /// as the Dart engine's CBR backend until its own retirement task). A
  /// missing native library degrades to Dart, while corrupt comics surface
  /// as a [FormatException] like the Dart engine.
  Future<ParsedDocument> _parseComic(String path, BookFormat format) async {
    try {
      final parsed = format == BookFormat.cbr
          ? await rust.parseCbr(path: path)
          : await rust.parseCbz(path: path);
      return ParsedDocument(
        title: titleFromFilename(path),
        author: '',
        chapters: [
          for (final page in parsed.pages)
            Chapter(page.title, '\uFFFC', const [], [
              ImageRun(
                offset: 0,
                bytes: page.imageBytes,
                intrinsicWidth: page.width,
                intrinsicHeight: page.height,
                fullWidth: true,
              ),
            ]),
        ],
        coverBytes: parsed.coverBytes,
      );
    } catch (e) {
      if (isRustNotInitializedFailure(e)) return DocumentParser.parse(path);
      if (format == BookFormat.cbr
          ? isRustCorruptCbrFailure(e)
          : isRustCorruptCbzFailure(e)) {
        throw FormatException(e.toString());
      }
      rethrow;
    }
  }

  /// Parses a PDF book through the Rust engine.
  ///
  /// Neither engine reflows PDF — rendering stays in `pdfrx`. The Dart
  /// isolate's PDF branch returns an empty-chapter stub without reading the
  /// file (filename-derived title, empty author, one `Chapter('', '')`, no
  /// cover bytes — the cover renders via `pdf_cover.dart`), and the FFI
  /// `parsePdf` port returns the same single empty chapter, so the mapped
  /// document is identical by construction. A missing native library degrades
  /// to Dart; the stub itself never fails, so no `FormatException`
  /// translation is needed (unlike TXT/CBZ/CBR, Dart throws nothing for PDF).
  Future<ParsedDocument> _parsePdf(String path) async {
    try {
      final chapters = await rust.parsePdf(path: path);
      return ParsedDocument(
        title: titleFromFilename(path),
        author: '',
        chapters: [for (final c in chapters) EpubDtoMapper.toChapter(c)],
      );
    } catch (e) {
      if (isRustNotInitializedFailure(e)) return DocumentParser.parse(path);
      rethrow;
    }
  }

  /// Extracts only metadata and cover bytes via the Rust OPF reader.
  ///
  /// Every format routes to Rust: EPUBs read the OPF manifest, while TXT/CBZ/
  /// CBR/PDF go through the `extractMetadataTxt/Cbz/Cbr/Pdf` ports of
  /// `DocumentParser._extractMetadataIsolate`'s per-format branches
  /// (filename-derived title, first-page comic cover, deferred CBR cover).
  /// The mapped metadata (including the downscaled cover) matches the Dart
  /// engine field by field. A missing native library degrades to Dart; corrupt
  /// books surface as a [FormatException] like the Dart engine.
  @override
  Future<ParsedMetadata> extractMetadata(String path) async {
    final format = formatFromExtension(path);
    if (format == BookFormat.epub) {
      return _extractEpubMetadata(path);
    }
    if (format == BookFormat.txt) {
      return _extractTxtMetadata(path);
    }
    if (format == BookFormat.cbz) {
      return _extractCbzMetadata(path);
    }
    if (format == BookFormat.cbr) {
      return _extractCbrMetadata(path);
    }
    if (format == BookFormat.pdf) {
      return _extractPdfMetadata(path);
    }
    // Belt and braces behind the factory fallback: an unknown extension still
    // degrades to the Dart implementation rather than failing.
    return DocumentParser.extractMetadata(path);
  }

  Future<ParsedMetadata> _extractEpubMetadata(String path) async {
    try {
      final metadata = await rust.readMetadata(path: path);
      return EpubDtoMapper.toParsedMetadata(
        metadata,
        fallbackTitle: titleFromFilename(path),
      );
    } on FormatException {
      rethrow;
    } catch (e) {
      if (isRustNotInitializedFailure(e)) {
        return DocumentParser.extractMetadata(path);
      }
      if (isRustCorruptEpubFailure(e)) {
        throw FormatException(e.toString());
      }
      rethrow;
    }
  }

  /// Extracts TXT metadata through the FFI `extractMetadataTxt` port.
  ///
  /// The file is never read on either side (filename-derived title, empty
  /// author, no cover), so only a missing native library needs handling.
  Future<ParsedMetadata> _extractTxtMetadata(String path) async {
    try {
      final metadata = await rust.extractMetadataTxt(path: path);
      return EpubDtoMapper.toParsedMetadata(
        metadata,
        fallbackTitle: titleFromFilename(path),
      );
    } catch (e) {
      if (isRustNotInitializedFailure(e)) {
        return DocumentParser.extractMetadata(path);
      }
      rethrow;
    }
  }

  /// Extracts CBZ metadata through the FFI `extractMetadataCbz` port.
  ///
  /// Only the first (natural-sorted) page's bytes cross as the cover; the
  /// mapper downscales them exactly like the Dart metadata path. Corrupt
  /// archives surface as a [FormatException] like the Dart engine.
  Future<ParsedMetadata> _extractCbzMetadata(String path) async {
    try {
      final metadata = await rust.extractMetadataCbz(path: path);
      return EpubDtoMapper.toParsedMetadata(
        metadata,
        fallbackTitle: titleFromFilename(path),
      );
    } on FormatException {
      rethrow;
    } catch (e) {
      if (isRustNotInitializedFailure(e)) {
        return DocumentParser.extractMetadata(path);
      }
      if (isRustCorruptCbzFailure(e)) {
        throw FormatException(e.toString());
      }
      rethrow;
    }
  }

  /// Extracts CBR metadata through the FFI `extractMetadataCbr` port.
  ///
  /// Like the Dart engine, the archive is never touched: metadata carries only
  /// the filename-derived title and series, with the cover deferred (null)
  /// until the comic is opened.
  Future<ParsedMetadata> _extractCbrMetadata(String path) async {
    try {
      final metadata = await rust.extractMetadataCbr(path: path);
      return EpubDtoMapper.toParsedMetadata(
        metadata,
        fallbackTitle: titleFromFilename(path),
      );
    } catch (e) {
      if (isRustNotInitializedFailure(e)) {
        return DocumentParser.extractMetadata(path);
      }
      rethrow;
    }
  }

  /// Extracts PDF metadata through the FFI `extractMetadataPdf` port.
  ///
  /// The file is never read on either side (filename-derived title, empty
  /// author, no cover — the cover renders via `pdf_cover.dart`), so only a
  /// missing native library needs handling.
  Future<ParsedMetadata> _extractPdfMetadata(String path) async {
    try {
      final metadata = await rust.extractMetadataPdf(path: path);
      return EpubDtoMapper.toParsedMetadata(
        metadata,
        fallbackTitle: titleFromFilename(path),
      );
    } catch (e) {
      if (isRustNotInitializedFailure(e)) {
        return DocumentParser.extractMetadata(path);
      }
      rethrow;
    }
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
  @override
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
      try {
        bytes = await _readKeys(handle, keys);
      } finally {
        try {
          await rust.closeDocument(handle: handle);
        } catch (_) {}
      }
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
  @override
  Future<ParsedDocument> hydrateFonts(
    ParsedDocument doc,
    String path,
  ) async {
    if (!_needsFontHydration(doc)) return doc;

    final Map<String, Uint8List> bytes;
    try {
      final handle = await rust.openEpub(path: path);
      try {
        bytes = await _readKeys(handle, {
          for (final e in doc.fontFaces.entries)
            if (e.value.bytes == null && e.value.src.isNotEmpty) e.value.src,
        });
      } finally {
        try {
          await rust.closeDocument(handle: handle);
        } catch (_) {}
      }
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
  ///
  /// Deliberately narrows to the Dart namespace: if a future Rust cache
  /// appears it must get its own namespaced `clearCacheFor` here, or book
  /// deletion will leak Rust entries. See [EpubEngine.clearCacheFor].
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

/// Whether a Rust-backend failure means the native library was never
/// initialized (`RustLib.init()` failed or was skipped) and the call must
/// degrade to the Dart engine instead of bricking the open.
///
/// Matches the `flutter_rust_bridge has not been initialized` guard the
/// generated bindings throw before touching the native library. Kept separate
/// from [isRustCorruptEpubFailure]: that one classifies unreadable books,
/// this one classifies a missing engine.
bool isRustNotInitializedFailure(Object error) {
  return error.toString().contains('has not been initialized');
}

/// Whether a Rust-backend failure means "permanently unreadable" and must be
/// surfaced as a [FormatException] — the class the library metadata worker
/// treats as complete-and-skipped (no retry on next launch).
///
/// The Rust FFI stringifies `EpubError`, so a corrupt EPUB surfaces as a
/// thrown `String` ("Not a valid EPUB file") rather than the
/// [FormatException] the Dart engine throws for the same file. Matching is
/// deliberately narrow — only the `Invalid` ("Not a valid EPUB file") and
/// `TooLarge` payloads, which mirror Dart's `FormatException`s — so
/// genuinely-transient failures (IO errors such as "Cannot open EPUB: ...")
/// are rethrown unchanged and still retry. An existing [FormatException]
/// needs no translation and returns false.
bool isRustCorruptEpubFailure(Object error) {
  if (error is FormatException) return false;
  final message = error.toString();
  return message.contains('Not a valid EPUB file') ||
      message.contains('EPUB file too large') ||
      message.contains('decompressed size exceeds');
}

/// Whether a Rust TXT failure means "permanently unreadable" and must be
/// surfaced as a [FormatException] — mirroring [isRustCorruptEpubFailure] for
/// the TXT messages (`Text file too large`, `File is empty`), which match
/// `DocumentParser._parseTxt`'s `FormatException`s verbatim. Transient
/// failures (IO errors such as "Cannot open text file: ...") are rethrown
/// unchanged and still retry. An existing [FormatException] needs no
/// translation and returns false.
bool isRustCorruptTxtFailure(Object error) {
  if (error is FormatException) return false;
  final message = error.toString();
  return message.contains('Text file too large') ||
      message.contains('File is empty');
}

/// Whether a Rust CBZ failure means "permanently unreadable" and must be
/// surfaced as a [FormatException] — mirroring [isRustCorruptEpubFailure] for
/// the CBZ messages (`CBZ file too large`, `Not a valid CBZ...`, `No images
/// found in comic archive`), which match `DocumentParser._parseComicBook`'s
/// `FormatException`s verbatim. Transient failures (such as `Entry not
/// found: ...`) are rethrown unchanged and still retry. An existing
/// [FormatException] needs no translation and returns false.
bool isRustCorruptCbzFailure(Object error) {
  if (error is FormatException) return false;
  final message = error.toString();
  return message.contains('CBZ file too large') ||
      message.contains('Not a valid CBZ') ||
      message.contains('No images found in comic archive') ||
      message.contains('decompressed size exceeds');
}

/// Whether a Rust CBR failure means "permanently unreadable" and must be
/// surfaced as a [FormatException] — mirroring [isRustCorruptCbzFailure] for
/// the CBR messages (`CBR file too large`, `Not a valid CBR...`, `Failed to
/// extract CBR archive`, `No images found in comic archive`), which match
/// `DocumentParser._parseComicBook`'s CBR `FormatException`s verbatim.
/// Transient failures (such as `Entry not found: ...`) are rethrown unchanged
/// and still retry. An existing [FormatException] needs no translation and
/// returns false.
bool isRustCorruptCbrFailure(Object error) {
  if (error is FormatException) return false;
  final message = error.toString();
  return message.contains('CBR file too large') ||
      message.contains('Not a valid CBR') ||
      message.contains('Failed to extract CBR archive') ||
      message.contains('No images found in comic archive') ||
      message.contains('decompressed size exceeds');
}

/// The filename-derived title, matching `DocumentParser._titleFromFilename`.
String titleFromFilename(String path) {
  final base = path.split(Platform.pathSeparator).last;
  final dot = base.lastIndexOf('.');
  return cleanBookTitle(dot > 0 ? base.substring(0, dot) : base);
}
