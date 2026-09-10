import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models/reader_settings.dart';
import 'screens/library_screen.dart';
import 'screens/onboarding_screen.dart';
import 'services/dictionary_service.dart';
import 'services/library_service.dart';
import 'theme/burrow_tokens.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // PDF renderer — non-fatal if it fails; PDFs will be unavailable.
  try {
    await PdfrxEntryFunctions.instance.init();
  } catch (e) {
    debugPrint('Pdfrx init failed (PDFs unavailable): $e');
  }

  // Dictionary — non-fatal if it fails; lookups will be disabled.
  try {
    await DictionaryService.instance.init();
  } catch (e) {
    debugPrint('Dictionary init failed (lookups disabled): $e');
  }

  // Library — fatal on first attempt, but we try to recover from corrupted data.
  var library = LibraryService();
  try {
    await library.load();
  } catch (e) {
    debugPrint('Library load failed, attempting recovery: $e');
    library.dispose();
    // Delete the corrupted database and clear corrupted SharedPreferences.
    try {
      final dir = await getApplicationDocumentsDirectory();
      final dbFile = File('${dir.path}/burrow.db');
      if (await dbFile.exists()) await dbFile.delete();
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
    } catch (_) {}
    // Retry with a fresh database.
    library = LibraryService();
    try {
      await library.load();
    } catch (e2) {
      debugPrint('Library load failed after recovery: $e2');
    }
  }

  runApp(BurrowApp(library: library));
}

class BurrowApp extends StatefulWidget {
  const BurrowApp({super.key, required this.library});

  final LibraryService library;

  @override
  State<BurrowApp> createState() => _BurrowAppState();
}

class _BurrowAppState extends State<BurrowApp> {
  late Widget _home;

  @override
  void initState() {
    super.initState();
    _home = _buildHome();
    widget.library.addListener(_onThemeChanged);
  }

  @override
  void dispose() {
    widget.library.removeListener(_onThemeChanged);
    widget.library.dispose();
    DictionaryService.instance.close();
    super.dispose();
  }

  void _onThemeChanged() {
    if (mounted) setState(() {});
  }

  Widget _buildHome() {
    final library = widget.library;
    if (library.onboardingComplete) {
      return LibraryScreen(library: library);
    }
    return OnboardingScreen(library: library, onDone: _finishOnboarding);
  }

  /// Called when the onboarding flow finishes: persist the flag and swap the
  /// home widget to the library.
  void _finishOnboarding() {
    widget.library.markOnboardingComplete();
    if (!mounted) return;
    setState(() => _home = LibraryScreen(library: widget.library));
  }

  @override
  Widget build(BuildContext context) {
    final appMode = widget.library.settings.appThemeMode;
    final isOled = appMode == AppThemeMode.oled;
    final settings = widget.library.settings;
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(settings.uiTextScale),
      ),
      child: MaterialApp(
        title: 'burrow',
        debugShowCheckedModeBanner: false,
        theme: _expressiveTheme(
          ColorScheme.fromSeed(seedColor: const Color(0xFF2E6E4E)),
          uiFontFamily: settings.uiFontFamily,
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
          uiFontFamily: settings.uiFontFamily,
        ),
        themeMode: AppTheme.byMode(appMode).brightness == Brightness.light
            ? ThemeMode.light
            : ThemeMode.dark,
        home: _home,
      ),
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
        shape: RoundedRectangleBorder(
          borderRadius: Burrow.r(Burrow.shapeLg),
        ),
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
        shape: RoundedSuperellipseBorder(borderRadius: Burrow.r(Burrow.shapeMd)),
        margin: EdgeInsets.zero,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: Burrow.r(Burrow.shapeSm + 4)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        showDragHandle: true,
        backgroundColor: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Burrow.r(Burrow.shapeXl).topLeft),
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
