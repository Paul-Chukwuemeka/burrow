import 'package:flutter/material.dart';

/// Minimum brightness level (0–1). A low floor keeps the UI recoverable on
/// devices where the hardware minimum backlight is very dim.
const kMinBrightness = 0.05;

/// Marker for `ReaderSettings.defaultDictionary` meaning "define with the
/// built-in offline dictionary". Any other non-null value is an Android
/// package name of an external dictionary app.
const String burrowDefaultDictionary = 'burrow';

/// App-wide theme mode — controls the library, settings and chrome.
enum AppThemeMode { light, dark, oled }

/// Per-reader color scheme — chosen independently from the app theme.
enum ReaderThemeMode { light, sepia, dark, dusk, oled }

enum PdfLayoutDirection { vertical, horizontalLtr, horizontalRtl }

/// Reading mode for image-based comics (CBR/CBZ).
enum ComicReadingMode { paginated, vertical }

/// Scroll direction for paginated comics (CBR/CBZ).
enum ComicReadingDirection { ltr, rtl }

/// Text alignment for reflowable documents.
enum TextJustification { left, justify }

/// Image fit mode for comic pages.
enum ComicFitMode { contain, fitWidth, fitHeight }

/// Which scan runs when the user taps "Scan": a full device walk, a single
/// chosen folder, or a quick refresh of folders already in the library.
enum ScanMode { device, folder, quick }

/// App-level Material 3 brightness mapping.
class AppTheme {
  const AppTheme._({required this.brightness});

  final Brightness brightness;

  static const AppTheme light = AppTheme._(brightness: Brightness.light);
  static const AppTheme dark = AppTheme._(brightness: Brightness.dark);
  static const AppTheme oled = AppTheme._(brightness: Brightness.dark);

  static AppTheme byMode(AppThemeMode mode) => switch (mode) {
    AppThemeMode.light => light,
    AppThemeMode.dark => dark,
    AppThemeMode.oled => oled,
  };
}

class ReaderTheme {
  const ReaderTheme({
    required this.background,
    required this.text,
    required this.muted,
    required this.accent,
    required this.selection,
    required this.brightness,
  });

  final Color background;
  final Color text;
  final Color muted;
  final Color accent;

  /// Background tint behind selected text.
  ///
  /// Each theme gets an opaque, pre-tuned tint rather than a translucent
  /// accent: at 25% the accent was almost invisible on sepia and dark pages.
  /// Every value keeps at least 2:1 against [background] and 5:1 for [text]
  /// on top of it, so the selection reads clearly without hurting legibility.
  final Color selection;

  final Brightness brightness;

  static const ReaderTheme light = ReaderTheme(
    background: Color(0xFFFAFAF7),
    text: Color(0xFF1A1A1A),
    muted: Color(0xFF8A8A85),
    accent: Color(0xFF2E6E4E),
    selection: Color(0xFF9AB8A7),
    brightness: Brightness.light,
  );

  static const ReaderTheme sepia = ReaderTheme(
    background: Color(0xFFF4E8D1),
    text: Color(0xFF3B2F20),
    muted: Color(0xFF96825F),
    accent: Color(0xFF9C5B2B),
    selection: Color(0xFFC49C76),
    brightness: Brightness.light,
  );

  static const ReaderTheme dark = ReaderTheme(
    background: Color(0xFF121212),
    text: Color(0xFFCFCFC8),
    muted: Color(0xFF6E6E68),
    accent: Color(0xFF7FB894),
    selection: Color(0xFF3E5446),
    brightness: Brightness.dark,
  );

  static const ReaderTheme oled = ReaderTheme(
    background: Color(0xFF000000),
    text: Color(0xFFE6E6E1),
    muted: Color(0xFF6E6E6A),
    accent: Color(0xFF7FB894),
    selection: Color(0xFF334A3B),
    brightness: Brightness.dark,
  );

  static const ReaderTheme dusk = ReaderTheme(
    background: Color(0xFF1A1A2E),
    text: Color(0xFFC8C8D4),
    muted: Color(0xFF6E6E80),
    accent: Color(0xFF7FB894),
    selection: Color(0xFF3A524E),
    brightness: Brightness.dark,
  );

