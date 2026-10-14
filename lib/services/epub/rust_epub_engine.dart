import 'dart:io';

import 'package:burrow/src/rust/api/epub.dart' as rust;
import 'package:burrow/src/rust/epub/project.dart' show ChapterDto;

import '../../utils/book_title.dart';
import '../document_parser.dart';
import 'epub_dto_mapper.dart';
import 'epub_engine.dart';

/// The [EpubEngine] backed by the native Rust parser.
///
/// Opens one opaque Rust handle per book, then pulls metadata and each spine
/// chapter across the FFI (`chapter(handle, index)`), mapping the flat-run DTOs
/// onto the existing domain types (spec D4). Every offset the engine emits is a
/// Dart UTF-16 code unit, `%` lengths stay symbolic, and image bytes stay empty
/// until Task 8's on-demand hydration (D15).
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
    final spine = await rust.spine(handle: handle);
    final chapters = <ChapterDto>[];
    for (var index = 0; index < spine.length; index++) {
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

  /// No-op: the Rust engine writes no disk cache in Phase A.
  @override
  void clearCacheFor(String path) {}
}

/// The filename-derived title, matching `DocumentParser._titleFromFilename`.
String titleFromFilename(String path) {
  final base = path.split(Platform.pathSeparator).last;
  final dot = base.lastIndexOf('.');
  return cleanBookTitle(dot > 0 ? base.substring(0, dot) : base);
}
