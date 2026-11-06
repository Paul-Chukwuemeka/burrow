import 'package:flutter/foundation.dart';

import 'library_enums.dart';

enum BookFormat { epub, txt, pdf, cbz, cbr }

/// Extensions that map cleanly to a supported format.
/// Unknown extensions (`.mobi`, `.azw3`, etc.) fall through to `txt` and will
/// be Latin-1-decoded into garbage chapters — callers should surface an error
/// for unsupported types rather than silently importing them.
BookFormat formatFromExtension(String path) {
  final ext = path.toLowerCase().split('.').last;
  switch (ext) {
    case 'epub':
      return BookFormat.epub;
    case 'pdf':
      return BookFormat.pdf;
    case 'cbz':
      return BookFormat.cbz;
    case 'cbr':
      return BookFormat.cbr;
    case 'txt':
      return BookFormat.txt;
    default:
      return BookFormat.txt;
  }
}

class Book {
  Book({
    required this.id,
    required this.title,
    required this.author,
    required this.path,
    required this.format,
    this.coverPath,
    required this.addedAt,
    this.lastReadAt = 0,
    this.progress = 0,
    this.lastChapter = 0,
    this.lastOffset = 0,
    this.description,
    this.annotation,
    this.genre,
    this.seriesName,
    this.seriesIndex,
    this.publisher,
    this.isbn,
    this.language,
    this.review,
    this.publicationDate,
    this.rights,
    this.type,
    this.source,
    this.titleSort,
    this.authorSort,
    this.metadataComplete = false,
    this.fileSize,
    this.mtimeMs,
    this.archiveTier = ArchiveTier.none,
    this.archivedAt = 0,
  });

  final String id;
  String title;
  String author;
  final String path;
  final BookFormat format;

  /// Path to a cover image file inside the app's documents directory.
  String? coverPath;

  final int addedAt;

  /// Milliseconds since epoch of last open; 0 = never opened.
  int lastReadAt;

  /// 0..1 overall reading progress.
  double progress;

  /// Reflowable: current chapter index. PDF: current page index.
  int lastChapter;

  /// Reflowable: char offset within chapter. PDF: unused.
  int lastOffset;

  // -- User-editable metadata ------------------------------------------------

  String? description;
  String? annotation;
  String? genre;
  String? seriesName;
  double? seriesIndex;
  String? publisher;
  String? isbn;
  String? language;
  String? review;
  String? publicationDate;
  String? rights;
  String? type;
  String? source;
  String? titleSort;
  String? authorSort;

  /// Whether full metadata (author, description, cover, etc.) has been extracted.
  bool metadataComplete;

  int? fileSize;
  int? mtimeMs;

  /// Archive tier; [ArchiveTier.none] while the book is in the active library.
  ArchiveTier archiveTier;

  /// Epoch-ms when the book was archived; 0 while active.
  int archivedAt;

  bool get isArchived => archiveTier != ArchiveTier.none;

  bool get isStarted => lastReadAt > 0;
  bool get isFinished => progress >= 0.999;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'author': author,
    'path': path,
    'format': format.name,
    'coverPath': coverPath,
    'addedAt': addedAt,
    'lastReadAt': lastReadAt,
    'progress': progress,
    'lastChapter': lastChapter,
    'lastOffset': lastOffset,
    'description': description,
    'annotation': annotation,
    'genre': genre,
    'seriesName': seriesName,
    'seriesIndex': seriesIndex,
    'publisher': publisher,
    'isbn': isbn,
    'language': language,
    'review': review,
    'publicationDate': publicationDate,
    'rights': rights,
    'type': type,
    'source': source,
    'titleSort': titleSort,
    'authorSort': authorSort,
    'metadataComplete': metadataComplete,
    'fileSize': fileSize,
    'mtimeMs': mtimeMs,
    'archiveTier': archiveTier.name,
    'archivedAt': archivedAt,
  };

  static Book fromJson(Map<String, dynamic> json) {
    // Handle unknown/corrupt format values gracefully instead of throwing.
    BookFormat fmt;
    try {
      fmt = BookFormat.values.byName(json['format'] as String);
    } catch (_) {
      // ignore: avoid_print
      debugPrint('Unknown book format "${json['format']}", defaulting to txt');
      fmt = BookFormat.txt;
    }

    return Book(
      id: json['id'] as String,
      title: json['title'] as String,
      author: (json['author'] as String?) ?? '',
      path: json['path'] as String,
      format: fmt,
      coverPath: json['coverPath'] as String?,
      addedAt: json['addedAt'] as int? ?? 0,
      lastReadAt: json['lastReadAt'] as int? ?? 0,
      progress: (json['progress'] as num?)?.toDouble() ?? 0,
      lastChapter: json['lastChapter'] as int? ?? 0,
      lastOffset: json['lastOffset'] as int? ?? 0,
      description: json['description'] as String?,
      annotation: json['annotation'] as String?,
      genre: json['genre'] as String?,
      seriesName: json['seriesName'] as String?,
      seriesIndex: (json['seriesIndex'] as num?)?.toDouble(),
      publisher: json['publisher'] as String?,
      isbn: json['isbn'] as String?,
      language: json['language'] as String?,
      review: json['review'] as String?,
      publicationDate: json['publicationDate'] as String?,
      rights: json['rights'] as String?,
      type: json['type'] as String?,
      source: json['source'] as String?,
      titleSort: json['titleSort'] as String?,
      authorSort: json['authorSort'] as String?,
      metadataComplete: json['metadataComplete'] as bool? ?? false,
      fileSize: json['fileSize'] as int?,
      mtimeMs: json['mtimeMs'] as int?,
      archiveTier: _archiveTierFromName(json['archiveTier']),
      archivedAt: json['archivedAt'] as int? ?? 0,
    );
  }

  static ArchiveTier _archiveTierFromName(Object? raw) {
    if (raw is! String) return ArchiveTier.none;
    for (final tier in ArchiveTier.values) {
      if (tier.name == raw) return tier;
    }
    return ArchiveTier.none;
  }

  /// Pretty-printed progress, e.g. "42%" or "New".
  String get progressLabel {
    if (!isStarted) return 'New';
    if (isFinished) return 'Finished';
    return '${(progress * 100).round()}%';
  }

  /// Single screen-reader convention shared by hero card and grid tiles.
  ///
  /// Unstarted books say "Not started" (never a bare "0%"); started books
  /// announce "42 percent read"; finished books announce "Finished".
  String get progressSemantics {
    if (!isStarted) return 'Not started';
    if (isFinished) return 'Finished';
    final pct = (progress * 100).round();
    return '$pct percent read';
  }

  /// Whether a progress bar should be drawn. Bars only appear once reading
  /// has begun; "New" books show no bar at all rather than an empty one.
  bool get showProgress => isStarted;
}