  static ReaderTheme byMode(ReaderThemeMode mode) => switch (mode) {
    ReaderThemeMode.light => light,
    ReaderThemeMode.sepia => sepia,
    ReaderThemeMode.dark => dark,
    ReaderThemeMode.dusk => dusk,
    ReaderThemeMode.oled => oled,
  };
}

/// Describes a font available in the reader font picker.
class ReaderFont {
  const ReaderFont({required this.family, required this.label, this.subtitle});

  /// The `fontFamily` value stored in settings. `null` means system default.
  final String? family;

  /// Short display name for the dropdown.
  final String label;

  /// Optional description shown below the label.
  final String? subtitle;

  static const kDefault = 'Fraunces';
}

/// All fonts offered in the reader font picker.
const kReaderFonts = <ReaderFont>[
  ReaderFont(
    family: null,
    label: 'System default',
    subtitle: 'Respect the EPUB embedded font',
  ),
  ReaderFont(family: 'Fraunces', label: 'Fraunces'),
  ReaderFont(
    family: 'Literata',
    label: 'Literata',
    subtitle: 'Google reading serif',
  ),
  ReaderFont(family: 'Bitter', label: 'Bitter', subtitle: 'Slab serif'),
  ReaderFont(family: 'PT Serif', label: 'PT Serif'),
  ReaderFont(family: 'Georgia', label: 'Georgia', subtitle: 'System serif'),
  ReaderFont(
    family: 'Atkinson Hyperlegible',
    label: 'Atkinson Hyperlegible',
    subtitle: 'Accessibility first',
  ),
  ReaderFont(
    family: 'Source Sans 3',
    label: 'Source Sans 3',
    subtitle: 'Sans serif',
  ),
  ReaderFont(
    family: 'Public Sans',
    label: 'Public Sans',
    subtitle: 'Sans serif',
  ),
];

/// Fonts offered in the app UI font picker (settings screen).
const kUiFonts = <ReaderFont>[
  ReaderFont(family: null, label: 'Fraunces', subtitle: 'Default serif'),
  ReaderFont(family: 'Bitter', label: 'Bitter', subtitle: 'Slab serif'),
  ReaderFont(
    family: 'Atkinson Hyperlegible',
    label: 'Atkinson Hyperlegible',
    subtitle: 'Accessibility first',
  ),
  ReaderFont(
    family: 'Source Sans 3',
    label: 'Source Sans 3',
    subtitle: 'Clean sans serif',
  ),
];

class ReaderSettings {
  ReaderSettings({
    this.fontSize = 18,
    this.lineHeight = 1.6,
    this.appThemeMode = AppThemeMode.light,
    this.readerTheme = ReaderThemeMode.sepia,
    this.fontFamily,
    this.keepScreenOn = false,
    this.brightness,
    this.volumeKeyTurns = false,
    this.pdfLayoutDirection = PdfLayoutDirection.vertical,
    this.pdfContinuousScroll = true,
    this.comicReadingMode = ComicReadingMode.paginated,
    this.comicReadingDirection = ComicReadingDirection.ltr,
    this.textJustification = TextJustification.justify,
    this.horizontalMargin = 20,
    this.comicFitMode = ComicFitMode.contain,
    this.lastZoomLevel = 1.0,
    this.uiFontFamily,
    this.uiTextScale = 1.0,
    this.respectCssStyles = true,
    this.overrideCssFontSize = false,
    this.overrideCssFontFamily = false,
    this.overrideCssColor = false,
    this.overrideCssTextAlign = false,
    this.overrideCssMargin = false,
    this.scanMode = ScanMode.device,
    this.scanFolder = '',
    this.defaultDictionary,
  });

  double fontSize;
  double lineHeight;
  AppThemeMode appThemeMode;
  ReaderThemeMode readerTheme;
  String? fontFamily;
  bool keepScreenOn;

  /// Screen brightness level (0.05–1.0). Null means follow system brightness.
  double? brightness;

  bool volumeKeyTurns;

