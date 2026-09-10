import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/reader_settings.dart';
import '../services/import_helper.dart';
import '../services/library_service.dart';
import '../services/scan_service.dart';
import '../theme/burrow_tokens.dart';

/// Pick a set of files; returns absolute paths (empty when cancelled).
typedef PickFilesFn = Future<List<String>> Function();

/// Resolve a list of book paths (scan or folder walk).
typedef ScanFn = Future<List<String>> Function();

/// Request storage access; returns whether access was granted.
typedef PermissionFn = Future<bool> Function();

/// First-run welcome flow. Establishes the app's personality, seeds reader
/// preferences (theme + typeface) and gets the user to their first book with
/// as little friction as possible. Skipping optional steps lands you on the
/// import screen; the whole flow can be completed in a few taps.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({
    super.key,
    required this.library,
    required this.onDone,
    this.requestPermission,
    this.scanDevice,
    this.scanFolder,
    this.pickFile,
  });

  final LibraryService library;
  final VoidCallback onDone;

  /// Test/injection overrides for the platform-backed pieces.
  final PermissionFn? requestPermission;
  final ScanFn? scanDevice;
  final ScanFn? scanFolder;
  final PickFilesFn? pickFile;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

enum _ScanStatus { none, running, done, error }

enum _ScanKind { none, device, folder }

class _OnboardingScreenState extends State<OnboardingScreen> {
  static const _pageCount = 5;

  final PageController _page = PageController();
  int _current = 0;

  _ScanStatus _scanStatus = _ScanStatus.none;
  _ScanKind _pendingScanKind = _ScanKind.none;
  List<String> _scanPaths = const [];
  int _added = 0;
  int _failed = 0;
  bool _permissionGranted = false;
  bool _permissionDenied = false;
  int _scanProgress = 0;
  int _scanTotal = 0;

  /// Formats the user wants scanned (extensions with leading dot).
  late Set<String> _selectedFormats;

  @override
  void initState() {
    super.initState();
    _selectedFormats = Set.from(ScanService.defaultExtensions);
  }

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  LibraryService get _lib => widget.library;

  Set<String> get _knownPaths => _lib.books.map((b) => b.path).toSet();

  void _goTo(int index) {
    final target = index.clamp(0, _pageCount - 1);
    if (target == _current) return;
    _page.animateToPage(
      target,
      duration: const Duration(milliseconds: 520),
      curve: Easing.emphasizedDecelerate,
    );
  }

  // -------------------------------------------------------------------------
  // Theme seeding
  // -------------------------------------------------------------------------

  void _selectAppTheme(AppThemeMode mode) {
    _lib.settings.appThemeMode = mode;
    _lib.saveSettings();
    setState(() {});
  }

  // -------------------------------------------------------------------------
  // Import / permission
  // -------------------------------------------------------------------------

  /// Requests storage access, then advances to the format selection page.
  /// The device scan itself is deferred until the import page becomes active
  /// so the user sees one calm setup step at a time.
  Future<void> _grantAndProceed() async {
    final granted =
        await (widget.requestPermission ?? ScanService.ensurePermission)();
    if (!mounted) return;
    setState(() {
      _permissionGranted = granted;
      _permissionDenied = !granted;
      if (granted) _pendingScanKind = _ScanKind.device;
    });
    _goTo(2);
  }

  Future<void> _startFolderScan() async {
    setState(() {
      _scanStatus = _ScanStatus.running;
      _permissionDenied = false;
    });
    _goTo(4);
    await _startScan(
      widget.scanFolder ??
          () async {
            final dir = await FilePicker.getDirectoryPath();
            if (dir == null) return const <String>[];
            return ScanService.scanFolder(
              dir,
              knownPaths: _knownPaths,
              extensions: _selectedFormats,
            );
          },
    );
  }

