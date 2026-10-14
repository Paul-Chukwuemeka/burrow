import '../document_parser.dart';
import 'epub_engine.dart';

/// The [EpubEngine] backed by the existing Dart [DocumentParser].
///
/// A pure delegation: routing the reader through this adapter must not change
/// behaviour, so the suite stays green when the engine flag is switched back
/// to `dart` (the reversible fallback).
class DartEpubEngine implements EpubEngine {
  const DartEpubEngine();

  @override
  Future<ParsedDocument> parse(String path) => DocumentParser.parse(path);

  @override
  Future<ParsedMetadata> extractMetadata(String path) =>
      DocumentParser.extractMetadata(path);

  @override
  void clearCacheFor(String path) => DocumentParser.clearCacheForSync(path);
}