  PdfLayoutDirection pdfLayoutDirection;
  bool pdfContinuousScroll;
  ComicReadingMode comicReadingMode;
  ComicReadingDirection comicReadingDirection;
  TextJustification textJustification;
  double horizontalMargin;
  ComicFitMode comicFitMode;

  /// Last zoom level used in PDF/comic reader (persists across sessions).
  double lastZoomLevel;

  String? uiFontFamily;
  double uiTextScale;

  /// Whether to apply CSS-derived styles from EPUB stylesheets.
  bool respectCssStyles;

  /// When [respectCssStyles] is true, these override specific CSS properties,
  /// forcing the user's preference instead of the EPUB stylesheet value.
  bool overrideCssFontSize;
  bool overrideCssFontFamily;
  bool overrideCssColor;
  bool overrideCssTextAlign;
  bool overrideCssMargin;

  /// Preferred scan type for the library's scan actions.
  ScanMode scanMode;

  /// Remembered folder for [ScanMode.folder]; empty until the user picks one.
  String scanFolder;

  /// Default dictionary used for word lookups.
  ///
  /// Null means ask every time (show the picker); [burrowDefaultDictionary]
  /// means the built-in offline dictionary; any other value is the Android
  /// package name of an external dictionary app.
  String? defaultDictionary;

  ReaderTheme get colors => ReaderTheme.byMode(readerTheme);

  TextStyle textStyle(BuildContext context) {
    return TextStyle(
      fontSize: fontSize,
      height: lineHeight,
      color: colors.text,
      fontFamily: fontFamily,
    );
  }

  Map<String, dynamic> toJson() => {
    'fontSize': fontSize,
    'lineHeight': lineHeight,
    'appThemeMode': appThemeMode.name,
    'readerTheme': readerTheme.name,
    'fontFamily': fontFamily,
    'keepScreenOn': keepScreenOn,
    'brightness': brightness,
    'volumeKeyTurns': volumeKeyTurns,
    'pdfLayoutDirection': pdfLayoutDirection.name,
    'pdfContinuousScroll': pdfContinuousScroll,
    'comicReadingMode': comicReadingMode.name,
    'comicReadingDirection': comicReadingDirection.name,
    'textJustification': textJustification.name,
    'horizontalMargin': horizontalMargin,
    'comicFitMode': comicFitMode.name,
    'lastZoomLevel': lastZoomLevel,
    'uiFontFamily': uiFontFamily,
    'uiTextScale': uiTextScale,
    'respectCssStyles': respectCssStyles,
    'overrideCssFontSize': overrideCssFontSize,
    'overrideCssFontFamily': overrideCssFontFamily,
    'overrideCssColor': overrideCssColor,
    'overrideCssTextAlign': overrideCssTextAlign,
    'overrideCssMargin': overrideCssMargin,
    'scanMode': scanMode.name,
    'scanFolder': scanFolder,
    'defaultDictionary': defaultDictionary,
  };

  /// Slider ranges the UI offers; persisted values are clamped to them so a
  /// corrupt or hand-edited pref can't produce a degenerate text style.
  static const fontSizeRange = (13.0, 30.0);
  static const lineHeightRange = (1.2, 2.2);
  static const uiTextScaleRange = (0.8, 1.2);

  static double _clampTo((double, double) range, double v, double fallback) {
    if (v.isNaN || v.isInfinite) return fallback;
    return v.clamp(range.$1, range.$2);
  }