  Future<void> _runPendingScan() async {
    if (_scanStatus != _ScanStatus.none) return;
    switch (_pendingScanKind) {
      case _ScanKind.none:
        return;
      case _ScanKind.device:
        await _startScan(
          widget.scanDevice ??
              () => ScanService.scanDevice(
                    knownPaths: _knownPaths,
                    extensions: _selectedFormats,
                  ),
        );
      case _ScanKind.folder:
        await _startScan(
          widget.scanFolder ??
              () async {
                final dir = await FilePicker.getDirectoryPath();
                if (dir == null) return const <String>[];
                return ScanService.scanFolder(
                  dir,
                  knownPaths: _knownPaths,
                  extensions: _selectedFormats,
                );
              },
        );
    }
  }

  Future<void> _startScan(Future<List<String>> Function() scan) async {
    setState(() {
      _scanStatus = _ScanStatus.running;
      _permissionDenied = false;
      _pendingScanKind = _ScanKind.none;
      _scanProgress = 0;
      _scanTotal = 0;
    });
    
    try {
      final (paths, added, failed) = await BookImporter.runScan(
        _lib,
        scan(),
        onScanComplete: (pathCount) {
          if (!mounted) return;
          setState(() {
            _scanTotal = pathCount;
            _scanProgress = 0;
          });
        },
        onProgress: (completed, total) {
          if (!mounted) return;
          setState(() {
            _scanProgress = completed;
            _scanTotal = total;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _scanStatus = _ScanStatus.done;
        _scanPaths = paths;
        _added = added.length;
        _failed = failed;
        _scanProgress = 0;
        _scanTotal = 0;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _scanStatus = _ScanStatus.error;
        _scanProgress = 0;
        _scanTotal = 0;
      });
    }
  }

  Future<void> _pickAndImport() async {
    final paths = await (widget.pickFile ??
        () async {
          final files = await FilePicker.pickFiles(
            type: FileType.custom,
            allowedExtensions: const ['epub', 'txt', 'pdf'],
          );
          return files.map((f) => f.path).whereType<String>().toList();
        })();
    if (paths.isEmpty || !mounted) return;
    final (added, failed) = await BookImporter.importPaths(_lib, paths);
    if (!mounted) return;
    setState(() {
      _scanStatus = _ScanStatus.done;
      _scanPaths = paths;
      _added = added.length;
      _failed = failed;
    });
  }

  void _finish() => widget.onDone();

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final spec = _specFor(scheme, _current);

    return Scaffold(
      backgroundColor: scheme.surface,
      body: SafeArea(
        child: Column(
          children: [
            _topBar(context),
            Expanded(
              child: PageView.builder(
                controller: _page,
                physics: const BouncingScrollPhysics(),
                onPageChanged: (i) {
                  setState(() => _current = i);
                  if (i == 4) _runPendingScan();
                },
                itemCount: _pageCount,
                itemBuilder: (context, i) => _pageBody(context, i),
              ),
            ),
            if (_scanStatus == _ScanStatus.running)
              _ScanStatusBar(
                completed: _scanProgress,
                total: _scanTotal,
              ),
            _controls(context, spec),
          ],
        ),
      ),
    );
  }

  Widget _topBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 12, 0),
      child: Row(
        children: [
          SizedBox(
            width: 48,
            height: 48,
            child: _current > 0
                ? IconButton(
                    icon: const Icon(Icons.arrow_back_rounded),
                    tooltip: 'Back',
                    onPressed: () => _goTo(_current - 1),
                  )
                : null,
          ),
          const Spacer(),
          if (_current < _pageCount - 1)
            TextButton(
              onPressed: () => _goTo(_pageCount - 1),
              child: const Text('Skip'),
            )
          else
            const SizedBox(width: 72),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Page bodies
  // -------------------------------------------------------------------------

  Widget _pageBody(BuildContext context, int i) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        children: [
          const SizedBox(height: 28),
          _stage(context, i),
          const SizedBox(height: 40),
          _headline(context, i),
          const SizedBox(height: 12),
          _body(context, i),
          const SizedBox(height: 28),
          if (i == 3) _preferences(context),
          if (i == 4) _importBody(context),
          if (i == 1) _formatChips(context),
          if (i == 2) _formatSelection(context),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  String _title(int i) => switch (i) {
        0 => 'burrow',
        1 => 'let burrow find your books',
        2 => 'what formats do you read?',
        3 => 'make it yours',
        4 => switch (_scanStatus) {
            _ScanStatus.running => 'settling in…',
            _ScanStatus.done => _scanPaths.isEmpty
                ? 'no new books found'
                : 'found ${_scanPaths.length} books',
            _ScanStatus.error => 'something went wrong',
            _ScanStatus.none => 'your den is waiting',
          },
        _ => '',
      };

  String _subtitle(int i) => switch (i) {
        0 => 'a cozy den for all your books.',
        1 => 'we only look for your books — nothing leaves your device.',
        2 => 'pick the types you want to scan for.',
        3 => 'what feels like reading?',
        4 => switch (_scanStatus) {
            _ScanStatus.running => 'scanning your device…',
            _ScanStatus.done =>
              '$_added added${_failed > 0 ? ' · $_failed unreadable' : ''}.',
            _ScanStatus.error => 'you can still add books one at a time.',
            _ScanStatus.none => 'add one book and make it yours.',
          },
        _ => '',
      };

  Widget _headline(BuildContext context, int i) {
    final scheme = Theme.of(context).colorScheme;
    final isWordmark = i == 0;
    return Text(
      _title(i),
      textAlign: TextAlign.center,
      style: TextStyle(
        fontFamily: 'Fraunces',
        fontSize: isWordmark ? 56 : 34,
        height: isWordmark ? 1.0 : 1.1,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.6,
        color: scheme.onSurface,
      ),
    );
  }

  Widget _body(BuildContext context, int i) {
    final scheme = Theme.of(context).colorScheme;
    return Text(
      _subtitle(i),
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
            fontSize: 15,
            height: 1.45,
          ),
    );
  }

  Widget _formatChips(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget chip(String label, Color bg, Color fg) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(99),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: fg,
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.6,
            ),
          ),
        );
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        chip('EPUB', scheme.primaryContainer, scheme.onPrimaryContainer),
        const SizedBox(width: 8),
        chip('TXT', const Color(0xFFFFE3BC), const Color(0xFF5A421A)),
        const SizedBox(width: 8),
        chip('PDF', const Color(0xFFFFDACF), const Color(0xFF66241A)),
      ],
    );
  }

  Widget _formatSelection(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final formats = [
      ('.epub', 'EPUB', Icons.menu_book_rounded, scheme.primaryContainer, scheme.onPrimaryContainer),
      ('.txt', 'TXT', Icons.description_outlined, const Color(0xFFFFE3BC), const Color(0xFF5A421A)),
      ('.pdf', 'PDF', Icons.picture_as_pdf_rounded, const Color(0xFFFFDACF), const Color(0xFF66241A)),
      ('.cbz', 'CBZ', Icons.collections_rounded, const Color(0xFFE8DEF8), const Color(0xFF4A3560)),
      ('.cbr', 'CBR', Icons.collections_rounded, const Color(0xFFD0E8E0), const Color(0xFF1A4A3A)),
    ];

    return Wrap(
      spacing: 10,
      runSpacing: 10,
      alignment: WrapAlignment.center,
      children: formats.map((f) {
        final (ext, label, icon, bg, fg) = f;
        final selected = _selectedFormats.contains(ext);
        return GestureDetector(
          onTap: () {
            setState(() {
              if (selected) {
                _selectedFormats.remove(ext);
              } else {
                _selectedFormats.add(ext);
              }
            });
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: selected ? bg : scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(99),
              border: Border.all(
                color: selected ? fg.withValues(alpha: 0.4) : scheme.outlineVariant.withValues(alpha: 0.5),
                width: selected ? 2 : 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  selected ? Icons.check_circle_rounded : icon,
                  size: 18,
                  color: selected ? fg : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: TextStyle(
                    color: selected ? fg : scheme.onSurfaceVariant,
                    fontSize: 14,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _preferences(BuildContext context) {
    return Column(
      children: [
        _appThemeGrid(context),
      ],
    );
  }

  Widget _appThemeGrid(BuildContext context) {
    return Row(
      children: [
        Expanded(child: _appThemeCard(context, AppThemeMode.light)),
        const SizedBox(width: 12),
        Expanded(child: _appThemeCard(context, AppThemeMode.dark)),
        const SizedBox(width: 12),
        Expanded(child: _appThemeCard(context, AppThemeMode.oled)),
      ],
    );
  }

  Widget _appThemeCard(BuildContext context, AppThemeMode mode) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _lib.settings.appThemeMode == mode;
    final preview = switch (mode) {
      AppThemeMode.light => const Color(0xFFFAFAF7),
      AppThemeMode.dark => const Color(0xFF121212),
      AppThemeMode.oled => const Color(0xFF000000),
    };
    final label = switch (mode) {
      AppThemeMode.light => 'Light',
      AppThemeMode.dark => 'Dark',
      AppThemeMode.oled => 'OLED',
    };
    final icon = switch (mode) {
      AppThemeMode.light => Icons.light_mode_outlined,
      AppThemeMode.dark => Icons.dark_mode_outlined,
      AppThemeMode.oled => Icons.lens_blur_outlined,
    };
    final onPreview = switch (mode) {
      AppThemeMode.light => const Color(0xFF1A1A1A),
      _ => const Color(0xFFE6E6E1),
    };
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _selectAppTheme(mode),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Easing.emphasizedDecelerate,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: Burrow.r(18),
          border: Border.all(
            color: selected ? scheme.primary : scheme.outlineVariant.withValues(alpha: 0.5),
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            AnimatedScale(
              scale: selected ? 1.06 : 1,
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutBack,
              child: Container(
                height: 92,
                decoration: BoxDecoration(
                  color: preview,
                  borderRadius: Burrow.r(12),
                  border: Border.all(
                    color: onPreview.withValues(alpha: 0.15),
                  ),
                ),
                child: Center(
                  child: Icon(icon, size: 32, color: onPreview.withValues(alpha: 0.6)),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _importBody(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    switch (_scanStatus) {
      case _ScanStatus.running:
        return const SizedBox.shrink();
      case _ScanStatus.done:
        return const SizedBox.shrink();
      case _ScanStatus.error:
      case _ScanStatus.none:
        if (_permissionDenied) {
          return Text(
            'no storage access? you can still add books one at a time, '
            'or pick a folder instead.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              color: scheme.onSurfaceVariant,
              fontStyle: FontStyle.italic,
            ),
          );
        }
        return const SizedBox.shrink();
    }
  }

  // -------------------------------------------------------------------------
  // Stage + morph
  // -------------------------------------------------------------------------

  _StageSpec _specFor(ColorScheme s, int i) => switch (i) {
        0 => _StageSpec(
            w: 210, h: 210, radius: 74,
            bg: s.primaryContainer, fg: s.onPrimaryContainer,
            icon: Icons.auto_stories_outlined),
        1 => _StageSpec(
            w: 168, h: 134, radius: 32,
            bg: s.secondaryContainer, fg: s.onSecondaryContainer,
            icon: Icons.folder_open_rounded),
        2 => _StageSpec(
            w: 152, h: 152, radius: 28,
            bg: s.tertiaryContainer, fg: s.onTertiaryContainer,
            icon: Icons.tune_rounded),
        3 => _StageSpec(
            w: 152, h: 152, radius: 28,
            bg: s.primaryContainer, fg: s.onPrimaryContainer,
            icon: Icons.menu_book_rounded),
        _ => _StageSpec(
            w: 174, h: 152, radius: 30,
            bg: s.secondaryContainer, fg: s.onSecondaryContainer,
            icon: Icons.layers_outlined),
      };

  /// The shared-element "den": one container that morphs its size, shape and
  /// fill between pages so the flow reads as a single object travelling
  /// through (den → folder → book → pages → shelf).
  Widget _stage(BuildContext context, int i) {
    final scheme = Theme.of(context).colorScheme;
    final spec = _specFor(scheme, i);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 540),
      curve: Easing.emphasizedDecelerate,
      width: spec.w,
      height: spec.h,
      decoration: ShapeDecoration(
        color: spec.bg,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(spec.radius),
        ),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (i == 0)
            _denGraphic(scheme)
          else
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: Icon(
                spec.icon,
                key: ValueKey(spec.icon),
                size: spec.w * 0.42,
                color: spec.fg,
              ),
            ),
          if (i == 3 && _scanStatus == _ScanStatus.done)
            Positioned(
              right: 6,
              bottom: 6,
              child: Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: scheme.primary,
                  shape: BoxShape.circle,
                  border: Border.all(color: scheme.surface, width: 3),
                ),
                child: Icon(Icons.check_rounded, size: 20, color: scheme.onPrimary),
              ),
            ),
          if (i == 1 && _permissionGranted)
            Positioned(
              right: 6,
              bottom: 6,
              child: Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: scheme.primary,
                  shape: BoxShape.circle,
                  border: Border.all(color: scheme.surface, width: 3),
                ),
                child: Icon(Icons.check_rounded, size: 20, color: scheme.onPrimary),
              ),
            ),
        ],
      ),
    );
  }

  /// A page curled into a den: sepia page resting inside a moss ring, with a
  /// warm lamp dot — "burrowing into a book".
  Widget _denGraphic(ColorScheme scheme) {
    final sepia = ReaderTheme.sepia;
    return Stack(
      alignment: Alignment.center,
      children: [
        Transform.rotate(
          angle: -0.07,
          child: Container(
            width: 118,
            height: 172,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: sepia.background,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: sepia.muted.withValues(alpha: 0.4)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 7,
                  decoration: BoxDecoration(
                    color: sepia.muted.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(3.5),
                  ),
                ),
                const SizedBox(height: 10),
                for (final w in [72.0, 80.0, 66.0, 74.0, 58.0]) ...[
                  Container(
                    width: w,
                    height: 5,
                    decoration: BoxDecoration(
                      color: sepia.text.withValues(alpha: 0.22),
                      borderRadius: BorderRadius.circular(2.5),
                    ),
                  ),
                  const SizedBox(height: 6),
                ],
                const Spacer(),
                Container(
                  width: 54,
                  height: 5,
                  decoration: BoxDecoration(
                    color: sepia.accent,
                    borderRadius: BorderRadius.circular(2.5),
                  ),
                ),
              ],
            ),
          ),
        ),
        Positioned(
          right: 10,
          bottom: 16,
          child: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(color: scheme.tertiary, shape: BoxShape.circle),
            child: Icon(
              Icons.bedtime_rounded,
              size: 16,
              color: scheme.onTertiary,
            ),
          ),
        ),
      ],
    );
  }

  // -------------------------------------------------------------------------
  // Controls
  // -------------------------------------------------------------------------

  Widget _controls(BuildContext context, _StageSpec spec) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < _pageCount; i++)
              AnimatedContainer(
                duration: const Duration(milliseconds: 260),
                curve: Easing.emphasizedDecelerate,
                width: i == _current ? 24 : 8,
                height: 8,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: i == _current ? scheme.primary : scheme.outlineVariant.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
          ],
        ),
        const SizedBox(height: 20),
        ..._ctas(context),
        const SizedBox(height: 24),
      ],
    );
  }

  List<Widget> _ctas(BuildContext context) {
    return switch (_current) {
      0 => [
          _cta('Tuck in', () => _goTo(1)),
        ],
      1 => [
          _permissionGranted
              ? _cta('Continue', () => _goTo(2))
              : _cta('Find my books', _grantAndProceed),
          const SizedBox(height: 10),
          _cta(
            'Choose a folder instead',
            _startFolderScan,
            variant: _CtaVariant.outlined,
          ),
          const SizedBox(height: 6),
          _cta('Skip for now', () => _goTo(4), variant: _CtaVariant.text),
        ],
      2 => [
          _selectedFormats.isEmpty
              ? _cta('Skip for now', () => _goTo(3), variant: _CtaVariant.text)
              : _cta('Next', () => _goTo(3)),
        ],
      3 => [
          _cta('Next', () => _goTo(4)),
        ],
      4 => switch (_scanStatus) {
          _ScanStatus.running => [
              _cta('Browse library', _finish),
              const SizedBox(height: 6),
              _cta(
                'Scanning…',
                null,
                variant: _CtaVariant.text,
              ),
            ],
          _ScanStatus.done ||
          _ScanStatus.error =>
            [_cta('Open your burrow', _finish)],
          _ScanStatus.none => [
              _cta('Add your first book', _pickAndImport),
              const SizedBox(height: 6),
              _cta('Open your burrow', _finish, variant: _CtaVariant.text),
            ],
        },
      _ => [_cta('Open your burrow', _finish)],
    };
  }

  Widget _cta(
    String label,
    VoidCallback? onTap, {
    _CtaVariant variant = _CtaVariant.filled,
  }) {
    final scheme = Theme.of(context).colorScheme;
    const minSize = Size(260, 56);

    final style = switch (variant) {
      _CtaVariant.filled => FilledButton.styleFrom(
          minimumSize: minSize,
          shape: RoundedSuperellipseBorder(borderRadius: Burrow.r(Burrow.shapeLg)),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
      _CtaVariant.outlined => OutlinedButton.styleFrom(
          minimumSize: const Size(260, 50),
          shape: RoundedSuperellipseBorder(borderRadius: Burrow.r(Burrow.shapeLg)),
          foregroundColor: scheme.onSurfaceVariant,
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      _CtaVariant.text => TextButton.styleFrom(
          minimumSize: const Size(260, 44),
          foregroundColor: scheme.onSurfaceVariant,
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      _CtaVariant.disabled => FilledButton.styleFrom(
          minimumSize: minSize,
          shape: RoundedSuperellipseBorder(borderRadius: Burrow.r(Burrow.shapeLg)),
          disabledBackgroundColor: scheme.surfaceContainerHighest,
          disabledForegroundColor: scheme.onSurfaceVariant,
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
    };

    final button = switch (variant) {
      _CtaVariant.filled => FilledButton(
          onPressed: onTap,
          style: style,
          child: Text(label),
        ),
      _CtaVariant.outlined => OutlinedButton(
          onPressed: onTap,
          style: style,
          child: Text(label),
        ),
      _CtaVariant.text => TextButton(
          onPressed: onTap,
          style: style,
          child: Text(label),
        ),
      _CtaVariant.disabled => FilledButton(
          onPressed: null,
          style: style,
          child: Text(label),
        ),
    };

    if (variant == _CtaVariant.filled || variant == _CtaVariant.disabled) {
      return _Squishy(onTap: onTap, child: button);
    }
    return button;
  }
}

enum _CtaVariant { filled, outlined, text, disabled }

/// Press feedback for the primary CTA: the squircle squashes wider and
/// flatter under the finger, then springs back — like a pillow being sat on.
class _Squishy extends StatefulWidget {
  const _Squishy({required this.onTap, required this.child});

  final VoidCallback? onTap;
  final Widget child;

  @override
  State<_Squishy> createState() => _SquishyState();
}

class _SquishyState extends State<_Squishy>
    with SingleTickerProviderStateMixin {
  late final AnimationController _press = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 160),
  );

  @override
  void dispose() {
    _press.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _press.forward(),
      onPointerUp: (_) => _press.reverse(),
      onPointerCancel: (_) => _press.reverse(),
      child: AnimatedBuilder(
        animation: _press,
        builder: (context, child) {
          final t = Curves.easeOutBack.transform(_press.value);
          return Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()
              ..setEntry(0, 0, 1 + 0.045 * t)
              ..setEntry(1, 1, 1 - 0.09 * t),
            child: child,
          );
        },
        child: widget.child,
      ),
    );
  }
}

class _StageSpec {
  const _StageSpec({
    required this.w,
    required this.h,
    required this.radius,
    required this.bg,
    required this.fg,
    required this.icon,
  });

  final double w;
  final double h;
  final double radius;
  final Color bg;
  final Color fg;
  final IconData icon;
}

class _ScanStatusBar extends StatelessWidget {
  const _ScanStatusBar({
    required this.completed,
    required this.total,
  });

  final int completed;
  final int total;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = total > 0
        ? 'Importing books… $completed / $total'
        : 'Scanning for books…';

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(
          top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.3)),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: scheme.primary,
                  value: total > 0 ? completed / total : null,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  text,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
          if (total > 0) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(Burrow.shapeXs),
              child: LinearProgressIndicator(
                value: completed / total,
                minHeight: 4,
                backgroundColor: scheme.primaryContainer,
                color: scheme.primary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
