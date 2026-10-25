import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

import 'package:lexicor/lexicor.dart';
import 'package:path_provider/path_provider.dart';

import 'package:burrow/services/dictionary_files.dart';

/// Offline dictionary service backed by Wiktionary data (via kaikki.org).
///
/// On first use the compressed database (~60 MB container) is downloaded from
/// a hosted URL, integrity-checked and decompressed into the app documents
/// directory. Subsequent lookups are instant and fully offline.
class DictionaryService {
  DictionaryService._();

  static final DictionaryService instance = DictionaryService._();

  static const _dbUrl =
      'https://github.com/Paul-Chukwuemeka/burrow/releases/download/Dictionary/dictionary_wikt.sqlite.xz';

  /// Compressed container kept on disk after decompression, so updating the
  /// database later does not re-download it unnecessarily.
  static const _containerFileName = 'dictionary.sqlite.xz';

  /// Final decompressed SQLite database the engine opens.
  static const _dbFileName = 'dictionary.sqlite';

  /// SHA-256 hash of the known-good downloadable container.
  /// Updated when a new version is published. Empty string skips verification.
  static const _expectedXzSha256 = '';

  Lexicor? _lexicor;
  bool _initializing = false;
  Completer<void>? _initCompleter;

  /// Cached path to the database file.
  String? _dbPath;

  /// Whether the decompressed database file exists on disk.
  bool get isDownloaded => _isDownloaded ?? false;
  bool? _isDownloaded;

  /// Initialises the cached path and checks download status. Call once at app start.
  Future<void> init() async {
    final file = await _dbFile;
    _dbPath = file.path;
    _isDownloaded = file.existsSync();
    await _cleanupObsoleteArtifacts(file);
  }

  /// Ensures the Lexicor engine is initialised. Downloads the DB on first use.
  ///
  /// [onProgress] is called with a value between 0.0 and 1.0 during download,
  /// or with −1 progress ticks when the server offers no content length.
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
    final completer = Completer<void>();
    _initCompleter = completer;

    try {
      final file = await _dbFile;
      if (!file.existsSync()) {
        onStatus?.call('Downloading dictionary…');
        await _downloadDatabase(
          file,
          onProgress: onProgress,
          onStatus: onStatus,
        );
      }

      onStatus?.call('Loading dictionary…');
      _lexicor = await Lexicor.init(
        customPath: file.path,
        withDefinitions: true,
      );

      _isDownloaded = true;
      completer.complete();
    } catch (e) {
      completer.completeError(e);
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
    _initializing = false;
    _initCompleter = null;
  }

  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------

  Future<File> get _dbFile async {
    if (_dbPath != null) return File(_dbPath!);
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$_dbFileName');
    _dbPath = file.path;
    return file;
  }

  /// Deletes obsolescent artifacts (legacy Open English WordNet DBs and any
  /// interrupted-download temp files) from the app documents directory.
  ///
  /// Existing users of the previous dictionary build are detected here: the
  /// legacy file's presence is reported instead of trusted, so [isDownloaded]
  /// stays false and the new Wiktionary DB downloads on the next ensureReady.
  Future<void> _cleanupObsoleteArtifacts(File currentDb) async {
    try {
      final dir = currentDb.parent;
      await cleanupDictionaryArtifacts(dir);
    } catch (_) {
      // Best-effort cleanup; ignore errors.
    }
  }

  Future<File> get _containerFile async {
    final dir = (await _dbFile).parent;
    return File('${dir.path}/$_containerFileName');
  }

  Future<void> _downloadDatabase(
    File targetFile, {
    Function(double progress)? onProgress,
    Function(String status)? onStatus,
  }) async {
    final uri = Uri.parse(_dbUrl);
    final client = HttpClient();
    try {
      final request = await client
          .getUrl(uri)
          .timeout(
            const Duration(seconds: 30),
            onTimeout: () => throw TimeoutException('Connection timed out'),
          );
      final response = await request.close().timeout(
        const Duration(seconds: 30),
        onTimeout: () => throw TimeoutException('Download timed out'),
      );

      if (response.statusCode != 200) {
        throw HttpException('Download failed: HTTP ${response.statusCode}');
      }

      // GitHub release downloads redirect; HttpClient follows them, so this
      // is the final response. contentLength can still be −1 (chunked).
      final contentLength = response.contentLength;
      final container = await _containerFile;
      final tempContainer = File('${container.path}.tmp');
      final sink = tempContainer.openWrite();

      // sha256 accumulates in flight — no second read pass needed for
      // download-integrity checking.
      final digestCollector = _DigestCollector();
      final hashSink = sha256.startChunkedConversion(digestCollector);

      int received = 0;

      try {
        await for (final chunk in response.timeout(
          const Duration(minutes: 2),
        )) {
          sink.add(chunk);
          hashSink.add(chunk);
          received += chunk.length;
          if (contentLength > 0) {
            onProgress?.call(received / contentLength);
          } else {
            onProgress?.call(-1);
          }
        }
      } finally {
        await sink.flush();
        await sink.close();
        hashSink.close();
      }

      if (_expectedXzSha256.isNotEmpty &&
          digestCollector.digest.toString() != _expectedXzSha256) {
        // Corrupt or truncated container: delete and surface per spec.
        await tempContainer.delete();
        throw StateError('Dictionary download integrity check failed');
      }

      await tempContainer.rename(container.path);

      onStatus?.call('Preparing dictionary…');
      // Decompress + integrity-verify off the UI thread (archive's XZDecoder
      // is pure Dart, so it is isolate-friendly).
      await Isolate.run(() {
        return decompressAndVerify(
          xz: container,
          out: targetFile,
          expectedSha256: _expectedXzSha256,
        );
      });

      // The container is kept on disk: re-attempts or engine re-inits don't
      // re-download an already-fetched container.
    } finally {
      client.close();
    }
  }
}

/// Holds the final sha256 [Digest] fed by [sha256.startChunkedConversion].
class _DigestCollector implements Sink<Digest> {
  Digest? _digest;

  Digest get digest => _digest!;

  @override
  void add(Digest data) => _digest = data;

  @override
  void close() {}
}
