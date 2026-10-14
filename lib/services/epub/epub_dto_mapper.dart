import 'dart:typed_data';

import 'package:burrow/models/css_style.dart';
import 'package:burrow/models/style_run.dart';
import 'package:burrow/services/document_parser.dart';
import 'package:burrow/services/epub_css_parser.dart';
import 'package:burrow/src/rust/epub/model.dart';
import 'package:burrow/src/rust/epub/project.dart' as rust;

/// Maps the Rust engine's flat-run DTOs onto the existing Dart domain model.
///
/// This is the last hop of the Phase-A contract (spec D4): the DTOs carry Dart
/// UTF-16 offsets and symbolic percentages, so the mapped
/// `ParsedDocument`/`Chapter`/`StyleRun`/`ImageRun`/`CssStyle` are exactly what
/// the reader/paginator already consume — nothing downstream changes.
///
/// `CssStyleDto` is shaped like `CssStyle.toJson`, so [`cssStyleFrom`] rebuilds
/// a `CssStyle` through the existing `CssStyle.fromJson`/`CssLength.fromJson`
/// decoders rather than duplicating their parsing rules.
abstract final class EpubDtoMapper {
  /// Maps one projected chapter onto a [Chapter].
  static Chapter toChapter(rust.ChapterDto dto) => Chapter(
    dto.title,
    dto.body,
    dto.runs.map(_toStyleRun).toList(),
    dto.images.map(_toImageRun).toList(),
  );

  /// Builds a [ParsedDocument] from the projected chapters and the book's
  /// metadata.
  ///
  /// The cover is downscaled with the same helper the Dart engine uses so the
  /// two engines' covers match; `fallbackTitle` is used when the OPF title is
  /// empty (the caller passes the filename-derived title).
  static ParsedDocument toParsedDocument({
    required List<rust.ChapterDto> chapters,
    required MetadataDto metadata,
    String fallbackTitle = '',
  }) {
    return ParsedDocument(
      title: metadata.title.isEmpty ? fallbackTitle : metadata.title,
      author: metadata.author,
      chapters: chapters.map(toChapter).toList(),
      coverBytes: DocumentParser.prepareCover(metadata.coverBytes),
      description: metadata.description,
      genre: metadata.genre,
      seriesName: metadata.seriesName,
      seriesIndex: metadata.seriesIndex,
      publisher: metadata.publisher,
      isbn: metadata.isbn,
      language: metadata.language,
      publicationDate: metadata.publicationDate,
      rights: metadata.rights,
      titleSort: metadata.titleSort,
      authorSort: metadata.authorSort,
      fontFaces: fontFacesFrom(metadata),
    );
  }

  /// Maps the Rust metadata DTO onto [ParsedMetadata].
  static ParsedMetadata toParsedMetadata(
    MetadataDto metadata, {
    String fallbackTitle = '',
  }) {
    return ParsedMetadata(
      title: metadata.title.isEmpty ? fallbackTitle : metadata.title,
      author: metadata.author,
      coverBytes: DocumentParser.prepareCover(metadata.coverBytes),
      description: metadata.description,
      genre: metadata.genre,
      seriesName: metadata.seriesName,
      seriesIndex: metadata.seriesIndex,
      publisher: metadata.publisher,
      isbn: metadata.isbn,
      language: metadata.language,
      publicationDate: metadata.publicationDate,
      rights: metadata.rights,
      titleSort: metadata.titleSort,
      authorSort: metadata.authorSort,
    );
  }

  /// The `@font-face` families the book declares, keyed by family.
  ///
  /// The DTO carries no bytes (D15); a font's bytes are materialised lazily by
  /// the engine, so `bytes` stays null here.
  static Map<String, FontFaceInfo> fontFacesFrom(MetadataDto metadata) {
    return {
      for (final face in metadata.fontFaces)
        face.family: FontFaceInfo(family: face.family, src: face.src),
    };
  }

  /// Rebuilds a [CssStyle] from a DTO, or null when nothing was declared.
  static CssStyle? cssStyleFrom(rust.CssStyleDto? dto) {
    if (dto == null) return null;
    final style = CssStyle.fromJson({
      if (dto.fontSize != null) 'fontSize': dto.fontSize,
      if (dto.color != null) 'color': dto.color,
      if (dto.textAlign != null) 'textAlign': dto.textAlign,
      if (dto.textIndent != null) 'textIndent': dto.textIndent,
      if (dto.marginLeft != null) 'marginLeft': dto.marginLeft,
      if (dto.marginRight != null) 'marginRight': dto.marginRight,
      if (dto.marginTop != null) 'marginTop': dto.marginTop,
      if (dto.marginBottom != null) 'marginBottom': dto.marginBottom,
      if (dto.fontWeight != null) 'fontWeight': dto.fontWeight,
      if (dto.fontStyle != null) 'fontStyle': dto.fontStyle,
      if (dto.textDecoration != null) 'textDecoration': dto.textDecoration,
      if (dto.fontFamily != null) 'fontFamily': dto.fontFamily,
      if (dto.lineHeight != null) 'lineHeight': dto.lineHeight,
      if (dto.letterSpacing != null) 'letterSpacing': dto.letterSpacing,
      if (dto.wordSpacing != null) 'wordSpacing': dto.wordSpacing,
      if (dto.textTransform != null) 'textTransform': dto.textTransform,
      if (dto.whiteSpace != null) 'whiteSpace': dto.whiteSpace,
      if (dto.width != null) 'width': _lengthJson(dto.width!),
      if (dto.height != null) 'height': _lengthJson(dto.height!),
      if (dto.maxWidth != null) 'maxWidth': _lengthJson(dto.maxWidth!),
      if (dto.maxHeight != null) 'maxHeight': _lengthJson(dto.maxHeight!),
    });
    return style.isEmpty ? null : style;
  }

  /// The `CssLength.fromJson` shape (`{'v': value, 'p': isPercent}`).
  static Map<String, dynamic> _lengthJson(rust.CssLengthDto length) => {
    'v': length.value,
    'p': length.isPercent,
  };

  static StyleRun _toStyleRun(rust.StyleRunDto dto) => StyleRun(
    dto.start,
    dto.end,
    bold: dto.bold,
    italic: dto.italic,
    quote: dto.quote,
    css: cssStyleFrom(dto.css),
  );

  static ImageRun _toImageRun(rust.ImageRunDto dto) => ImageRun(
    offset: dto.offset,
    // Bytes cross the boundary by reference, not value (D15); Task 8 hydrates
    // them on demand through the Rust handle.
    bytes: Uint8List(0),
    intrinsicWidth: dto.intrinsicW,
    intrinsicHeight: dto.intrinsicH,
    alt: dto.alt,
    fullWidth: dto.fullWidth,
    css: cssStyleFrom(dto.css),
    elementId: dto.elementId,
    htmlWidth: dto.htmlW,
    htmlHeight: dto.htmlH,
    sourceKey: dto.sourceKey,
    imgSrc: dto.imgSrc,
    imgClass: dto.imgClass,
  );
}
