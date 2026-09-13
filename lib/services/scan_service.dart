import 'dart:io';
import 'dart:isolate';
import 'package:permission_handler/permission_handler.dart';

/// Finds supported documents on the device.
///
/// Two modes:
/// - [scanDevice]: full-storage walk; needs All Files Access on Android 11+,
///   runtime READ_EXTERNAL_STORAGE below that.
/// - [scanFolder]: user picks one folder via SAF; no permission needed.
class ScanService {
  static const defaultExtensions = {'.epub', '.txt', '.pdf', '.cbz', '.cbr'};
  static const _maxResults = 2000;
  static const _maxDepth = 14;

  /// Directories never worth walking (app sandboxes, virtual mounts).
  static const _skipNames = {
    'Android',
    'proc',
    'sys',
    'dev',
    'config',
    'cache',
    'data',
  };

  /// Returns true if broad file access is granted after prompting.
  static Future<bool> ensurePermission() async {
    if (!Platform.isAndroid) return true;

    var status = await Permission.manageExternalStorage.request();
    if (status.isGranted) return true;

    // Android 10 and below: classic runtime permission instead.
    status = await Permission.storage.request();
    return status.isGranted || status.isLimited;
  }

  /// Walks shared storage looking for documents. Returns absolute paths not
  /// already present in [knownPaths].
  static Future<List<String>> scanDevice({
    Set<String> knownPaths = const {},
    Set<String>? extensions,
  }) {
    final exts = extensions ?? defaultExtensions;
    return Isolate.run(
      () => _walk('/storage/emulated/0', knownPaths, exts),
    ).timeout(const Duration(minutes: 2), onTimeout: () => []);
  }

  /// Recursively scans a single user-chosen folder.
  static Future<List<String>> scanFolder(
    String folder, {
    Set<String> knownPaths = const {},
    Set<String>? extensions,
  }) {
    final exts = extensions ?? defaultExtensions;
    return Isolate.run(
      () => _walk(folder, knownPaths, exts),
    ).timeout(const Duration(minutes: 2), onTimeout: () => []);
  }

  /// Scans multiple specific folders and merges the results.
  /// This is the "quick refresh" counterpart to [scanDevice].
  static Future<List<String>> scanFolders(
    Iterable<String> folders, {
    Set<String> knownPaths = const {},
    Set<String>? extensions,
  }) async {
    final exts = extensions ?? defaultExtensions;
    final results = <String>[];
    for (final folder in folders) {
      if (!await Directory(folder).exists()) continue;
      final found = await Isolate.run(
        () => _walk(folder, knownPaths, exts),
      ).timeout(const Duration(minutes: 2), onTimeout: () => []);
      results.addAll(found);
    }
    results.sort();
    return results;
  }

  static List<String> _walk(
    String root,
    Set<String> knownPaths,
    Set<String> extensions,
  ) {
    final results = <String>[];
    final stack = [(root, 0)];
    while (stack.isNotEmpty && results.length < _maxResults) {
      final (dir, depth) = stack.removeLast();
      final dirRef = Directory(dir);
      List<FileSystemEntity> entries;
      try {
        entries = dirRef.listSync(followLinks: false);
      } catch (_) {
        continue; // Unreadable directory: skip silently.
      }
      for (final e in entries) {
        final name = e.path.split(Platform.pathSeparator).last;
        if (name.startsWith('.')) continue;
        if (e is Directory) {
          if (_skipNames.contains(name.toLowerCase()) && depth == 0) continue;
          if (depth < _maxDepth) stack.add((e.path, depth + 1));
        } else if (e is File) {
          final dot = name.lastIndexOf('.');
          if (dot < 0) continue;
          final ext = name.substring(dot).toLowerCase();
          if (!extensions.contains(ext)) continue;
          if (!knownPaths.contains(e.path)) results.add(e.path);
          if (results.length >= _maxResults) break;
        }
      }
    }
    results.sort();
    return results;
  }
}
