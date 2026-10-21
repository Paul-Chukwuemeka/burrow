import 'package:flutter/material.dart';

import '../services/library_service.dart';
import '../services/onboarding_analytics.dart';
import '../services/onboarding_flow_controller.dart';
import '../widgets/onboarding/import_body.dart';
import '../widgets/onboarding/onboarding_stage.dart';
import '../widgets/onboarding/scan_status_bar.dart';
import '../widgets/onboarding/squishy_button.dart';
import '../widgets/onboarding/theme_picker.dart';

export '../services/onboarding_flow_controller.dart'
    show PickFilesFn, ScanFn, PermissionFn;

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
    this.pickFolder,
    this.scanDevice,
    this.scanFolder,
    this.pickFile,
  });

  final LibraryService library;
  final void Function(BuildContext context) onDone;

  /// Test/injection overrides for the platform-backed pieces.
  final PermissionFn? requestPermission;
  final Future<String?> Function()? pickFolder;
  final ScanFn? scanDevice;
  final ScanFn? scanFolder;
  final PickFilesFn? pickFile;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  late final OnboardingFlowController _ctrl;
  late final PageController _page;
  final _analytics = OnboardingAnalytics.instance;
  DateTime? _flowStartedAt;

  @override
  void initState() {
    super.initState();
    _flowStartedAt = DateTime.now();
    _ctrl = OnboardingFlowController(
      library: widget.library,
      requestPermission: widget.requestPermission,
      pickFolder: widget.pickFolder,
      scanDevice: widget.scanDevice,
      scanFolder: widget.scanFolder,
      pickFile: widget.pickFile,
    );
    _page = PageController();
    _ctrl.addListener(_onControllerUpdate);
    _analytics.onboardingStarted();
    _analytics.pageViewed(0, 'welcome');
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onControllerUpdate);
    _ctrl.dispose();
    _page.dispose();
    super.dispose();
  }

  void _onControllerUpdate() {
    // A running scan ("settling in…") goes straight to the library; the
    // scan keeps importing in the background.
    if (_ctrl.scanStatus == ScanStatus.running) {
      _finishOnce();
      return;
    }
    // Sync the PageView to the controller's current index.
    if (_page.hasClients && _page.page?.round() != _ctrl.currentPageIndex) {
      _page.animateToPage(
        _ctrl.currentPageIndex,
        duration: const Duration(milliseconds: 520),
        curve: Easing.emphasizedDecelerate,
      );
    }
    setState(() {});
  }

  LibraryService get _lib => widget.library;

  void _finish() {
    final elapsed = _flowStartedAt != null
        ? DateTime.now().difference(_flowStartedAt!).inMilliseconds
        : 0;
    _analytics.onboardingCompleted(totalDurationMs: elapsed);
    widget.onDone(context);
  }

  bool _finished = false;

  /// Finishes onboarding at most once; progress callbacks from the
  /// background scan keep firing after the screen is gone.
  void _finishOnce() {
    if (_finished || !mounted) return;
    _finished = true;
    _finish();
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

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
                  _ctrl.goTo(i);
                  _analytics.pageViewed(i, _pageName(i));
                  if (i == 3) _ctrl.runPendingScan();
                },
                itemCount: _ctrl.pageCount,
                itemBuilder: (context, i) => _pageBody(context, i),
              ),
            ),
            if (_ctrl.isScanRunning)
              ScanStatusBar(
                completed: _ctrl.scanProgress,
                total: _ctrl.scanTotal,
              ),
            _controls(context),
          ],
        ),
      ),
    );
  }

  String _pageName(int i) => switch (i) {
    0 => 'welcome',
    1 => 'permission',
    2 => 'theme',
    3 => 'import',
    _ => 'unknown',
  };

  Widget _topBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 12, 0),
      child: Row(
        children: [
          SizedBox(
            width: 48,
            height: 48,
            child: !_ctrl.isFirstPage
                ? IconButton(
                    icon: const Icon(Icons.arrow_back_rounded),
                    tooltip: 'Back',
                    onPressed: () {
                      _ctrl.goBack();
                      _page.animateToPage(
                        _ctrl.currentPageIndex,
                        duration: const Duration(milliseconds: 520),
                        curve: Easing.emphasizedDecelerate,
                      );
                    },
                  )
                : null,
          ),
          const Spacer(),
          if (!_ctrl.isLastPage)
            TextButton(
              onPressed: () {
                _analytics.skippedFrom(_ctrl.currentPageIndex);
                _ctrl.skipToEnd();
                _page.animateToPage(
                  _ctrl.currentPageIndex,
                  duration: const Duration(milliseconds: 520),
                  curve: Easing.emphasizedDecelerate,
                );
              },
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
          buildStage(
            context,
            i,
            animateEntrance: i == 0,
            showPermissionCheck: i == 1 && _ctrl.permissionGranted,
            showScanCheck: i == 2 && _ctrl.scanStatus == ScanStatus.done,
          ),
          const SizedBox(height: 40),
          _headline(context, i),
          const SizedBox(height: 12),
          _body(context, i),
          const SizedBox(height: 28),
          if (i == 2) _preferences(context),
          if (i == 3) _importBody(context),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  String _title(int i) => switch (i) {
    0 => 'burrow',
    1 => 'let burrow find your books',
    2 => 'make it yours',
    3 => switch (_ctrl.scanStatus) {
      ScanStatus.running => 'settling in…',
      ScanStatus.done =>
        _ctrl.scanPaths.isEmpty
            ? 'no new books found'
            : 'found ${_ctrl.scanPaths.length} books',
      ScanStatus.error => 'something went wrong',
      ScanStatus.none => 'your den is waiting',
    },
    _ => '',
  };

  String _subtitle(int i) => switch (i) {
    0 => 'a cozy den for all your books.',
    1 => 'we only look for your books — nothing leaves your device.',
    2 => 'what feels like reading?',
    3 => switch (_ctrl.scanStatus) {
      ScanStatus.running => 'scanning your device…',
      ScanStatus.done =>
        '${_ctrl.added} added${_ctrl.failed > 0 ? ' · ${_ctrl.failed} unreadable' : ''}.',
      ScanStatus.error => 'you can still add books one at a time.',
      ScanStatus.none => 'add one book and make it yours.',
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

  Widget _preferences(BuildContext context) {
    return ThemePicker(library: _lib, onChanged: () => setState(() {}));
  }

  Widget _importBody(BuildContext context) {
    return ImportBody(
      scanStatus: _ctrl.scanStatus,
      permissionDenied: _ctrl.permissionDenied,
    );
  }

  // -------------------------------------------------------------------------
  // Controls
  // -------------------------------------------------------------------------

  Widget _controls(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < _ctrl.pageCount; i++)
              AnimatedContainer(
                duration: const Duration(milliseconds: 260),
                curve: Easing.emphasizedDecelerate,
                width: i == _ctrl.currentPageIndex ? 24 : 8,
                height: 8,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: i == _ctrl.currentPageIndex
                      ? scheme.primary
                      : scheme.outlineVariant.withValues(alpha: 0.5),
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
    return switch (_ctrl.currentPageIndex) {
      0 => [
        buildCta(context, 'Tuck in', () {
          _ctrl.nextPage();
          _page.animateToPage(
            _ctrl.currentPageIndex,
            duration: const Duration(milliseconds: 520),
            curve: Easing.emphasizedDecelerate,
          );
        }),
      ],
      1 => [
        _ctrl.permissionGranted
            ? buildCta(context, 'Continue', () {
                _ctrl.nextPage();
                _page.animateToPage(
                  _ctrl.currentPageIndex,
                  duration: const Duration(milliseconds: 520),
                  curve: Easing.emphasizedDecelerate,
                );
              })
            : buildCta(context, 'Find my books', () {
                _analytics.permissionGranted();
                _ctrl.grantAndProceed();
              }),
        const SizedBox(height: 10),
        buildCta(
          context,
          'Choose a folder instead',
          _ctrl.startFolderScan,
          variant: CtaVariant.outlined,
        ),
        const SizedBox(height: 6),
        buildCta(context, 'Skip for now', () {
          _analytics.skippedFrom(1);
          _ctrl.skipToEnd();
          _page.animateToPage(
            _ctrl.currentPageIndex,
            duration: const Duration(milliseconds: 520),
            curve: Easing.emphasizedDecelerate,
          );
        }, variant: CtaVariant.text),
      ],
      2 => [
        buildCta(context, 'Next', () {
          _ctrl.nextPage();
          _page.animateToPage(
            _ctrl.currentPageIndex,
            duration: const Duration(milliseconds: 520),
            curve: Easing.emphasizedDecelerate,
          );
        }),
      ],
      3 => switch (_ctrl.scanStatus) {
        ScanStatus.running => [
          buildCta(context, 'Browse library', () {
            _ctrl.handOffScanToLibrary();
            // Scan callbacks can concurrently fire _finishOnce(); guard the
            // CTA the same way so onDone navigation never runs twice.
            _finishOnce();
          }),
          const SizedBox(height: 6),
          buildCta(context, 'Scanning…', null, variant: CtaVariant.text),
        ],
        ScanStatus.done ||
        ScanStatus.error => [buildCta(context, 'Open your burrow', _finish)],
        ScanStatus.none => [
          buildCta(context, 'Add your first book', _ctrl.pickAndImport),
          const SizedBox(height: 6),
          buildCta(
            context,
            'Open your burrow',
            _finish,
            variant: CtaVariant.text,
          ),
        ],
      },
      _ => [buildCta(context, 'Open your burrow', _finish)],
    };
  }
}
