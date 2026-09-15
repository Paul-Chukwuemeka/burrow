import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:rar/rar.dart';
import 'package:xml/xml.dart';

import '../models/book.dart';
import '../models/css_style.dart';
import '../models/style_run.dart';
import '../utils/book_title.dart';
import '../utils/comic_series.dart';
import 'epub_css_parser.dart';

class Chapter {
  const Chapter(
    this.title,
    this.body, [
    this.runs = const [],
    this.images = const [],
  ]);
  final String title;
  final String body;

  /// Styled ranges over [body] (emphasis, blockquotes). Empty for plain-text
  /// sources; rendering falls back to uniform styling when absent.
  final List<StyleRun> runs;

  /// Inline images embedded in [body] at the corresponding `\uFFFC` offsets.
  final List<ImageRun> images;
}

class ParsedDocument {
  const ParsedDocument({
    required this.title,
    required this.author,
    required this.chapters,
    this.coverBytes,
    this.description,
    this.annotation,
    this.genre,
    this.seriesName,
    this.seriesIndex,
    this.publisher,
    this.isbn,
    this.language,
    this.publicationDate,
    this.rights,
    this.type,
    this.source,
    this.titleSort,
    this.authorSort,
    this.fontFaces = const {},
  });
  final String title;
  final String author;
  final List<Chapter> chapters;

  /// Raw image bytes (jpeg/png) for the cover, if the file embeds one.
  final List<int>? coverBytes;

  final String? description;
  final String? annotation;
  final String? genre;
  final String? seriesName;
  final double? seriesIndex;
  final String? publisher;
  final String? isbn;
  final String? language;
  final String? publicationDate;
  final String? rights;
  final String? type;
  final String? source;
  final String? titleSort;
  final String? authorSort;

  /// Embedded fonts parsed from @font-face rules.
  final Map<String, FontFaceInfo> fontFaces;
}

/// Metadata and cover extracted from a document without parsing its content.
///
/// Mirrors the metadata fields of [ParsedDocument] so the background metadata
/// worker can populate a book by reading OPF/manifest data only, skipping the
/// expensive chapter/CSS/image pipeline.
class ParsedMetadata {
  const ParsedMetadata({
    required this.title,
    required this.author,
    this.coverBytes,
    this.description,
    this.annotation,
    this.genre,
    this.seriesName,
    this.seriesIndex,
    this.publisher,
    this.isbn,
    this.language,
    this.publicationDate,
    this.rights,
    this.type,
    this.source,
    this.titleSort,
    this.authorSort,
  });
  final String title;
  final String author;
  final List<int>? coverBytes;
  final String? description;
  final String? annotation;
  final String? genre;
  final String? seriesName;
  final double? seriesIndex;
  final String? publisher;
  final String? isbn;
  final String? language;
  final String? publicationDate;
  final String? rights;
  final String? type;
  final String? source;
  final String? titleSort;
  final String? authorSort;

  ParsedMetadata copyWith({List<int>? coverBytes}) {
    return ParsedMetadata(
      title: title,
      author: author,
      coverBytes: coverBytes ?? this.coverBytes,
      description: description,
      annotation: annotation,
      genre: genre,
      seriesName: seriesName,
      seriesIndex: seriesIndex,
      publisher: publisher,
      isbn: isbn,
      language: language,
      publicationDate: publicationDate,
      rights: rights,
      type: type,
      source: source,
      titleSort: titleSort,
      authorSort: authorSort,
    );
  }
}

/// One table-of-contents entry, in document order.
///
/// [fragment] is kept (not stripped) because several entries commonly point
/// into a single spine document via `#anchor`; each of those is a chapter in
/// its own right, so the fragment is what tells them apart.
@immutable
class TocEntry {
  const TocEntry(this.fileKey, this.fragment, this.title);

  /// Normalized zip path of the target document, without the fragment.
  final String fileKey;

  /// Raw (still percent-encoded) anchor id, or null when the entry targets the
  /// whole document.
  final String? fragment;

  final String title;

  @override
  bool operator ==(Object other) =>
      other is TocEntry &&
      other.fileKey == fileKey &&
      other.fragment == fragment &&
      other.title == title;

  @override
  int get hashCode => Object.hash(fileKey, fragment, title);
}

class DocumentParser {
  /// Parses a document into chapters. Heavy work runs in a background isolate.
  ///
  /// The cache directory is resolved here, on the main isolate, because
  /// `path_provider` uses a platform channel that is unavailable inside a
  /// `compute` isolate.
  static Future<ParsedDocument> parse(String path) async {
    final cacheDir = await _safeCacheDirPath();
    return compute(_parseIsolate, (path, cacheDir));
  }

  /// Extracts only metadata and cover bytes from a document.
  ///
  /// Far cheaper than [parse]: it reads the EPUB OPF/manifest (and the cover
  /// entry) without touching chapter text, CSS, embedded fonts, or images, and
  /// never writes the content cache. Intended for the background metadata
  /// worker so a freshly imported library becomes usable quickly.
  static Future<ParsedMetadata> extractMetadata(String path) {
    return compute(_extractMetadataIsolate, path);
  }

  static Future<ParsedMetadata> _extractMetadataIsolate(String path) async {
    ParsedMetadata meta;
    switch (formatFromExtension(path)) {
      case BookFormat.epub:
        meta = await _extractEpubMetadata(path);
      case BookFormat.pdf:
      case BookFormat.txt:
        meta = ParsedMetadata(title: _titleFromFilename(path), author: '');
      case BookFormat.cbz:
        meta = await _extractCbzMetadata(path);
      case BookFormat.cbr:
        // The rar plugin can only extract whole archives, so a CBR cover is
        // deferred until the comic is opened. Metadata needs only the title.
        final series = parseComicSeries(path);
        meta = ParsedMetadata(
          title: _titleFromFilename(path),
          author: '',
          seriesName: series.name,
          seriesIndex: series.index,
        );
    }
    final cover = _downscaleCover(meta.coverBytes);
    return cover == null ? meta : meta.copyWith(coverBytes: cover);
  }

  /// Shrinks a cover to at most [maxDimension] px on its long edge so the
  /// library does not decode (or store) multi-megapixel originals. Returns the
  /// original bytes when decoding fails or the image is already small.
  static Uint8List? prepareCover(List<int>? bytes) => _downscaleCover(bytes);

  static Uint8List? _downscaleCover(
    List<int>? bytes, {
    int maxDimension = 600,
  }) {
    if (bytes == null || bytes.isEmpty) return null;
    final original = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    try {
      final decoded = img.decodeImage(original);
      if (decoded == null) return original;
      if (decoded.width <= maxDimension &&
          decoded.height <= maxDimension &&
          original.length <= 300 * 1024) {
        return original;
      }
      final resized = decoded.width >= decoded.height
          ? img.copyResize(decoded, width: maxDimension)
          : img.copyResize(decoded, height: maxDimension);
      return Uint8List.fromList(img.encodeJpg(resized, quality: 82));
    } catch (_) {
      return original;
    }
  }

