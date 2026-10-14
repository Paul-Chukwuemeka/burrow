import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import 'db/database.dart';
import 'models/reader_settings.dart';
import 'screens/library_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/splash_screen.dart';
import 'services/dictionary_service.dart';
import 'services/library_service.dart';
import 'src/rust/frb_generated.dart';
import 'theme/burrow_tokens.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The default content engine is the native Rust parser (engine flag `rust`,
  // design D8). Its FFI binding must be initialized on this isolate before any
  // engine call — without this every EPUB open and OPF metadata extraction
  // fails with "flutter_rust_bridge has not been initialized".
  try {
    await RustLib.init();
  } catch (e) {
    debugPrint('Rust engine unavailable: $e');
  }
  runApp(const BurrowApp());
}

class BurrowApp extends StatefulWidget {
  const BurrowApp({super.key, this.library});

  /// Test seam: when provided, this library is used instead of building and
  /// loading a fresh one, and the heavy plugin initialization is skipped.
  final LibraryService? library;

  @override
  State<BurrowApp> createState() => _BurrowAppState();
}

class _BurrowAppState extends State<BurrowApp> {
  LibraryService? _library;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _library?.addListener(_onThemeChanged);
    });
  }

  @override
  void dispose() {
    _library?.removeListener(_onThemeChanged);
    _library?.dispose();
    DictionaryService.instance.close();
    super.dispose();
  }

  void _onThemeChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final library = _library;
    final appMode = library?.settings.appThemeMode;
    final isOled = appMode == AppThemeMode.oled;
    final settings = library?.settings;

    return MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(settings?.uiTextScale ?? 1.0)),
      child: MaterialApp(
        title: 'burrow',
        debugShowCheckedModeBanner: false,
        theme: _expressiveTheme(
          ColorScheme.fromSeed(seedColor: const Color(0xFF2E6E4E)),
          uiFontFamily: settings?.uiFontFamily,
        ),
        darkTheme: _expressiveTheme(
          isOled
              ? ColorScheme.fromSeed(
                  seedColor: const Color(0xFF2E6E4E),
                  brightness: Brightness.dark,
                ).copyWith(
                  surface: Colors.black,
                  surfaceContainerLow: const Color(0xFF0A0A0A),
                  surfaceContainer: const Color(0xFF111111),
                  surfaceContainerHigh: const Color(0xFF1A1A1A),
                  surfaceContainerHighest: const Color(0xFF222222),
                )
              : ColorScheme.fromSeed(
                  seedColor: const Color(0xFF2E6E4E),
                  brightness: Brightness.dark,
                ),
          uiFontFamily: settings?.uiFontFamily,
        ),
        themeMode: library != null
            ? AppTheme.byMode(appMode!).brightness == Brightness.light
                  ? ThemeMode.light
                  : ThemeMode.dark
            : ThemeMode.system,
        home: SplashScreen(onReady: _buildHome),
      ),
    );
  }

  Future<Widget> _buildHome(BuildContext context) async {
    // Heavy initialization runs while the splash is visible.
    // Never throw: a rejected future bricks the splash (infinite spinner),
    // so failures degrade to a retryable error screen instead.
    try {
      final injected = widget.library;
      if (injected == null) {
        await PdfrxEntryFunctions.instance.init();
        await DictionaryService.instance.init();
      }
      final library = injected ?? LibraryService();
      _library = library;
      library.addListener(_onThemeChanged);
      if (injected == null) {
        try {
          await library.load();
        } catch (e) {
          library.removeListener(_onThemeChanged);
          library.dispose();
          // Don't dispose the injected/test instance; only our own partial.
          _library = null;
          debugPrint('Library load failed: $e');
          return _StartupErrorScreen(
            message: 'Could not open your library ($e)',
            onRetry: () => _retryStartup(context),
            onReset: () => _resetLibrary(context),
          );
        }
        // Finish metadata extraction for books left incomplete by an
        // interrupted scan/import.
        library.resumeMetadataExtraction();
      }

      if (library.onboardingComplete) {
        return LibraryScreen(library: library);
      }
      return OnboardingScreen(
        library: library,
        onDone: (context) {
          library.markOnboardingComplete();
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => LibraryScreen(library: library)),
          );
        },
      );
    } catch (e) {
      debugPrint('Startup failed: $e');
      return _StartupErrorScreen(
        message: 'Startup failed ($e)',
        onRetry: () => _retryStartup(context),
        onReset: () => _resetLibrary(context),
      );
    }
  }

  Future<void> _retryStartup(BuildContext context) async {
    final home = await _buildHome(context);
    if (!context.mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => home),
    );
  }

  Future<void> _resetLibrary(BuildContext context) async {
    // Dispose any partial library state before wiping the DB.
    _library?.removeListener(_onThemeChanged);
    _library?.dispose();
    _library = null;
    await AppDatabase.deleteDatabaseFile();
    // Clear the legacy snapshot + covers so load() can't resurrect them.
    await LibraryService.clearResetState();
    // Also clear the PDF plugin cache so a corrupt cache can't block startup.
    final home = await _buildHome(context);
    if (!context.mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => home),
    );
  }

  // Material 3 Expressive-flavoured foundation: Roboto Flex variable type,
  // generous corner radii, tonal surfaces, squircle-ish FABs and springy ink.
  ThemeData _expressiveTheme(ColorScheme scheme, {String? uiFontFamily}) {
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      fontFamily: uiFontFamily ?? 'Fraunces',
      splashFactory: InkSparkle.splashFactory,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        scrolledUnderElevation: 0,
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        shape: RoundedRectangleBorder(borderRadius: Burrow.r(Burrow.shapeLg)),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: Burrow.r(Burrow.shapeSm)),
        side: BorderSide(color: scheme.outlineVariant),
        labelPadding: const EdgeInsets.symmetric(horizontal: 2),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLow,
        shape: RoundedSuperellipseBorder(
          borderRadius: Burrow.r(Burrow.shapeMd),
        ),
        margin: EdgeInsets.zero,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: Burrow.r(Burrow.shapeSm + 4),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        showDragHandle: true,
        backgroundColor: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Burrow.r(Burrow.shapeXl).topLeft,
          ),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        linearTrackColor: scheme.primaryContainer,
        circularTrackColor: scheme.primaryContainer,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant),
    );
  }
}

/// Shown when startup initialization fails instead of leaving the splash
/// spinning forever. Retry re-runs [_BurrowAppState._buildHome].
class _StartupErrorScreen extends StatelessWidget {
  const _StartupErrorScreen({
    required this.message,
    required this.onRetry,
    this.onReset,
  });

  final String message;
  final VoidCallback onRetry;
  final VoidCallback? onReset;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48),
              const SizedBox(height: 16),
              const Text('Something went wrong'),
              const SizedBox(height: 8),
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: onRetry, child: const Text('Retry')),
              if (onReset != null) ...[
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: onReset,
                  child: const Text('Reset library'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
