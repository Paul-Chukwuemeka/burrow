import 'dart:async';
import 'dart:io';

import 'package:lexicor/lexicor.dart';
import 'package:path_provider/path_provider.dart';

/// Offline dictionary service backed by the Open English WordNet.
///
/// On first use the database (~40 MB) is downloaded from a hosted URL and
/// stored in the app documents directory. Subsequent lookups are instant and
/// fully offline.
class DictionaryService {
  DictionaryService._();

  static final DictionaryService instance = DictionaryService._();

  /// Replace with the actual URL after uploading dictionary_full.sqlite
  /// to GitHub Releases.
  static const _dbUrl =
      'https://github.com/Paul-Chukwuemeka/burrow/releases/download/Dictionary/dictionary_full.sqlite';

  static const _dbFileName = 'dictionary_full.sqlite';

  Lexicor? _lexicor;
  bool _initializing = false;
  Completer<void>? _initCompleter;

  /// Whether the database has been downloaded and is ready for lookups.
  Future<bool> get isReady async {
    final file = await _dbFile;
    return file.existsSync();
  }

  /// Ensures the Lexicor engine is initialised. Downloads the DB on first use.
  ///
  /// [onProgress] is called with a value between 0.0 and 1.0 during download.
  /// [onStatus] is called with human-readable status messages.
  Future<void> ensureReady({
    Function(double progress)? onProgress,
    Function(String status)? onStatus,
  }) async {
    if (_lexicor != null) return;
    if (_initializing) {
      await _initCompleter!.future;
      return;
    }
    _initializing = true;
    _initCompleter = Completer<void>();

    try {
      final file = await _dbFile;
      if (!file.existsSync()) {
        onStatus?.call('Downloading dictionary…');
        await _downloadDatabase(file, onProgress: onProgress, onStatus: onStatus);
      }

      onStatus?.call('Loading dictionary…');
      _lexicor = await Lexicor.init(
        customPath: file.path,
        withDefinitions: true,
      );

      if (!_initCompleter!.isCompleted) _initCompleter!.complete();
    } catch (e) {
      if (!_initCompleter!.isCompleted) _initCompleter!.completeError(e);
      rethrow;
    } finally {
      _initializing = false;
    }
  }

  /// Looks up [word] and returns the result, or null if the engine isn't ready.
  LookupResult? lookup(String word) {
    return _lexicor?.lookup(word);
  }

  /// Returns example sentences for a concept, or an empty list.
  List<String> examples(Concept concept) {
    return _lexicor?.examples(concept) ?? [];
  }

  /// Returns synonyms for a concept.
  List<String> synonyms(Concept concept) {
    return _lexicor?.synonyms(concept) ?? [];
  }

  /// Closes the Lexicor engine and releases resources.
  void close() {
    _lexicor?.close();
    _lexicor = null;
  }

  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------

  Future<File> get _dbFile async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_dbFileName');
  }

  Future<void> _downloadDatabase(
    File targetFile, {
    Function(double progress)? onProgress,
    Function(String status)? onStatus,
  }) async {
    final uri = Uri.parse(_dbUrl);
    final client = HttpClient();
    try {
      final request = await client.getUrl(uri).timeout(
        const Duration(seconds: 30),
        onTimeout: () => throw TimeoutException('Connection timed out'),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 30),
        onTimeout: () => throw TimeoutException('Download timed out'),
      );

      if (response.statusCode != 200) {
        throw HttpException(
          'Download failed: HTTP ${response.statusCode}',
        );
      }

      final contentLength = response.contentLength;
      final bytes = <int>[];
      int received = 0;

      await for (final chunk in response) {
        bytes.addAll(chunk);
        received += chunk.length;
        if (contentLength > 0) {
          onProgress?.call(received / contentLength);
        }
      }

      final tempFile = File('${targetFile.path}.tmp');
      await tempFile.writeAsBytes(bytes, flush: true);
      await tempFile.rename(targetFile.path);
    } finally {
      client.close();
    }
  }
}
