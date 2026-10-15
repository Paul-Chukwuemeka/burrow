import '../services/epub_css_parser.dart' show FontFaceInfo;
import 'style_run.dart' show ImageRun, StyleRun;

/// A single parsed chapter: title plus body text with style runs and images.
///
/// Moved verbatim out of the retired Dart parser (retire-dart-engine
/// Task 7): the Rust engine maps its DTOs onto these same domain types, so
/// the reader, search, and table of contents consume them unchanged.
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