  static ReaderSettings fromJson(Map<String, dynamic> json) => ReaderSettings(
    fontSize: _clampTo(
      fontSizeRange,
      (json['fontSize'] as num?)?.toDouble() ?? 18,
      18,
    ),
    lineHeight: _clampTo(
      lineHeightRange,
      (json['lineHeight'] as num?)?.toDouble() ?? 1.6,
      1.6,
    ),
    appThemeMode: AppThemeMode.values.firstWhere(
      (m) => m.name == json['appThemeMode'],
      orElse: () => AppThemeMode.light,
    ),
    readerTheme: ReaderThemeMode.values.firstWhere(
      (m) => m.name == (json['readerTheme'] ?? json['theme']),
      orElse: () => ReaderThemeMode.sepia,
    ),
    fontFamily: _migrateFontFamily(json),
    keepScreenOn: json['keepScreenOn'] as bool? ?? false,
    brightness: _parseBrightness(json),
    volumeKeyTurns: json['volumeKeyTurns'] as bool? ?? false,
    pdfLayoutDirection: PdfLayoutDirection.values.firstWhere(
      (d) => d.name == json['pdfLayoutDirection'],
      orElse: () => PdfLayoutDirection.vertical,
    ),
    pdfContinuousScroll: json['pdfContinuousScroll'] as bool? ?? true,
    comicReadingMode: ComicReadingMode.values.firstWhere(
      (m) => m.name == json['comicReadingMode'],
      orElse: () => ComicReadingMode.paginated,
    ),
    comicReadingDirection: ComicReadingDirection.values.firstWhere(
      (d) => d.name == json['comicReadingDirection'],
      orElse: () => ComicReadingDirection.ltr,
    ),
    textJustification: TextJustification.values.firstWhere(
      (j) => j.name == json['textJustification'],
      orElse: () => TextJustification.justify,
    ),
    horizontalMargin: _clampTo(
      const (8.0, 40.0),
      (json['horizontalMargin'] as num?)?.toDouble() ?? 20,
      20,
    ),
    comicFitMode: ComicFitMode.values.firstWhere(
      (m) => m.name == json['comicFitMode'],
      orElse: () => ComicFitMode.contain,
    ),
    lastZoomLevel: _clampTo(
      const (0.5, 5.0),
      (json['lastZoomLevel'] as num?)?.toDouble() ?? 1.0,
      1.0,
    ),
    uiFontFamily: json['uiFontFamily'] as String?,
    uiTextScale: _clampTo(
      uiTextScaleRange,
      (json['uiTextScale'] as num?)?.toDouble() ?? 1.0,
      1.0,
    ),
    respectCssStyles: json['respectCssStyles'] as bool? ?? true,
    overrideCssFontSize: json['overrideCssFontSize'] as bool? ?? false,
    overrideCssFontFamily: json['overrideCssFontFamily'] as bool? ?? false,
    overrideCssColor: json['overrideCssColor'] as bool? ?? false,
    overrideCssTextAlign: json['overrideCssTextAlign'] as bool? ?? false,
    overrideCssMargin: json['overrideCssMargin'] as bool? ?? false,
    scanMode: ScanMode.values.firstWhere(
      (m) => m.name == json['scanMode'],
      orElse: () => ScanMode.device,
    ),
    scanFolder: json['scanFolder'] as String? ?? '',
    defaultDictionary: json['defaultDictionary'] as String?,
  );

  /// Migrate the legacy `serif` bool to the new `fontFamily` string.
  static String? _migrateFontFamily(Map<String, dynamic> json) {
    final saved = json['fontFamily'] as String?;
    if (saved != null) {
      // Validate against known fonts; fall back to null (system default) for
      // removed or unknown values (e.g. old 'Roboto Flex', 'serif', 'sans-serif').
      return kReaderFonts.any((f) => f.family == saved) ? saved : null;
    }
    final serif = json['serif'] as bool?;
    if (serif == true) return 'Georgia';
    return null;
  }

  /// Migrate legacy `dimmer` (0.3–1.0, 1.0 = no dim) into `brightness`
  /// (0.05–1.0, null = follow system). Legacy values at 1.0 become null.
  static double? _parseBrightness(Map<String, dynamic> json) {
    final raw = json['brightness'] as num?;
    if (raw != null) {
      final v = raw.toDouble();
      // Non-finite values must never reach the platform brightness channel.
      if (!v.isFinite) return null; // follow system
      return v.clamp(kMinBrightness, 1.0);
    }
    // Legacy dimmer migration.
    final dimmer = json['dimmer'] as num?;
    if (dimmer != null) {
      final v = dimmer.toDouble();
      if (!v.isFinite || v >= 1.0) return null; // 100% → follow system
      return v.clamp(kMinBrightness, 1.0);
    }
    return null; // no value saved → follow system
  }
}
