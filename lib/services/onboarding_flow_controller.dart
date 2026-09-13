import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/import_helper.dart';
import '../services/library_service.dart';
import '../services/scan_service.dart';
import '../widgets/onboarding/import_body.dart';

/// Pick a set of files; returns absolute paths (empty when cancelled).
typedef PickFilesFn = Future<List<String>> Function();

/// Resolve a list of book paths (scan or folder walk).
typedef ScanFn = Future<List<String>> Function();

/// Request storage access; returns whether access was granted.
typedef PermissionFn = Future<bool> Function();

enum _ScanKind { none, device, folder }

/// Manages onboarding page order, scan state, and navigation.
///
/// Single source of truth for the onboarding flow. The [OnboardingScreen]
/// reads from it and calls its methods; individual page widgets never talk
/// to each other directly.
class OnboardingFlowController extends ChangeNotifier {
  OnboardingFlowController({
    required this.library,
    this.requestPermission,
    this.scanDevice,
    this.scanFolder,
    this.pickFile,
  });

  final LibraryService library;
  final PermissionFn? requestPermission;
  final ScanFn? scanDevice;
  final ScanFn? scanFolder;
  final PickFilesFn? pickFile;

  int _currentPageIndex = 0;
  static const int _pageCount = 4;

  // Scan state
  ScanStatus scanStatus = ScanStatus.none;
  _ScanKind _pendingScanKind = _ScanKind.none;
  List<String> scanPaths = const [];
  int added = 0;
  int failed = 0;
  bool permissionGranted = false;
  bool permissionDenied = false;
  int scanProgress = 0;
  int scanTotal = 0;

  // ---- Derived -----------------------------------------------------------

  int get pageCount => _pageCount;
  int get currentPageIndex => _currentPageIndex;
  bool get isFirstPage => _currentPageIndex == 0;
  bool get isLastPage => _currentPageIndex == _pageCount - 1;
  bool get isScanRunning => scanStatus == ScanStatus.running;

  Set<String> get _knownPaths => library.books.map((b) => b.path).toSet();

  // ---- Navigation --------------------------------------------------------

  void goTo(int index) {
    final target = index.clamp(0, _pageCount - 1);
    if (target == _currentPageIndex) return;
    _currentPageIndex = target;
    notifyListeners();
  }

  void goBack() => goTo(_currentPageIndex - 1);

  void skipToEnd() => goTo(_pageCount - 1);

  void nextPage() => goTo(_currentPageIndex + 1);

  // ---- Permission / scan -------------------------------------------------

  Future<void> grantAndProceed() async {
    final granted = await (requestPermission ?? ScanService.ensurePermission)();
    permissionGranted = granted;
    permissionDenied = !granted;
    if (granted) _pendingScanKind = _ScanKind.device;
    notifyListeners();
    goTo(2); // advance to theme
  }

  Future<void> startFolderScan() async {
    scanStatus = ScanStatus.running;
    permissionDenied = false;
    notifyListeners();
    skipToEnd(); // jump to import page
    await _startScan(
      scanFolder ??
          () async {
            final dir = await FilePicker.getDirectoryPath();
            if (dir == null) return const <String>[];
            return ScanService.scanFolder(dir, knownPaths: _knownPaths);
          },
    );
  }

  Future<void> runPendingScan() async {
    if (scanStatus != ScanStatus.none) return;
    switch (_pendingScanKind) {
      case _ScanKind.none:
        return;
      case _ScanKind.device:
        await _startScan(
          scanDevice ?? () => ScanService.scanDevice(knownPaths: _knownPaths),
        );
      case _ScanKind.folder:
        await _startScan(
          scanFolder ??
              () async {
                final dir = await FilePicker.getDirectoryPath();
                if (dir == null) return const <String>[];
                return ScanService.scanFolder(dir, knownPaths: _knownPaths);
              },
        );
    }
  }

  Future<void> pickAndImport() async {
    final paths =
        await (pickFile ??
            () async {
              final files = await FilePicker.pickFiles(
                type: FileType.custom,
                allowedExtensions: const ['epub', 'txt', 'pdf'],
              );
              return files.map((f) => f.path).whereType<String>().toList();
            })();
    if (paths.isEmpty) return;
    final (addedResult, failedResult) = await BookImporter.importPaths(
      library,
      paths,
    );
    scanStatus = ScanStatus.done;
    scanPaths = paths;
    added = addedResult.length;
    failed = failedResult;
    notifyListeners();
  }

  // ---- Internal helpers --------------------------------------------------

  Future<void> _startScan(Future<List<String>> Function() scan) async {
    scanStatus = ScanStatus.running;
    permissionDenied = false;
    _pendingScanKind = _ScanKind.none;
    scanProgress = 0;
    scanTotal = 0;
    notifyListeners();

    try {
      final (paths, addedList, failedCount) = await BookImporter.runScan(
        library,
        scan(),
        onScanComplete: (pathCount) {
          scanTotal = pathCount;
          scanProgress = 0;
          notifyListeners();
        },
        onProgress: (completed, total) {
          scanProgress = completed;
          scanTotal = total;
          notifyListeners();
        },
      );
      scanStatus = ScanStatus.done;
      scanPaths = paths;
      added = addedList.length;
      failed = failedCount;
      scanProgress = 0;
      scanTotal = 0;
    } catch (_) {
      scanStatus = ScanStatus.error;
      scanProgress = 0;
      scanTotal = 0;
    }
    notifyListeners();
  }

  /// Hands off a pending device scan to [LibraryService] so it continues
  /// after the onboarding screen is disposed. Call this when the user taps
  /// "Browse library" while a scan is still running.
  void handOffScanToLibrary() {
    if (_pendingScanKind == _ScanKind.none) return;
    final scan = _pendingScanKind == _ScanKind.device
        ? (scanDevice ?? () => ScanService.scanDevice(knownPaths: _knownPaths))
        : (scanFolder ??
              () async {
                final dir = await FilePicker.getDirectoryPath();
                if (dir == null) return const <String>[];
                return ScanService.scanFolder(dir, knownPaths: _knownPaths);
              });
    _pendingScanKind = _ScanKind.none;
    library.startBackgroundScan(scan());
  }
}