  /// Reads only the OPF metadata and cover entry from an EPUB.
  static Future<ParsedMetadata> _extractEpubMetadata(String path) async {
    final file = File(path);
    final length = await file.length();
    if (length > 100 * 1024 * 1024) {
      throw const FormatException('EPUB file too large (limit 100 MB)');
    }
    final Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } catch (_) {
      throw const FormatException('Not a valid EPUB file');
    }
    return extractEpubMetadataBytes(
      bytes,
      fallbackTitle: _titleFromFilename(path),
    );
  }

  /// In-memory counterpart of [_extractEpubMetadata], for tests.
  @visibleForTesting
  static ParsedMetadata extractEpubMetadataBytes(
    Uint8List bytes, {
    String fallbackTitle = '',
  }) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw const FormatException('Not a valid EPUB file');
    }

    final entries = <String, ArchiveFile>{
      for (final f in archive.files)
        Uri.decodeComponent(f.name.toLowerCase()): f,
    };
    ArchiveFile? lookup(String name) => entries[name.toLowerCase()];

    // container.xml -> rootfile (the .opf path).
    String opfPath = '';
    final containerData = lookup('META-INF/container.xml')?.content;
    if (containerData != null) {
      try {
        final container = XmlDocument.parse(
          utf8.decode(containerData, allowMalformed: true),
        );
        for (final el in _els(container, 'rootfile')) {
          final full = el.getAttribute('full-path');
          if (full != null && full.isNotEmpty) {
            opfPath = full;
            break;
          }
        }
      } catch (_) {}
    }

    final opfData = lookup(opfPath)?.content;
    if (opfData == null) throw const FormatException('Not a valid EPUB file');
    final XmlDocument opf;
    try {
      opf = XmlDocument.parse(utf8.decode(opfData, allowMalformed: true));
    } catch (_) {
      throw const FormatException('Not a valid EPUB file');
    }

    final meta = _parseOpfMetadata(opf);
    return ParsedMetadata(
      title: meta.title.isEmpty ? fallbackTitle : meta.title,
      author: meta.author,
      coverBytes: _extractCover(archive, entries, opf),
      description: meta.description,
      annotation: meta.annotation,
      genre: meta.genre,
      seriesName: meta.seriesName,
      seriesIndex: meta.seriesIndex,
      publisher: meta.publisher,
      isbn: meta.isbn,
      language: meta.language,
      publicationDate: meta.publicationDate,
      rights: meta.rights,
      type: meta.type,
      source: meta.source,
      titleSort: meta.titleSort,
      authorSort: meta.authorSort,
    );
  }

  /// Reads the zip directory and only the first page image of a CBZ.
  static Future<ParsedMetadata> _extractCbzMetadata(String path) async {
    final Uint8List bytes;
    try {
      bytes = await File(path).readAsBytes();
    } catch (_) {
      throw const FormatException('Not a valid CBZ file');
    }
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw const FormatException('Not a valid CBZ/ZIP archive');
    }
    final names =
        archive.files
            .where((f) => f.isFile && _isImage(f.name))
            .map((f) => f.name)
            .toList()
          ..sort(_naturalCompare);
    if (names.isEmpty) {
      throw const FormatException('No images found in comic archive');
    }
    // Accessing `.content` decompresses only this entry.
    final cover = archive.files
        .firstWhere((f) => f.name == names.first)
        .content;
    final series = parseComicSeries(path);
    return ParsedMetadata(
      title: _titleFromFilename(path),
      author: '',
      seriesName: series.name,
      seriesIndex: series.index,
      coverBytes: cover,
    );
  }

  static Future<ParsedDocument> _parseIsolate((String, String?) args) async {
    final (path, cacheDirPath) = args;
    // Check disk cache for EPUB/TXT (formats where parsing is expensive).
    final fmt = formatFromExtension(path);
    if ((fmt == BookFormat.epub || fmt == BookFormat.txt) &&
        cacheDirPath != null) {
      final cached = await _loadFromCache(path, cacheDirPath);
      if (cached != null) {
        // The cache stores image/font references, not bytes; re-read them
        // from the source EPUB. If that fails (source moved/changed), drop the
        // stale entry and fall through to a full parse.
        if (fmt == BookFormat.epub) {
          final hydrated = _hydrateAssets(cached, path);
          if (hydrated != null) return hydrated;
          _deleteCacheFile(path, cacheDirPath);
        } else {
          return cached;
        }
      }
    }

    ParsedDocument doc;
    switch (fmt) {
      case BookFormat.epub:
        doc = await _parseEpub(path);
      case BookFormat.pdf:
        doc = ParsedDocument(
          title: _titleFromFilename(path),
          author: '',
          chapters: const [Chapter('', '')],
        );
      case BookFormat.txt:
        doc = await _parseTxt(path);
      case BookFormat.cbz:
      case BookFormat.cbr:
        doc = await _parseComicBook(path);
    }

    // Save to disk cache for expensive formats.
    if ((fmt == BookFormat.epub || fmt == BookFormat.txt) &&
        cacheDirPath != null) {
      await _saveToCache(path, doc, cacheDirPath);
    }

    return doc;
  }

  // --------------------------------------------------------------------------
  // EPUB: a minimal OPF/spine/NCX reader over the zip container.
  // --------------------------------------------------------------------------

  static Future<ParsedDocument> _parseEpub(String path) async {
    final file = File(path);
    final length = await file.length();
    if (length > 100 * 1024 * 1024) {
      throw const FormatException('EPUB file too large (limit 100 MB)');
    }
    final Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } catch (_) {
      throw const FormatException('Not a valid EPUB file');
    }
    return parseEpubBytes(bytes, fallbackTitle: _titleFromFilename(path));
  }

  /// Parses EPUB [bytes] into chapters. Separated from file reading so tests
  /// can drive the whole OPF/spine/NCX path from an in-memory archive.
  @visibleForTesting
  static ParsedDocument parseEpubBytes(
    Uint8List bytes, {
    String fallbackTitle = '',
  }) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw const FormatException('Not a valid EPUB file');
    }

    // Case-insensitive entry lookup; EPUBs are inconsistent about casing.
    final entries = {
      for (final f in archive.files)
        Uri.decodeComponent(f.name.toLowerCase()): f,
    };
    Uint8List? entry(String name) => entries[name.toLowerCase()]?.content;

    XmlDocument? tryParse(Uint8List? data) {
      if (data == null) return null;
      try {
        return XmlDocument.parse(utf8.decode(data, allowMalformed: true));
      } catch (_) {
        return null;
      }
    }

    // container.xml -> rootfile (the .opf path).
    final container = tryParse(entry('META-INF/container.xml'));
    String opfPath = '';
    if (container != null) {
      for (final el in _els(container, 'rootfile')) {
        final full = el.getAttribute('full-path');
        if (full != null && full.isNotEmpty) {
          opfPath = full;
          break;
        }
      }
    }
    final opfData = entry(opfPath);
    final opf = opfData == null ? null : tryParse(opfData);
    if (opf == null) throw const FormatException('Not a valid EPUB file');

    final opfDir = opfPath.contains('/')
        ? opfPath.substring(0, opfPath.lastIndexOf('/'))
        : '';

    final meta = _parseOpfMetadata(opf);

    // Manifest: id -> resolved href. The item flagged properties="nav" is the
    // EPUB3 table of contents.
    final manifest = <String, String>{};
    final manifestImageDims =
        <String, (double, double)>{}; // href -> (width, height)
    String? navPath;
    for (final el in _els(opf, 'item')) {
      final id = el.getAttribute('id');
      final href = el.getAttribute('href');
      if (id == null || href == null) continue;
      final resolved = _resolveHref(opfDir, href);
      manifest[id] = resolved;
      final props = el.getAttribute('properties');
      if (props != null && props.split(RegExp(r'\s+')).contains('nav')) {
        navPath = resolved;
      }
      // Read width/height from OPF manifest for images.
      final wAttr = el.getAttribute('width');
      final hAttr = el.getAttribute('height');
      if (wAttr != null && hAttr != null) {
        final w = double.tryParse(wAttr);
        final h = double.tryParse(hAttr);
        if (w != null && h != null && w > 0 && h > 0) {
          manifestImageDims[resolved.toLowerCase()] = (w, h);
        }
      }
    }

    // Spine order (fall back to all XHTML manifest entries).
    final spineIds = [
      for (final el in _els(opf, 'itemref'))
        if (el.getAttribute('idref') != null) el.getAttribute('idref')!,
    ];
    final docPaths = [
      ...spineIds.map((id) => manifest[id]).nonNulls,
      if (spineIds.isEmpty)
        ...manifest.values.where(
          (p) => p.endsWith('.xhtml') || p.endsWith('.html'),
        ),
    ];

    // Table of contents, in reading order and with fragments intact.
    var tocEntries = const <TocEntry>[];
    final spineToc = _els(opf, 'spine').firstOrNull?.getAttribute('toc');
    var ncxPath = spineToc == null ? null : manifest[spineToc];
    if (ncxPath == null) {
      for (final p in manifest.values) {
        if (p.toLowerCase().endsWith('.ncx')) {
          ncxPath = p;
          break;
        }
      }
    }
    if (ncxPath != null) {
      final ncxDir = ncxPath.contains('/')
          ? ncxPath.substring(0, ncxPath.lastIndexOf('/'))
          : '';
      tocEntries = _parseNcx(entry(ncxPath), ncxDir);
    }
    if (tocEntries.isEmpty && navPath != null) {
      tocEntries = _parseNavDoc(entry(navPath), navPath);
    }
    // Last resort for books that never flag their nav document.
    if (tocEntries.isEmpty) {
      for (final p in manifest.values) {
        if (!_isHtmlPath(p)) continue;
        tocEntries = _parseNavDoc(entry(p), p, requireNav: true);
        if (tocEntries.isNotEmpty) break;
      }
    }

    // Group entries by target document, preserving reading order.
    final byFile = <String, List<TocEntry>>{};
    for (final e in tocEntries) {
      (byFile[e.fileKey] ??= <TocEntry>[]).add(e);
    }

    // Build archive entry lookup once (not per spine doc).
    final archiveContentMap = <String, Uint8List>{
      for (final e in entries.values)
        Uri.decodeComponent(e.name.toLowerCase()): e.content,
    };

    // Cover image hrefs, from both EPUB3 `properties="cover-image"` and the
    // EPUB2 `<meta name="cover" content="id">` convention.
    final coverHrefs = <String>{};
    for (final el in _els(opf, 'meta')) {
      if ((el.getAttribute('name') ?? '').toLowerCase() == 'cover') {
        final id = el.getAttribute('content');
        final href = id == null ? null : manifest[id];
        if (href != null) coverHrefs.add(href.toLowerCase());
      }
    }
    for (final el in _els(opf, 'item')) {
      final props = el.getAttribute('properties') ?? '';
      if (!props.split(RegExp(r'\s+')).contains('cover-image')) continue;
      final href = el.getAttribute('href');
      if (href != null) {
        coverHrefs.add(_resolveHref(opfDir, href).toLowerCase());
      }
    }

    // Read HTML and build DOMs once per chapter — shared between CSS parser
    // (selector matching) and regex parser (style run extraction).
    final chapterHtml = <String, String>{};
    final chapterDoms = <String, dom.Document>{};
    for (final p in docPaths) {
      final htmlBytes = entry(p);
      if (htmlBytes == null) continue;
      final xhtml = utf8.decode(htmlBytes, allowMalformed: true);
      chapterHtml[p] = xhtml;
      try {
        chapterDoms[_normalizeKey(p)] = html_parser.parse(xhtml);
      } catch (_) {}
    }

    // Parse CSS stylesheets and build resolved rules per chapter.
    // Pass pre-built DOMs to avoid duplicate HTML reads and DOM builds.
    final cssParser = EpubCssParser.parse(
      manifest: manifest,
      spinePaths: docPaths,
      readEntry: (name) => entry(name) ?? Uint8List(0),
      chapterDom: chapterDoms,
    );

    // Convert each spine document to one or more chapters. A document that
    // several TOC entries point into is split at their anchors, so every
    // entry becomes a chapter of its own.
    final chapters = <Chapter>[];
    for (final p in docPaths) {
      final xhtml = chapterHtml[p];
      if (xhtml == null) continue;
      final docDir = p.contains('/') ? p.substring(0, p.lastIndexOf('/')) : '';
      final (body, runs, anchors, images) = parseHtmlDocument(
        xhtml,
        archiveEntries: archiveContentMap,
        baseDir: docDir,
        manifestImageDims: manifestImageDims,
        coverHrefs: coverHrefs,
      );
      if (body.trim().isEmpty) continue;

      // Merge CSS-derived styles into the runs.
      final resolvedRules =
          cssParser.chapterStyles[_normalizeKey(p)] ?? const [];
      if (resolvedRules.isNotEmpty) {
        _mergeCssStyles(body, runs, resolvedRules);
        _mergeCssIntoImages(images, resolvedRules);
      }

      chapters.addAll(
        splitByAnchors(
          body,
          runs,
          anchors,
          byFile[_normalizeKey(p)] ?? const [],
          images,
        ),
      );
    }
    if (chapters.isEmpty) {
      throw const FormatException('EPUB contains no readable text');
    }

    return ParsedDocument(
      title: meta.title.isEmpty ? fallbackTitle : meta.title,
      author: meta.author,
      chapters: chapters,
      coverBytes: _extractCover(archive, entries, opf),
      description: meta.description,
      annotation: meta.annotation,
      genre: meta.genre,
      seriesName: meta.seriesName,
      seriesIndex: meta.seriesIndex,
      publisher: meta.publisher,
      isbn: meta.isbn,
      language: meta.language,
      publicationDate: meta.publicationDate,
      rights: meta.rights,
      type: meta.type,
      source: meta.source,
      titleSort: meta.titleSort,
      authorSort: meta.authorSort,
      fontFaces: cssParser.fontFaces,
    );
  }

  /// Parses the OPF `<metadata>` block into a [ParsedMetadata].
  ///
  /// Shared by the full parse path and the lightweight metadata path so the
  /// two can never disagree about how fields are extracted.
  static ParsedMetadata _parseOpfMetadata(XmlDocument opf) {
    var title = '';
    for (final el in _els(opf, 'title')) {
      final t = el.innerText.trim();
      if (t.isNotEmpty) {
        title = t;
        break;
      }
    }
    var author = '';
    for (final el in _els(opf, 'creator')) {
      final a = el.innerText.trim();
      if (a.isNotEmpty) {
        author = a;
        break;
      }
    }

    String? description;
    for (final el in _els(opf, 'description')) {
      final d = htmlToText(el.innerText.trim());
      if (d.isNotEmpty) {
        description = d;
        break;
      }
    }

    // Annotation: Calibre stores this in <meta name="calibre:annotation">.
    String? annotation;
    for (final el in _els(opf, 'meta')) {
      if ((el.getAttribute('name') ?? '') == 'calibre:annotation') {
        annotation = el.getAttribute('content')?.trim();
        break;
      }
    }

    String? language;
    for (final el in _els(opf, 'language')) {
      final l = el.innerText.trim();
      if (l.isNotEmpty) {
        language = l;
        break;
      }
    }

    String? publisher;
    for (final el in _els(opf, 'publisher')) {
      final p = el.innerText.trim();
      if (p.isNotEmpty) {
        publisher = p;
        break;
      }
    }

    // Genre: collect ALL dc:subject values and join with comma.
    final genres = <String>[];
    for (final el in _els(opf, 'subject')) {
      final s = el.innerText.trim();
      if (s.isNotEmpty) genres.add(s);
    }
    final genre = genres.isEmpty ? null : genres.join(', ');

    // ISBN: strip hyphens, prefer explicit scheme, handle ISBN-10 with X.
    String? isbn;
    for (final el in _els(opf, 'identifier')) {
      final scheme =
          (el.getAttribute('scheme') ?? el.getAttribute('opf:scheme') ?? '')
              .toLowerCase();
      final raw = el.innerText.trim();
      final v = raw.replaceAll('-', '');
      if (scheme == 'isbn') {
        isbn = raw;
        break;
      }
      if (isbn == null &&
          v.isNotEmpty &&
          RegExp(r'^\d{9}[\dXx]$').hasMatch(v)) {
        isbn = raw;
      }
    }

    // Series: Calibre convention <meta name="calibre:series" content="..."/>
    // or EPUB3 <meta property="belongs-to-series">.
    String? seriesName;
    double? seriesIndex;
    for (final el in _els(opf, 'meta')) {
      final name = el.getAttribute('name') ?? '';
      if (name == 'calibre:series') {
        seriesName = el.getAttribute('content')?.trim();
      } else if (name == 'calibre:series_index') {
        seriesIndex = double.tryParse(el.getAttribute('content')?.trim() ?? '');
      }
    }
    if (seriesName == null) {
      for (final el in _els(opf, 'meta')) {
        final prop = el.getAttribute('property') ?? '';
        if (prop == 'belongs-to-series') {
          seriesName = el.innerText.trim();
        } else if (prop == 'group-position') {
          seriesIndex ??= double.tryParse(el.innerText.trim());
        }
      }
    }

    String? publicationDate;
    for (final el in _els(opf, 'date')) {
      final d = el.innerText.trim();
      if (d.isNotEmpty) {
        publicationDate = d;
        break;
      }
    }

    String? rights;
    for (final el in _els(opf, 'rights')) {
      final r = el.innerText.trim();
      if (r.isNotEmpty) {
        rights = r;
        break;
      }
    }

    String? type;
    for (final el in _els(opf, 'type')) {
      final t = el.innerText.trim();
      if (t.isNotEmpty) {
        type = t;
        break;
      }
    }

    String? source;
    for (final el in _els(opf, 'source')) {
      final s = el.innerText.trim();
      if (s.isNotEmpty) {
        source = s;
        break;
      }
    }

    // Sort forms from opf:file-as attribute.
    String? titleSort;
    for (final el in _els(opf, 'title')) {
      final fa = el.getAttribute('opf:file-as')?.trim();
      if (fa != null && fa.isNotEmpty) {
        titleSort = fa;
        break;
      }
    }
    String? authorSort;
    for (final el in _els(opf, 'creator')) {
      final fa = el.getAttribute('opf:file-as')?.trim();
      if (fa != null && fa.isNotEmpty) {
        authorSort = fa;
        break;
      }
    }

    return ParsedMetadata(
      title: title,
      author: author,
      description: description,
      annotation: annotation,
      genre: genre,
      seriesName: seriesName,
      seriesIndex: seriesIndex,
      publisher: publisher,
      isbn: isbn,
      language: language,
      publicationDate: publicationDate,
      rights: rights,
      type: type,
      source: source,
      titleSort: titleSort,
      authorSort: authorSort,
    );
  }

  static Iterable<XmlElement> _els(XmlNode node, String local) =>
      node.descendantElements.where((e) => e.name.local == local);

  /// Cuts one spine document into a chapter per table-of-contents [entries].
  ///
  /// Many EPUBs hold several chapters in a single document and distinguish them
  /// only by `#anchor`. Splitting here — rather than one chapter per file — is
  /// what makes each entry addressable: pagination, the contents sheet and
  /// saved positions all key off the chapter list, so they need no changes.
  ///
  /// [runs] are rebased into each slice's coordinate space. Text before the
  /// first anchor becomes an untitled leading chapter, which the contents sheet
  /// hides but which still reads in sequence. Entries whose fragment is absent
  /// from the document are ignored; if none resolve, the document stays whole.
  @visibleForTesting
  static List<Chapter> splitByAnchors(
    String body,
    List<StyleRun> runs,
    Map<String, int> anchors,
    List<TocEntry> entries, [
    List<ImageRun> images = const [],
  ]) {
    // offset -> title, first entry wins when two anchors land together.
    final cuts = <int, String>{};
    for (final e in entries) {
      final offset = e.fragment == null
          ? 0
          : _anchorOffset(anchors, e.fragment!);
      if (offset == null) continue;
      cuts.putIfAbsent(offset.clamp(0, body.length), () => e.title);
    }

    if (cuts.isEmpty) {
      // No usable anchors: keep the document whole, titled by its first entry.
      return [
        Chapter(entries.isEmpty ? '' : entries.first.title, body, runs, images),
      ];
    }

    final offsets = cuts.keys.toList()..sort();
    if (offsets.first > 0) offsets.insert(0, 0);

    final out = <Chapter>[];
    for (var i = 0; i < offsets.length; i++) {
      final start = offsets[i];
      final end = i + 1 < offsets.length ? offsets[i + 1] : body.length;
      if (end <= start) continue;
      final slice = body.substring(start, end);
      if (slice.trim().isEmpty) continue;
      out.add(
        Chapter(
          cuts[start] ?? '',
          slice,
          _sliceRuns(runs, start, end),
          _sliceImages(images, start, end),
        ),
      );
    }
    return out.isEmpty
        ? [Chapter(entries.first.title, body, runs, images)]
        : out;
  }

  /// Clips [runs] to `[start, end)` and shifts them to slice-local offsets.
  static List<StyleRun> _sliceRuns(List<StyleRun> runs, int start, int end) {
    if (runs.isEmpty) return const [];
    final out = <StyleRun>[];
    for (final r in runs) {
      final s = math.max(r.start, start);
      final e = math.min(r.end, end);
      if (e <= s) continue;
      out.add(
        StyleRun(
          s - start,
          e - start,
          bold: r.bold,
          italic: r.italic,
          quote: r.quote,
        ),
      );
    }
    return out;
  }

  /// Clips [images] to `[start, end)` and shifts them to slice-local offsets.
  static List<ImageRun> _sliceImages(
    List<ImageRun> images,
    int start,
    int end,
  ) {
    if (images.isEmpty) return const [];
    final out = <ImageRun>[];
    for (final img in images) {
      if (img.offset >= start && img.offset < end) {
        out.add(
          ImageRun(
            offset: img.offset - start,
            bytes: img.bytes,
            intrinsicWidth: img.intrinsicWidth,
            intrinsicHeight: img.intrinsicHeight,
            alt: img.alt,
            fullWidth: img.fullWidth,
            sourceKey: img.sourceKey,
          ),
        );
      }
    }
    return out;
  }

  static String _normalizeKey(String path) =>
      Uri.decodeComponent(path).toLowerCase();

  /// Resolves [href] (possibly `../`-relative, percent-encoded, with
  /// fragment) against the OPF's directory inside the zip.
  static String _resolveHref(String baseDir, String href) {
    final clean = href.split('#').first.trim();
    final decoded = Uri.decodeComponent(clean);
    final parts = baseDir.isEmpty
        ? decoded.split('/')
        : '$baseDir/$decoded'.split('/');
    final out = <String>[];
    for (final part in parts) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        if (out.isNotEmpty) out.removeLast();
      } else {
        out.add(part);
      }
    }
    return out.join('/');
  }

  /// Splits [href] into its resolved document path and its fragment.
  static (String, String?) _splitHref(String baseDir, String href) {
    final hash = href.indexOf('#');
    final frag = hash >= 0 ? href.substring(hash + 1).trim() : '';
    String path;
    try {
      path = _resolveHref(baseDir, href);
    } catch (_) {
      // Malformed percent-escapes: fall back to the undecoded path.
      path = href.split('#').first.trim();
    }
    return (path, frag.isEmpty ? null : frag);
  }

  static bool _isHtmlPath(String p) {
    final l = p.toLowerCase();
    return l.endsWith('.xhtml') || l.endsWith('.html') || l.endsWith('.htm');
  }

  /// Looks up [fragment] among [anchors], tolerating percent-encoding
  /// differences between the TOC and the document itself.
  static int? _anchorOffset(Map<String, int> anchors, String fragment) {
    final direct = anchors[fragment];
    if (direct != null) return direct;
    try {
      final decoded = Uri.decodeComponent(fragment);
      final hit = anchors[decoded];
      if (hit != null) return hit;
    } catch (_) {
      // Not valid percent-encoding; nothing more to try.
    }
    return null;
  }

  /// EPUB2 TOC (toc.ncx): navPoint/navLabel/text + content/@src, flattened in
  /// document order so nested navPoints keep their reading sequence.
  static List<TocEntry> _parseNcx(Uint8List? data, String ncxDir) {
    final result = <TocEntry>[];
    final doc = data == null ? null : _safeParse(data);
    if (doc == null) return result;
    try {
      final seen = <String>{};
      for (final point in _els(doc, 'navPoint')) {
        final texts = _els(point, 'text');
        final label = texts.isNotEmpty ? texts.first.innerText.trim() : '';
        final src = _els(point, 'content').firstOrNull?.getAttribute('src');
        if (src == null || label.isEmpty) continue;
        final (file, fragment) = _splitHref(ncxDir, src);
        if (file.isEmpty) continue;
        final key = _normalizeKey(file);
        if (!seen.add('$key#${fragment ?? ''}')) continue;
        result.add(TocEntry(key, fragment, label));
      }
    } catch (_) {}
    return result;
  }

  /// EPUB3 TOC (xhtml with properties="nav"): anchors within the toc `<nav>`.
  ///
  /// When [requireNav] is set, documents without a real `<nav>` are rejected —
  /// that keeps a stray link in some other page from being mistaken for a TOC.
  static List<TocEntry> _parseNavDoc(
    Uint8List? data,
    String docPath, {
    bool requireNav = false,
  }) {
    final result = <TocEntry>[];
    final doc = data == null ? null : _safeParse(data);
    if (doc == null) return result;
    try {
      final navs = _els(doc, 'nav').toList();
      if (navs.isEmpty && requireNav) return result;
      // Prefer the nav flagged epub:type="toc"; fall back to the first nav.
      XmlElement? nav;
      for (final n in navs) {
        String? type;
        for (final a in n.attributes) {
          if (a.name.local == 'type') {
            type = a.value;
            break;
          }
        }
        if (type != null && type.split(RegExp(r'\s+')).contains('toc')) {
          nav = n;
          break;
        }
      }
      nav ??= navs.firstOrNull ?? doc.rootElement;
      final baseDir = docPath.contains('/')
          ? docPath.substring(0, docPath.lastIndexOf('/'))
          : '';
      final seen = <String>{};
      for (final a in _els(nav, 'a')) {
        final href = a.getAttribute('href');
        final label = a.innerText.trim();
        if (href == null || label.isEmpty) continue;
        final (file, fragment) = _splitHref(baseDir, href);
        if (file.isEmpty) continue;
        final key = _normalizeKey(file);
        if (!seen.add('$key#${fragment ?? ''}')) continue;
        result.add(TocEntry(key, fragment, label));
      }
    } catch (_) {}
    return result;
  }

  static XmlDocument? _safeParse(Uint8List data) {
    try {
      return XmlDocument.parse(utf8.decode(data, allowMalformed: true));
    } catch (_) {
      return null;
    }
  }

  /// Cover image bytes: OPF `<meta name="cover" content="id">` -> manifest
  /// item -> raw bytes. Falls back to any archive entry named like a cover.
  static List<int>? _extractCover(
    Archive archive,
    Map<String, ArchiveFile> entries,
    XmlDocument opf,
  ) {
    try {
      // EPUB3: the manifest item flagged properties="cover-image".
      for (final item in _els(opf, 'item')) {
        final props = item.getAttribute('properties') ?? '';
        if (!props.split(RegExp(r'\s+')).contains('cover-image')) continue;
        final href = item.getAttribute('href');
        if (href == null) continue;
        final bytes = entries[_resolveHrefForLookup(href)]?.content;
        if (bytes != null && bytes.isNotEmpty) return bytes;
      }
      for (final meta in _els(opf, 'meta')) {
        if (meta.getAttribute('name')?.toLowerCase() != 'cover') continue;
        final coverId = meta.getAttribute('content');
        for (final item in _els(opf, 'item')) {
          if (item.getAttribute('id') != coverId) continue;
          if (!(item.getAttribute('media-type') ?? '').startsWith('image/')) {
            continue;
          }
          final href = item.getAttribute('href');
          if (href == null) continue;
          final bytes = entries[_resolveHrefForLookup(href)]?.content;
          if (bytes != null && bytes.isNotEmpty) return bytes;
        }
      }
      // Fallback: any image entry whose name mentions "cover".
      const imageExt = {'.jpg', '.jpeg', '.png', '.webp', '.gif'};
      for (final f in archive.files) {
        final lower = f.name.toLowerCase();
        final dot = lower.lastIndexOf('.');
        if (dot < 0 || !imageExt.contains(lower.substring(dot))) continue;
        if (lower.contains('cover')) return f.content;
      }
    } catch (_) {
      // Malformed metadata should never block an import.
    }
    return null;
  }

  /// Cover hrefs live in the same directory space as the OPF itself.
  static String _resolveHrefForLookup(String href) {
    final clean = Uri.decodeComponent(href.split('#').first.trim());
    final parts = clean.split('/');
    final out = <String>[];
    for (final part in parts) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        if (out.isNotEmpty) out.removeLast();
      } else {
        out.add(part);
      }
    }
    return out.join('/');
  }

  // --------------------------------------------------------------------------
  // TXT
  // --------------------------------------------------------------------------

  static Future<ParsedDocument> _parseTxt(String path) async {
    final file = File(path);
    final length = await file.length();
    if (length > 100 * 1024 * 1024) {
      throw const FormatException('Text file too large (limit 100 MB)');
    }
    final bytes = await file.readAsBytes();
    var text = utf8.decode(bytes, allowMalformed: true);
    // If malformed replacement chars dominate, retry as Latin-1.
    if ('\uFFFD'.allMatches(text).length > text.length / 64) {
      text = latin1.decode(bytes, allowInvalid: true);
    }
    if (text.trim().isEmpty) throw const FormatException('File is empty');
    final chapters = chapterizeTxt(text);
    return ParsedDocument(
      title: _titleFromFilename(path),
      author: '',
      chapters: chapters,
    );
  }

  // --------------------------------------------------------------------------
  // CBR / CBZ: comic book archives (images as pages)
  // --------------------------------------------------------------------------

  static const _imageExtensions = {
    '.jpg',
    '.jpeg',
    '.png',
    '.gif',
    '.webp',
    '.bmp',
  };

  static Future<ParsedDocument> _parseComicBook(String path) async {
    final format = formatFromExtension(path);
    List<String> entryNames;
    Uint8List Function(String entryName) readEntry;
    Directory? cbrTempDir;

    try {
      if (format == BookFormat.cbz) {
        final Uint8List bytes;
        try {
          bytes = await File(path).readAsBytes();
        } catch (_) {
          throw const FormatException('Not a valid CBZ file');
        }
        final Archive archive;
        try {
          archive = ZipDecoder().decodeBytes(bytes);
        } catch (_) {
          throw const FormatException('Not a valid CBZ/ZIP archive');
        }
        entryNames = archive.files
            .where((f) => f.isFile && _isImage(f.name))
            .map((f) => f.name)
            .toList();
        readEntry = (name) {
          final file = archive.files.firstWhere((f) => f.name == name);
          return Uint8List.fromList(file.content as List<int>);
        };
      } else {
        // CBR: use rar package (libarchive) to list and extract entries.
        final List<dynamic> allFiles;
        try {
          final listResult = await Rar.listRarContents(rarFilePath: path);
          if (listResult['success'] != true) {
            throw const FormatException('Not a valid CBR/RAR archive');
          }
          allFiles = listResult['files'] as List<dynamic>;
        } catch (e) {
          if (e is FormatException) rethrow;
          throw const FormatException('Not a valid CBR/RAR archive');
        }
        entryNames = allFiles
            .map((f) => f.toString())
            .where((f) => _isImage(f))
            .toList();

        // Extract all to temp dir, then read images from disk.
        // TODO: Consider lazy per-entry extraction if Rar library supports it,
        // to avoid holding all decompressed images on disk simultaneously.
        try {
          cbrTempDir = await Directory.systemTemp.createTemp('cbr_');
          final extractResult = await Rar.extractRarFile(
            rarFilePath: path,
            destinationPath: cbrTempDir.path,
          );
          if (extractResult['success'] != true) {
            throw const FormatException('Failed to extract CBR archive');
          }

          final tempDir = cbrTempDir;
          readEntry = (name) {
            final file = _findExtractedFile(tempDir, name);
            if (file == null) {
              throw FormatException('Entry not found: $name');
            }
            return Uint8List.fromList(file.readAsBytesSync());
          };
        } catch (e) {
          cbrTempDir?.deleteSync(recursive: true);
          cbrTempDir = null;
          if (e is FormatException) rethrow;
          throw const FormatException('Not a valid CBR/RAR archive');
        }
      }

      // Natural sort: "2.jpg" before "10.jpg".
      entryNames.sort(_naturalCompare);

      if (entryNames.isEmpty) {
        throw const FormatException('No images found in comic archive');
      }

      // Each image becomes a chapter with a single full-page ImageRun.
      final chapters = <Chapter>[];
      for (var i = 0; i < entryNames.length; i++) {
        final imageBytes = readEntry(entryNames[i]);
        // Read dimensions from image headers (fast, no full decode).
        final (width, height) = _RichTextBuilder._decodeImageDimensions(
          imageBytes,
        );
        final pageName = _filenameWithoutExtension(entryNames[i]);
        // Body contains a single \uFFFC placeholder for the image.
        chapters.add(
          Chapter(
            pageName.isNotEmpty ? pageName : 'Page ${i + 1}',
            '\uFFFC',
            const [],
            [
              ImageRun(
                offset: 0,
                bytes: imageBytes,
                intrinsicWidth: width,
                intrinsicHeight: height,
                fullWidth: true,
              ),
            ],
          ),
        );
      }

      // First image as cover.
      final coverBytes = readEntry(entryNames.first);

      return ParsedDocument(
        title: _titleFromFilename(path),
        author: '',
        chapters: chapters,
        coverBytes: coverBytes,
      );
    } finally {
      cbrTempDir?.deleteSync(recursive: true);
    }
  }

  static bool _isImage(String name) {
    final lower = name.toLowerCase();
    for (final ext in _imageExtensions) {
      if (lower.endsWith(ext)) return true;
    }
    return false;
  }

  static String _filenameWithoutExtension(String path) {
    final name = path.split('/').last;
    final dotIndex = name.lastIndexOf('.');
    return dotIndex > 0 ? name.substring(0, dotIndex) : name;
  }

  /// Recursively finds a file by name inside [dir], tolerating subdirectory
  /// paths from the RAR archive's internal structure.
  static File? _findExtractedFile(Directory dir, String name) {
    // Try flat path first (most comics have no subdirectories).
    final flat = File('${dir.path}/$name');
    if (flat.existsSync()) return flat;
    // Recursive fallback.
    for (final f in dir.listSync(recursive: true)) {
      if (f is File && f.path.endsWith('/$name')) return f;
    }
    return null;
  }

  /// Natural sort comparator for filenames (handles numeric ordering).
  static int _naturalCompare(String a, String b) {
    return _naturalCompareImpl(a.toLowerCase(), b.toLowerCase());
  }

  static int _naturalCompareImpl(String a, String b) {
    final aRunes = a.runes.toList();
    final bRunes = b.runes.toList();
    var ia = 0;
    var ib = 0;
    while (ia < aRunes.length && ib < bRunes.length) {
      final ca = aRunes[ia];
      final cb = bRunes[ib];
      if (ca >= 0x30 && ca <= 0x39 && cb >= 0x30 && cb <= 0x39) {
        // Both digits: compare numeric run.
        var numA = 0;
        var numB = 0;
        while (ia < aRunes.length && aRunes[ia] >= 0x30 && aRunes[ia] <= 0x39) {
          numA = numA * 10 + (aRunes[ia] - 0x30);
          ia++;
        }
        while (ib < bRunes.length && bRunes[ib] >= 0x30 && bRunes[ib] <= 0x39) {
          numB = numB * 10 + (bRunes[ib] - 0x30);
          ib++;
        }
        if (numA != numB) return numA.compareTo(numB);
      } else {
        if (ca != cb) return ca.compareTo(cb);
        ia++;
        ib++;
      }
    }
    return aRunes.length.compareTo(bRunes.length);
  }

  /// Splits plain text into chapters using heading patterns and blank-line runs.
  static List<Chapter> chapterizeTxt(String text) {
    // Regex for explicit chapter headings at line start:
    // "Chapter 1", "Chapter 12:", "PART I", "PART 12", etc.
    final headingRe = RegExp(
      r'^(?:Chapter|Ch(?:apter)?\.?)\s+\d+'
      r'|^PART\s+[IVX\d]+',
      caseSensitive: false,
      multiLine: true,
    );

    // Find all heading positions.
    final headings = <MapEntry<int, String>>[];
    for (final match in headingRe.allMatches(text)) {
      headings.add(MapEntry(match.start, match.group(0)!.trim()));
    }

    // Find blank-line run positions (3+ consecutive blank lines).
    final blankRunRe = RegExp(r'\n\s*\n\s*\n[ \t]*\n*');
    final blankRuns = <int>[];
    for (final match in blankRunRe.allMatches(text)) {
      blankRuns.add(match.start);
    }

    // Merge split points from headings and blank-line runs, sorted.
    final splitPoints = <int>{};
    for (final h in headings) {
      // Find the start of the line containing the heading.
      var lineStart = h.key;
      while (lineStart > 0 && text[lineStart - 1] != '\n') {
        lineStart--;
      }
      splitPoints.add(lineStart);
    }
    for (final bp in blankRuns) {
      // Split after the blank run (at the first non-blank content).
      final afterBlank = bp + blankRunRe.firstMatch(text.substring(bp))!.end;
      if (afterBlank < text.length) {
        splitPoints.add(afterBlank);
      }
    }

    // If no splits found, return single chapter.
    if (splitPoints.isEmpty) {
      return [Chapter('', text)];
    }

    final sorted = splitPoints.toList()..sort();
    final chapters = <Chapter>[];
    var start = 0;

    for (final splitAt in sorted) {
      if (splitAt <= start) continue;
      final chunk = text.substring(start, splitAt).trimRight();
      if (chunk.trim().isNotEmpty) {
        // Determine title: use the heading line if this chunk starts with one.
        final firstLineEnd = chunk.indexOf('\n');
        final firstLine =
            (firstLineEnd >= 0 ? chunk.substring(0, firstLineEnd) : chunk)
                .trim();
        final title = headingRe.hasMatch(firstLine) ? firstLine : '';
        chapters.add(Chapter(title, chunk));
      }
      start = splitAt;
    }

    // Final chunk after last split point.
    if (start < text.length) {
      final chunk = text.substring(start).trim();
      if (chunk.isNotEmpty) {
        final firstLineEnd = chunk.indexOf('\n');
        final firstLine =
            (firstLineEnd >= 0 ? chunk.substring(0, firstLineEnd) : chunk)
                .trim();
        final title = headingRe.hasMatch(firstLine) ? firstLine : '';
        chapters.add(Chapter(title, chunk));
      }
    }

    return chapters.isEmpty ? [Chapter('', text)] : chapters;
  }

  // --------------------------------------------------------------------------
  // Helpers
  // --------------------------------------------------------------------------

  static String _titleFromFilename(String path) {
    final base = path.split(Platform.pathSeparator).last;
    final dot = base.lastIndexOf('.');
    return cleanBookTitle(dot > 0 ? base.substring(0, dot) : base);
  }

  static final RegExp _blockTagRe = RegExp(
    r'</?(p|div|h[1-6]|li|tr|br|section|article|blockquote)\b[^>]*>',
    caseSensitive: false,
  );

  static final RegExp _entityRe = RegExp(
    r'&(amp|lt|gt|quot|apos|nbsp|mdash|ndash|hellip|lsquo|rsquo|ldquo|rdquo|#\d+|#x[0-9a-fA-F]+);',
  );

  /// Markup that carries no reading content. Dropping `<head>` also drops the
  /// document `<title>`, which would otherwise be prepended to every chapter;
  /// `<style>`/`<script>` bodies survive tag stripping as raw CSS/JS text, so
  /// they have to go as whole elements. An unclosed element simply doesn't
  /// match, leaving the markup untouched.
  static final RegExp _nonContentRe = RegExp(
    r'<!--.*?-->'
    r'|<head\b[^>]*>.*?</head\s*>'
    r'|<style\b[^>]*>.*?</style\s*>'
    r'|<script\b[^>]*>.*?</script\s*>',
    dotAll: true,
    caseSensitive: false,
  );

  static String _stripNonContent(String html) =>
      html.replaceAll(_nonContentRe, '');

  /// Minimal HTML-to-text conversion: block tags become newlines, remaining
  /// tags are stripped, common entities decoded, whitespace collapsed.
  static String htmlToText(String html) {
    var s = _stripNonContent(html);
    s = s.replaceAllMapped(_blockTagRe, (_) => '\n');
    s = s.replaceAll(RegExp(r'<[^>]*>'), '');
    s = _decodeEntities(s);
    s = s.replaceAll(RegExp(r'[ \t\r\f\v]+'), ' ');
    s = s.replaceAll(RegExp(r'\n[ \t]+'), '\n');
    s = s.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return s.trim();
  }

  /// Like [htmlToText] but also extracts styled ranges (bold, italic,
  /// blockquote) over the produced text. The plain-text output matches
  /// [htmlToText], so both share one coordinate space.
  static (String, List<StyleRun>) htmlToRichText(String html) {
    final (text, runs, _, noImages) = parseHtmlDocument(html);
    return (text, runs);
  }

  /// Converts [html] to plain text plus style runs, and records where each
  /// `id`/`<a name>` anchor lands in that text.
  ///
  /// Anchor offsets point at the first visible character following the anchor,
  /// so they are valid chapter-split positions: slicing the text there never
  /// cuts a word, and every offset shares the coordinate space used by both
  /// pagination and rich rendering.
  @visibleForTesting
  static (String, List<StyleRun>, Map<String, int>, List<ImageRun>)
  parseHtmlDocument(
    String html, {
    Map<String, Uint8List>? archiveEntries,
    String baseDir = '',
    Map<String, (double, double)>? manifestImageDims,
    Set<String> coverHrefs = const {},
  }) {
    final builder = _RichTextBuilder(
      archiveEntries: archiveEntries,
      baseDir: baseDir,
      manifestImageDims: manifestImageDims,
      coverHrefs: coverHrefs,
    );
    final cleaned = _stripNonContent(html);
    var cursor = 0;
    for (final m in _tagRe.allMatches(cleaned)) {
      builder.text(cleaned.substring(cursor, m.start));
      _handleTag(builder, m.group(0)!);
      cursor = m.end;
    }
    builder.text(cleaned.substring(cursor));
    return builder.finish();
  }

  static final RegExp _tagRe = RegExp(r'<[^>]*>');

  // Attribute readers. The leading `\s` keeps `data-id`/`xml:id` from matching
  // as a bare `id`, since a tag always separates attributes with whitespace.
  static final RegExp _idAttrRe = RegExp(
    r'''\sid\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>/]+))''',
    caseSensitive: false,
  );
  static final RegExp _nameAttrRe = RegExp(
    r'''\sname\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>/]+))''',
    caseSensitive: false,
  );
  static final RegExp _srcAttrRe = RegExp(
    r'''\ssrc\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>/]+))''',
    caseSensitive: false,
  );
  static final RegExp _altAttrRe = RegExp(
    r'''\salt\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>/]+))''',
    caseSensitive: false,
  );
  // SVG images use `href`/`xlink:href` instead of `src`.
  static final RegExp _hrefAttrRe = RegExp(
    r'''\s(?:xlink:)?href\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>/]+))''',
    caseSensitive: false,
  );
  static final RegExp _srcsetAttrRe = RegExp(
    r'''\ssrcset\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>/]+))''',
    caseSensitive: false,
  );

  /// First candidate URL from a `srcset` list (`"a.jpg 1x, b.jpg 2x"`).
  static String? _firstSrcset(String? srcset) {
    if (srcset == null || srcset.isEmpty) return null;
    final first = srcset.split(',').first.trim();
    if (first.isEmpty) return null;
    return first.split(RegExp(r'\s+')).first;
  }

  static String? _attr(RegExp re, String raw) {
    final m = re.firstMatch(raw);
    if (m == null) return null;
    final v = m.group(1) ?? m.group(2) ?? m.group(3);
    return (v == null || v.isEmpty) ? null : v;
  }

  static const _blockTagNames = {
    'p',
    'div',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'li',
    'tr',
    'br',
    'section',
    'article',
    'blockquote',
  };

  static void _handleTag(_RichTextBuilder b, String raw) {
    final m = RegExp(r'^<\s*(/?)\s*([a-zA-Z][a-zA-Z0-9]*)').firstMatch(raw);
    if (m == null) return;
    final closing = m.group(1) == '/';
    final name = (m.group(2)!).toLowerCase();

    // Anchor targets: `id` on any element, plus legacy `<a name="...">`.
    if (!closing) {
      final id = _attr(_idAttrRe, raw);
      if (id != null) b.anchor(id);
      if (name == 'a') {
        final legacy = _attr(_nameAttrRe, raw);
        if (legacy != null) b.anchor(legacy);
      }
    }

    if (name == 'b' || name == 'strong' || name == 'i' || name == 'em') {
      // Whitespace straddling the tag boundary belongs to the outer style,
      // so flush it before the depth changes.
      b.flushSpace();
    }
    switch (name) {
      case 'b' || 'strong':
        b.boldDepth = math.max(0, b.boldDepth + (closing ? -1 : 1));
      case 'i' || 'em':
        b.italicDepth = math.max(0, b.italicDepth + (closing ? -1 : 1));
      case 'blockquote':
        b.newline();
        b.quoteDepth = math.max(0, b.quoteDepth + (closing ? -1 : 1));
      case 'img' || 'image':
        if (!closing) {
          final htmlWidth = _attr(
            RegExp(r'\bwidth\s*=\s*"([^"]*)"', caseSensitive: false),
            raw,
          );
          final htmlHeight = _attr(
            RegExp(r'\bheight\s*=\s*"([^"]*)"', caseSensitive: false),
            raw,
          );
          // SVG `<image>` carries its target in href/xlink:href; `<img>` uses
          // src, falling back to the first srcset candidate.
          final src = name == 'image'
              ? _attr(_hrefAttrRe, raw)
              : (_attr(_srcAttrRe, raw) ??
                    _firstSrcset(_attr(_srcsetAttrRe, raw)));
          b.image(
            src,
            _attr(_altAttrRe, raw),
            id: _attr(_idAttrRe, raw),
            elementId: _attr(_idAttrRe, raw) ?? '',
            htmlWidth: htmlWidth != null ? double.tryParse(htmlWidth) : null,
            htmlHeight: htmlHeight != null ? double.tryParse(htmlHeight) : null,
          );
        }
      default:
        if (_blockTagNames.contains(name)) {
          b.newline();
        }
    }
  }

  static String _decodeEntities(String input) {
    const named = {
      'amp': '&',
      'lt': '<',
      'gt': '>',
      'quot': '"',
      'apos': "'",
      'nbsp': ' ',
      'mdash': '\u2014',
      'ndash': '\u2013',
      'hellip': '\u2026',
      'lsquo': '\u2018',
      'rsquo': '\u2019',
      'ldquo': '\u201C',
      'rdquo': '\u201D',
    };
    return input.replaceAllMapped(_entityRe, (m) {
      final e = m.group(1)!;
      if (e.startsWith('#x')) {
        return String.fromCharCode(int.parse(e.substring(2), radix: 16));
      }
      if (e.startsWith('#')) {
        return String.fromCharCode(int.parse(e.substring(1)));
      }
      return named[e] ?? m.group(0)!;
    });
  }

  // --- Public utilities used by ComicPageProvider ---

  static bool isImageEntry(String name) => _isImage(name);
  static int naturalCompare(String a, String b) => _naturalCompare(a, b);
  static (int, int) decodeImageDimensions(Uint8List bytes) =>
      _RichTextBuilder._decodeImageDimensions(bytes);

  static void _mergeCssStyles(
    String body,
    List<StyleRun> runs,
    List<ResolvedCssRule> rules,
  ) {
    if (rules.isEmpty || runs.isEmpty) return;

    for (final rule in rules) {
      final element = rule.element;
      final properties = rule.properties;

      // Find the element's text range in the body by matching its plain text.
      final elementText = element.text;
      if (elementText.isEmpty) continue;

      final bodyStart = body.indexOf(elementText);
      if (bodyStart < 0) continue;
      final bodyEnd = bodyStart + elementText.length;

      // Find all runs that overlap this element's text range.
      for (var i = 0; i < runs.length; i++) {
        final run = runs[i];
        final overlapStart = math.max(run.start, bodyStart);
        final overlapEnd = math.min(run.end, bodyEnd);
        if (overlapStart >= overlapEnd) continue;

        // Build a CssStyle from the matched rule's properties.
        final css = EpubCssParser.propsToCssStyle(properties);
        if (css.isEmpty) continue;

        // If the run exactly matches the element range, apply directly.
        if (run.start == bodyStart && run.end == bodyEnd) {
          runs[i] = StyleRun(
            run.start,
            run.end,
            bold: run.bold,
            italic: run.italic,
            quote: run.quote,
            css: run.css?.merge(css) ?? css,
          );
        } else {
          // Split: before / during / after the element range.
          final before = StyleRun(
            run.start,
            overlapStart,
            bold: run.bold,
            italic: run.italic,
            quote: run.quote,
            css: run.css,
          );
          final during = StyleRun(
            overlapStart,
            overlapEnd,
            bold: run.bold,
            italic: run.italic,
            quote: run.quote,
            css: run.css?.merge(css) ?? css,
          );
          final after = StyleRun(
            overlapEnd,
            run.end,
            bold: run.bold,
            italic: run.italic,
            quote: run.quote,
            css: run.css,
          );

          runs.removeAt(i);
          if (before.start < before.end) runs.insert(i++, before);
          runs.insert(i, during);
          if (after.start < after.end) runs.insert(i + 1, after);
        }
      }
    }
  }

  /// Merges CSS-derived image-sizing rules into [images] by matching
  /// resolved rules whose element is an `<img>` tag with a matching `id`.
  static void _mergeCssIntoImages(
    List<ImageRun> images,
    List<ResolvedCssRule> rules,
  ) {
    if (rules.isEmpty || images.isEmpty) return;

    for (final rule in rules) {
      final element = rule.element;
      if (element.localName != 'img') continue;

      final props = rule.properties;
      final hasImageProps =
          props.containsKey('width') ||
          props.containsKey('height') ||
          props.containsKey('max-width') ||
          props.containsKey('max-height');
      if (!hasImageProps) continue;

      final css = EpubCssParser.propsToCssStyle(props);
      if (css.width == null &&
          css.height == null &&
          css.maxWidth == null &&
          css.maxHeight == null) {
        continue;
      }

      final imgId = element.id;
      for (var i = 0; i < images.length; i++) {
        if (images[i].elementId == imgId && imgId.isNotEmpty) {
          final existing = images[i].css;
          images[i] = ImageRun(
            offset: images[i].offset,
            bytes: images[i].bytes,
            intrinsicWidth: images[i].intrinsicWidth,
            intrinsicHeight: images[i].intrinsicHeight,
            alt: images[i].alt,
            fullWidth: images[i].fullWidth,
            onTap: images[i].onTap,
            css: existing?.merge(css) ?? css,
            elementId: images[i].elementId,
            htmlWidth: images[i].htmlWidth,
            htmlHeight: images[i].htmlHeight,
            sourceKey: images[i].sourceKey,
          );
          break;
        }
      }
    }
  }

  // --------------------------------------------------------------------------
  // Disk cache for parsed documents.
  // --------------------------------------------------------------------------

  /// Resolves (and creates) the cache directory, or throws when the platform
  /// directory is unavailable. Must be called on the main isolate.
  static Future<String> _resolveCacheDirPath() async {
    final tmp = await getTemporaryDirectory();
    final dir = Directory('${tmp.path}/burrow_doc_cache');
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir.path;
  }

  /// Main-isolate-safe resolver used by [parse]: returns null when the cache
  /// directory cannot be resolved (e.g. the platform channel is unavailable).
  static Future<String?> _safeCacheDirPath() async {
    try {
      return await _resolveCacheDirPath();
    } catch (_) {
      return null;
    }
  }

  static String _cacheKey(String path) {
    final file = File(path);
    final mtime = file.lastModifiedSync().millisecondsSinceEpoch;
    final size = file.lengthSync();
    // Bump the schema tag when the cached shape changes so stale entries from
    // an older format are ignored instead of deserialized with missing fields.
    // v3: images/fonts store archive entry names instead of base64 bytes.
    final id = 'v3_${path}_${mtime}_$size';
    return id.hashCode.toRadixString(16);
  }

  static Future<ParsedDocument?> _loadFromCache(
    String path,
    String cacheDirPath,
  ) async {
    try {
      final key = _cacheKey(path);
      final cacheFile = File('$cacheDirPath/$key.json');
      if (!cacheFile.existsSync()) return null;
      final json =
          jsonDecode(await cacheFile.readAsString()) as Map<String, dynamic>;
      return _docFromJson(json);
    } catch (_) {
      return null;
    }
  }

  static Future<void> _saveToCache(
    String path,
    ParsedDocument doc,
    String cacheDirPath,
  ) async {
    try {
      final key = _cacheKey(path);
      final cacheFile = File('$cacheDirPath/$key.json');
      await cacheFile.writeAsString(jsonEncode(_docToJson(doc)));
    } catch (_) {}
  }

  static Map<String, dynamic> _docToJson(ParsedDocument doc) {
    return {
      'title': doc.title,
      'author': doc.author,
      'description': doc.description,
      'annotation': doc.annotation,
      'genre': doc.genre,
      'seriesName': doc.seriesName,
      'seriesIndex': doc.seriesIndex,
      'publisher': doc.publisher,
      'isbn': doc.isbn,
      'language': doc.language,
      'publicationDate': doc.publicationDate,
      'rights': doc.rights,
      'type': doc.type,
      'source': doc.source,
      'titleSort': doc.titleSort,
      'authorSort': doc.authorSort,
      'chapters': doc.chapters
          .map(
            (c) => {
              'title': c.title,
              'body': c.body,
              'runs': c.runs
                  .map(
                    (r) => {
                      's': r.start,
                      'e': r.end,
                      'b': r.bold,
                      'i': r.italic,
                      'q': r.quote,
                      if (r.css != null) 'css': r.css!.toJson(),
                    },
                  )
                  .toList(),
              'images': c.images
                  .map(
                    (img) => {
                      'o': img.offset,
                      // Store the source archive entry when known; the bytes
                      // are re-read from the EPUB on cache load. Only fall
                      // back to inlining base64 when there is no source key.
                      if (img.sourceKey != null)
                        'k': img.sourceKey
                      else
                        'b': base64Encode(img.bytes),
                      'w': img.intrinsicWidth,
                      'h': img.intrinsicHeight,
                      'a': img.alt,
                      'f': img.fullWidth,
                      'eid': img.elementId,
                      'hw': img.htmlWidth,
                      'hh': img.htmlHeight,
                      if (img.css != null) 'css': img.css!.toJson(),
                    },
                  )
                  .toList(),
            },
          )
          .toList(),
      'fontFaces': {
        // Font bytes are re-read from the EPUB on load; only the resolved
        // archive-relative src is cached.
        for (final e in doc.fontFaces.entries) e.key: {'src': e.value.src},
      },
    };
  }

  static ParsedDocument _docFromJson(Map<String, dynamic> json) {
    final chapters = (json['chapters'] as List).map((c) {
      final ch = c as Map<String, dynamic>;
      final runs = (ch['runs'] as List? ?? []).map((r) {
        final rm = r as Map<String, dynamic>;
        return StyleRun(
          rm['s'] as int,
          rm['e'] as int,
          bold: rm['b'] as bool? ?? false,
          italic: rm['i'] as bool? ?? false,
          quote: rm['q'] as bool? ?? false,
          css: rm['css'] is Map
              ? CssStyle.fromJson((rm['css'] as Map).cast<String, dynamic>())
              : null,
        );
      }).toList();
      final images = (ch['images'] as List? ?? []).map((img) {
        final im = img as Map<String, dynamic>;
        final encoded = im['b'] as String?;
        return ImageRun(
          offset: im['o'] as int,
          bytes: encoded == null ? Uint8List(0) : base64Decode(encoded),
          intrinsicWidth: im['w'] as int,
          intrinsicHeight: im['h'] as int,
          alt: im['a'] as String? ?? '',
          fullWidth: im['f'] as bool? ?? false,
          elementId: im['eid'] as String? ?? '',
          htmlWidth: (im['hw'] as num?)?.toDouble(),
          htmlHeight: (im['hh'] as num?)?.toDouble(),
          sourceKey: im['k'] as String?,
          css: im['css'] is Map
              ? CssStyle.fromJson((im['css'] as Map).cast<String, dynamic>())
              : null,
        );
      }).toList();
      return Chapter(ch['title'] as String, ch['body'] as String, runs, images);
    }).toList();
    final rawFonts = json['fontFaces'];
    final fontFaces = <String, FontFaceInfo>{};
    if (rawFonts is Map) {
      for (final entry in rawFonts.entries) {
        final info = (entry.value as Map).cast<String, dynamic>();
        final encoded = info['bytes'] as String?;
        fontFaces['${entry.key}'] = FontFaceInfo(
          family: '${entry.key}',
          src: info['src'] as String? ?? '',
          bytes: encoded == null ? null : base64Decode(encoded),
        );
      }
    }
    return ParsedDocument(
      title: json['title'] as String? ?? '',
      author: json['author'] as String? ?? '',
      chapters: chapters,
      description: json['description'] as String?,
      annotation: json['annotation'] as String?,
      genre: json['genre'] as String?,
      seriesName: json['seriesName'] as String?,
      seriesIndex: (json['seriesIndex'] as num?)?.toDouble(),
      publisher: json['publisher'] as String?,
      isbn: json['isbn'] as String?,
      language: json['language'] as String?,
      publicationDate: json['publicationDate'] as String?,
      rights: json['rights'] as String?,
      type: json['type'] as String?,
      source: json['source'] as String?,
      titleSort: json['titleSort'] as String?,
      authorSort: json['authorSort'] as String?,
      fontFaces: fontFaces,
    );
  }

  /// Deletes the cache entry for [path], if one exists.
  static Future<void> clearCacheFor(String path) async {
    final dirPath = await _safeCacheDirPath();
    if (dirPath != null) _deleteCacheFile(path, dirPath);
  }

  static void _deleteCacheFile(String path, String cacheDirPath) {
    try {
      final key = _cacheKey(path);
      final file = File('$cacheDirPath/$key.json');
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
  }

  /// Deletes cache entries that no longer correspond to any of [paths], then
  /// trims the cache to [maxBytes] by removing the least recently modified
  /// files. This also sweeps entries from earlier cache schema versions.
  ///
  /// The sweep runs in a background isolate so a large cache never janks the
  /// UI thread at startup.
  static Future<void> pruneCache(
    Iterable<String> paths, {
    int maxBytes = 256 * 1024 * 1024,
  }) async {
    if (_pruneRunning) return;
    final dirPath = await _safeCacheDirPath();
    if (dirPath == null) return;
    _pruneRunning = true;
    try {
      await compute(_pruneCacheIsolate, (
        dirPath,
        [for (final p in paths) p],
        maxBytes,
      ));
    } catch (_) {
    } finally {
      _pruneRunning = false;
    }
  }

  static bool _pruneRunning = false;

  static void _pruneCacheIsolate((String, List<String>, int) args) {
    final (dirPath, paths, maxBytes) = args;
    try {
      final dir = Directory(dirPath);
      if (!dir.existsSync()) return;
      final valid = <String>{};
      for (final p in paths) {
        try {
          valid.add(_cacheKey(p));
        } catch (_) {}
      }

      final files = <File>[];
      var total = 0;
      for (final entity in dir.listSync()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        final base = name.endsWith('.json')
            ? name.substring(0, name.length - '.json'.length)
            : name;
        if (!valid.contains(base)) {
          try {
            entity.deleteSync();
          } catch (_) {}
          continue;
        }
        files.add(entity);
        total += entity.lengthSync();
      }

      if (total > maxBytes && files.isNotEmpty) {
        files.sort(
          (a, b) => a.statSync().modified.compareTo(b.statSync().modified),
        );
        for (final f in files) {
          if (total <= maxBytes) break;
          final size = f.lengthSync();
          try {
            f.deleteSync();
            total -= size;
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  /// Returns a copy of [doc] with image/font bytes re-read from the source
  /// EPUB, or null when the source is missing/unreadable or a referenced image
  /// entry is gone (the caller then falls back to a full parse).
  static ParsedDocument? _hydrateAssets(ParsedDocument doc, String path) {
    if (!_docNeedsHydration(doc)) return doc;
    final file = File(path);
    if (!file.existsSync()) return null;

    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(file.readAsBytesSync());
    } catch (_) {
      return null;
    }
    final entries = <String, ArchiveFile>{
      for (final f in archive.files)
        Uri.decodeComponent(f.name.toLowerCase()): f,
    };
    Uint8List? read(String key) {
      final entry = entries[key.toLowerCase()];
      if (entry == null) return null;
      final bytes = entry.content;
      return bytes.isEmpty ? null : bytes;
    }

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
        final bytes = read(img.sourceKey!);
        if (bytes == null) return null;
        images.add(img.copyWith(bytes: bytes));
      }
      chapters.add(Chapter(ch.title, ch.body, ch.runs, images));
    }

    final fontFaces = <String, FontFaceInfo>{};
    for (final e in doc.fontFaces.entries) {
      final info = e.value;
      if (info.bytes != null || info.src.isEmpty) {
        fontFaces[e.key] = info;
        continue;
      }
      fontFaces[e.key] = FontFaceInfo(
        family: info.family,
        src: info.src,
        bytes: read(info.src),
      );
    }

    return ParsedDocument(
      title: doc.title,
      author: doc.author,
      chapters: chapters,
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
      fontFaces: fontFaces,
    );
  }

  static bool _docNeedsHydration(ParsedDocument doc) {
    for (final ch in doc.chapters) {
      for (final img in ch.images) {
        if (img.bytes.isEmpty && img.sourceKey != null) return true;
      }
    }
    for (final info in doc.fontFaces.values) {
      if (info.bytes == null && info.src.isNotEmpty) return true;
    }
    return false;
  }
}

/// Incrementally builds plain text plus style runs from HTML events.
///
/// Whitespace rules mirror [DocumentParser.htmlToText]: horizontal whitespace
/// collapses to one space, spaces around line breaks are dropped, runs of
/// newlines collapse to at most two, and the result is left- and right-trimmed.
class _RichTextBuilder {
  _RichTextBuilder({
    this.archiveEntries,
    this.baseDir = '',
    this.manifestImageDims,
    this.coverHrefs = const {},
  });

  /// Optional EPUB zip entries for resolving image src paths.
  final Map<String, Uint8List>? archiveEntries;
  final String baseDir;

  /// OPF manifest image dimensions (href -> (width, height)), used as fallback.
  final Map<String, (double, double)>? manifestImageDims;

  /// Normalized hrefs the OPF flags as the cover image.
  final Set<String> coverHrefs;

  final StringBuffer _buf = StringBuffer();
  final List<StyleRun> _runs = [];
  final List<ImageRun> _images = [];
  int boldDepth = 0;
  int italicDepth = 0;
  int quoteDepth = 0;
  final Map<String, int> _anchors = {};
  final List<String> _pendingAnchors = [];
  int _pendingNewlines = 0;
  bool _pendingSpace = false;
  String? _lastChar;

  /// A block/line break: collapses with adjacent breaks, drops pending space.
  void newline() => _pendingNewlines++;

  /// Records an anchor id, resolved to the offset of the next visible
  /// character. First declaration wins, matching how browsers treat
  /// duplicate ids.
  void anchor(String id) {
    if (id.isEmpty || _anchors.containsKey(id)) return;
    _pendingAnchors.add(id);
  }

  /// Emits a `\uFFFC` placeholder for an inline image, resolving [src]
  /// against the EPUB archive when available.
  void image(
    String? src,
    String? alt, {
    String? id,
    String elementId = '',
    double? htmlWidth,
    double? htmlHeight,
  }) {
    if (src == null || src.isEmpty) return;
    if (archiveEntries == null) return;
    // Flush pending whitespace/newlines before the placeholder.
    flushSpace();
    if (_pendingNewlines > 0 && _buf.isNotEmpty) {
      final n = math.min(_pendingNewlines, 2);
      _buf.write('\n' * n);
      _lastChar = '\n';
      _pendingNewlines = 0;
    }
    _pendingSpace = false;
    // Resolve anchors.
    if (_pendingAnchors.isNotEmpty) {
      final at = _buf.length;
      for (final id in _pendingAnchors) {
        _anchors[id] = at;
      }
      _pendingAnchors.clear();
    }
    // Resolve the image path against the chapter's base directory.
    final resolved = DocumentParser._resolveHref(baseDir, src);
    final entryName = _findImageEntryName(resolved);
    if (entryName == null) return;
    final entry = archiveEntries![entryName]!;
    final offset = _buf.length;
    _buf.write('\uFFFC');
    final (w, h) = _decodeImageDimensions(entry);
    final isCover =
        (id != null && id.toLowerCase().contains('cover')) ||
        coverHrefs.contains(resolved.toLowerCase()) ||
        _filenameOf(src).toLowerCase().contains('cover');

    // Fallback: HTML attributes > manifest dimensions.
    final manifestDims = manifestImageDims?[resolved.toLowerCase()];
    final effectiveHtmlWidth = htmlWidth ?? manifestDims?.$1;
    final effectiveHtmlHeight = htmlHeight ?? manifestDims?.$2;

    _images.add(
      ImageRun(
        offset: offset,
        bytes: entry,
        intrinsicWidth: w,
        intrinsicHeight: h,
        alt: alt ?? '',
        fullWidth: isCover,
        elementId: elementId,
        htmlWidth: effectiveHtmlWidth,
        htmlHeight: effectiveHtmlHeight,
        sourceKey: entryName,
      ),
    );
  }

  String? _findImageEntryName(String resolved) {
    final entries = archiveEntries!;
    // Try exact match first.
    final key = Uri.decodeComponent(resolved.toLowerCase());
    if (entries.containsKey(key)) return key;
    // Try filename-only match (handles path mismatches in EPUBs).
    final filename =
        (resolved.contains('/')
                ? resolved.substring(resolved.lastIndexOf('/') + 1)
                : resolved)
            .toLowerCase();
    for (final e in entries.keys) {
      if (e.endsWith('/$filename') || e == filename) {
        return e;
      }
    }
    return null;
  }

  static String _filenameOf(String path) {
    final clean = path.split('?').first;
    return clean.contains('/')
        ? clean.substring(clean.lastIndexOf('/') + 1)
        : clean;
  }

  /// Reads width/height from common image headers (PNG/JPEG/GIF/BMP/WebP/SVG).
  /// Falls back to 0×0 on failure, which callers treat as "unknown".
  static (int, int) _decodeImageDimensions(Uint8List bytes) {
    if (bytes.length >= 24 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      // PNG: width at offset 16, height at offset 20 (big-endian uint32).
      final w =
          (bytes[16] << 24 | bytes[17] << 16 | bytes[18] << 8 | bytes[19]);
      final h =
          (bytes[20] << 24 | bytes[21] << 16 | bytes[22] << 8 | bytes[23]);
      return (w, h);
    }
    if (bytes.length >= 10 &&
        bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46) {
      // GIF: logical screen width/height, little-endian uint16 at 6/8.
      return (bytes[6] | (bytes[7] << 8), bytes[8] | (bytes[9] << 8));
    }
    if (bytes.length >= 26 && bytes[0] == 0x42 && bytes[1] == 0x4D) {
      // BMP: int32 LE width at 18, height at 22 (may be negative top-down).
      final w =
          bytes[18] | (bytes[19] << 8) | (bytes[20] << 16) | (bytes[21] << 24);
      final h =
          bytes[22] | (bytes[23] << 8) | (bytes[24] << 16) | (bytes[25] << 24);
      return (w.abs(), h.abs());
    }
    if (bytes.length >= 30 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      // WebP: RIFF container; parse the first chunk's canvas size.
      final fourcc = String.fromCharCodes(bytes.sublist(12, 16));
      if (fourcc == 'VP8X') {
        final w = 1 + (bytes[24] | (bytes[25] << 8) | (bytes[26] << 16));
        final h = 1 + (bytes[27] | (bytes[28] << 8) | (bytes[29] << 16));
        return (w, h);
      }
      if (fourcc == 'VP8L' && bytes.length >= 25) {
        final b0 = bytes[21], b1 = bytes[22], b2 = bytes[23], b3 = bytes[24];
        final w = 1 + (((b1 & 0x3F) << 8) | b0);
        final h = 1 + (((b3 & 0x0F) << 10) | (b2 << 2) | ((b1 & 0xC0) >> 6));
        return (w, h);
      }
      if (fourcc == 'VP8 ' && bytes.length >= 30) {
        final w = (bytes[26] | (bytes[27] << 8)) & 0x3FFF;
        final h = (bytes[28] | (bytes[29] << 8)) & 0x3FFF;
        return (w, h);
      }
    }
    if (_looksLikeSvg(bytes)) {
      final (w, h) = _decodeSvgDimensions(bytes);
      if (w > 0 && h > 0) return (w, h);
    }
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8) {
      // JPEG: scan for SOF0–SOF15 marker (0xFFC0–0xFFCF).
      var i = 2;
      while (i + 9 < bytes.length) {
        if (bytes[i] != 0xFF) {
          i++;
          continue;
        }
        final marker = bytes[i + 1];
        if (marker >= 0xC0 &&
            marker <= 0xCF &&
            marker != 0xC4 &&
            marker != 0xC8 &&
            marker != 0xCC) {
          final h = (bytes[i + 5] << 8) | bytes[i + 6];
          final w = (bytes[i + 7] << 8) | bytes[i + 8];
          return (w, h);
        }
        final len = (bytes[i + 2] << 8) | bytes[i + 3];
        i += 2 + len;
      }
    }
    return (0, 0);
  }

  /// True when the bytes open as XML/SVG (ignoring a UTF-8 BOM and whitespace).
  static bool _looksLikeSvg(Uint8List bytes) {
    for (var i = 0; i < bytes.length && i < 64; i++) {
      final b = bytes[i];
      if (b == 0x3C) return true; // '<'
      if (b != 0x20 &&
          b != 0x09 &&
          b != 0x0A &&
          b != 0x0D &&
          b != 0xEF &&
          b != 0xBB &&
          b != 0xBF) {
        return false;
      }
    }
    return false;
  }

  /// Best-effort SVG dimensions from `viewBox`, then `width`/`height`.
  static (int, int) _decodeSvgDimensions(Uint8List bytes) {
    const limit = 8192;
    final slice = bytes.length > limit ? bytes.sublist(0, limit) : bytes;
    final text = utf8.decode(slice, allowMalformed: true);

    final viewBox = RegExp(
      r'''viewBox\s*=\s*["']([^"']+)["']''',
    ).firstMatch(text);
    if (viewBox != null) {
      final parts = viewBox.group(1)!.trim().split(RegExp(r'[\s,]+'));
      if (parts.length == 4) {
        final w = double.tryParse(parts[2]);
        final h = double.tryParse(parts[3]);
        if (w != null && h != null && w > 0 && h > 0) {
          return (w.round(), h.round());
        }
      }
    }
    final wm = RegExp(r'''\bwidth\s*=\s*["']([\d.]+)''').firstMatch(text);
    final hm = RegExp(r'''\bheight\s*=\s*["']([\d.]+)''').firstMatch(text);
    final w = wm == null ? null : double.tryParse(wm.group(1)!);
    final h = hm == null ? null : double.tryParse(hm.group(1)!);
    if (w != null && h != null && w > 0 && h > 0) {
      return (w.round(), h.round());
    }
    return (0, 0);
  }

  /// Emits any pending whitespace now, with the current style flags.
  void flushSpace() {
    if (!_pendingSpace) return;
    if (_buf.isNotEmpty && _lastChar != '\n') {
      _emit(' ');
    }
    _pendingSpace = false;
  }

  void text(String raw) {
    if (raw.isEmpty) return;
    final decoded = DocumentParser._decodeEntities(raw);
    for (final m in RegExp(r'[ \t\r\f\v]+|[^ \t\r\f\v]+').allMatches(decoded)) {
      final tok = m.group(0)!;
      if (tok.codeUnitAt(0) == 0x20 ||
          tok.codeUnitAt(0) == 0x09 ||
          tok.codeUnitAt(0) == 0x0A ||
          tok.codeUnitAt(0) == 0x0D) {
        _pendingSpace = true;
        continue;
      }
      if (_pendingNewlines > 0 && _buf.isNotEmpty) {
        final n = math.min(_pendingNewlines, 2);
        _buf.write('\n' * n);
        _lastChar = '\n';
      }
      _pendingNewlines = 0;
      if (_pendingSpace && _buf.isNotEmpty && _lastChar != '\n') {
        _emit(' ');
      }
      _pendingSpace = false;
      // Resolve anchors to this token's start: newlines and the separating
      // space belong to the preceding text, not to the anchored section.
      if (_pendingAnchors.isNotEmpty) {
        final at = _buf.length;
        for (final id in _pendingAnchors) {
          _anchors[id] = at;
        }
        _pendingAnchors.clear();
      }
      _emit(tok);
    }
  }

  void _emit(String tok) {
    final start = _buf.length;
    _buf.write(tok);
    _lastChar = tok[tok.length - 1];
    final bold = boldDepth > 0;
    final italic = italicDepth > 0;
    final quote = quoteDepth > 0;
    if (!bold && !italic && !quote) return;
    if (_runs.isNotEmpty) {
      final last = _runs.last;
      if (last.end == start &&
          last.bold == bold &&
          last.italic == italic &&
          last.quote == quote) {
        _runs[_runs.length - 1] = StyleRun(
          last.start,
          _buf.length,
          bold: bold,
          italic: italic,
          quote: quote,
        );
        return;
      }
    }
    _runs.add(
      StyleRun(start, _buf.length, bold: bold, italic: italic, quote: quote),
    );
  }

  (String, List<StyleRun>, Map<String, int>, List<ImageRun>) finish() {
    var text = _buf.toString();
    // Right-trim while clamping runs to the trimmed length.
    var end = text.length;
    while (end > 0 && _isWs(text.codeUnitAt(end - 1))) {
      end--;
    }
    text = text.substring(0, end);
    final runs = _runs.where((r) => r.start < end).map((r) {
      return r.end <= end
          ? r
          : StyleRun(
              r.start,
              end,
              bold: r.bold,
              italic: r.italic,
              quote: r.quote,
            );
    }).toList();
    final images = _images
        .where((img) => img.offset < end)
        .map((img) => _promoteStandaloneImage(text, img))
        .toList();
    // Trailing anchors had no following text; park them at the very end so
    // they resolve to an empty slice and get dropped rather than mis-titling
    // the preceding section.
    for (final id in _pendingAnchors) {
      _anchors[id] = end;
    }
    _pendingAnchors.clear();
    final anchors = {
      for (final e in _anchors.entries) e.key: math.min(e.value, end),
    };
    return (text, runs, anchors, images);
  }

  /// Marks a large image that sits on its own paragraph as full-width so the
  /// inline height cap does not shrink real illustrations into thumbnails.
  /// Small icons are left alone, and covers are already full-width.
  static ImageRun _promoteStandaloneImage(String text, ImageRun img) {
    if (img.fullWidth) return img;
    final largest = math.max(img.intrinsicWidth, img.intrinsicHeight);
    if (largest < 400 || !_isStandalone(text, img.offset)) return img;
    return ImageRun(
      offset: img.offset,
      bytes: img.bytes,
      intrinsicWidth: img.intrinsicWidth,
      intrinsicHeight: img.intrinsicHeight,
      alt: img.alt,
      fullWidth: true,
      onTap: img.onTap,
      css: img.css,
      elementId: img.elementId,
      htmlWidth: img.htmlWidth,
      htmlHeight: img.htmlHeight,
      sourceKey: img.sourceKey,
    );
  }

  /// True when only horizontal whitespace, image placeholders or line breaks
  /// surround [offset] — i.e. the image is its own block, not inline with text.
  static bool _isStandalone(String text, int offset) {
    var i = offset - 1;
    while (i >= 0 &&
        (_isHorizontalWs(text.codeUnitAt(i)) || text.codeUnitAt(i) == 0xFFFC)) {
      i--;
    }
    final left = i >= 0 ? text.codeUnitAt(i) : null;
    if (left != null && left != 0x0A) return false;

    var j = offset + 1;
    while (j < text.length &&
        (_isHorizontalWs(text.codeUnitAt(j)) || text.codeUnitAt(j) == 0xFFFC)) {
      j++;
    }
    final right = j < text.length ? text.codeUnitAt(j) : null;
    if (right != null && right != 0x0A) return false;
    return true;
  }

  static bool _isHorizontalWs(int c) => c == 0x20 || c == 0x09 || c == 0x0D;

  static bool _isWs(int c) => c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D;
}
