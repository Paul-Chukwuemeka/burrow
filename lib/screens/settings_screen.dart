import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../models/reader_settings.dart';
import '../services/dictionary_service.dart';
import '../services/library_service.dart';
import '../theme/burrow_tokens.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.library,
    this.autoDownloadDictionary = false,
  });

  final LibraryService library;
  final bool autoDownloadDictionary;

  static void show(BuildContext context, {
    required LibraryService library,
    bool autoDownloadDictionary = false,
  }) {
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => SettingsScreen(
          library: library,
          autoDownloadDictionary: autoDownloadDictionary,
        ),
      ),
    );
  }

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const _version = '1.0.0';
  ReaderSettings get _s => widget.library.settings;

  bool _dictDownloading = false;
  double _dictProgress = 0;
  String? _dictError;
  bool _dictReady = false;
  String _dictStatus = '';

  @override
  void initState() {
    super.initState();
    _dictReady = DictionaryService.instance.isDownloaded;
    if (widget.autoDownloadDictionary && !_dictReady) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _startDictDownload());
    }
  }

  void _update(void Function() mutate) {
    setState(mutate);
    widget.library.saveSettings();
  }

  Future<void> _startDictDownload() async {
    if (_dictDownloading) return;
    setState(() {
      _dictDownloading = true;
      _dictProgress = 0;
      _dictError = null;
    });

    try {
      await DictionaryService.instance.ensureReady(
        onProgress: (p) {
          if (mounted) setState(() => _dictProgress = p);
        },
        onStatus: (status) {
          if (mounted) setState(() => _dictStatus = status);
        },
      );
      if (mounted) {
        setState(() {
          _dictReady = true;
          _dictDownloading = false;
        });
      }
    } catch (e) {
      debugPrint('Dictionary download failed: $e');
      if (mounted) {
        setState(() {
          _dictDownloading = false;
          if (e is TimeoutException) {
            _dictError = 'Download timed out. Please check your connection.';
          } else if (e is HttpException) {
            _dictError = 'Download failed. Please try again later.';
          } else if (e is SocketException) {
            _dictError = 'No internet connection. Please check your network.';
          } else {
            _dictError = 'Something went wrong. Please try again.';
          }
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          _sectionHeader('General'),
          _ToggleRow(
            icon: Icons.screen_lock_portrait,
            label: 'Keep screen on',
            subtitle: 'Prevent display from sleeping while reading',
            value: _s.keepScreenOn,
            onChanged: (v) => _update(() => _s.keepScreenOn = v),
          ),
          _ToggleRow(
            icon: Icons.volume_up,
            label: 'Volume keys turn pages',
            subtitle: 'Use hardware volume buttons to flip pages',
            value: _s.volumeKeyTurns,
            onChanged: (v) => _update(() => _s.volumeKeyTurns = v),
          ),
          const SizedBox(height: 24),
          _sectionHeader('Appearance'),
          const SizedBox(height: 12),
          _ThemeGrid(
            selected: _s.appThemeMode,
            onSelect: (mode) => _update(() => _s.appThemeMode = mode),
          ),
          const SizedBox(height: 20),
          // Font family picker.
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.font_download_outlined, color: scheme.onSurfaceVariant),
            title: const Text('Font', softWrap: false),
            trailing: DropdownButton<String>(
              value: _s.uiFontFamily,
              underline: const SizedBox.shrink(),
              items: [
                for (final f in kUiFonts)
                  DropdownMenuItem(
                    value: f.family,
                    child: Text(f.label),
                  ),
              ],
              onChanged: (v) => _update(() => _s.uiFontFamily = v),
            ),
          ),
          // Text scale stepper.
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.text_increase, color: scheme.onSurfaceVariant),
            title: const Text('Text size'),
            subtitle: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.remove_circle_outline),
                  iconSize: 20,
                  visualDensity: VisualDensity.compact,
                  onPressed: _s.uiTextScale > ReaderSettings.uiTextScaleRange.$1
                      ? () => _update(() {
                            final step =
                                (ReaderSettings.uiTextScaleRange.$2 -
                                        ReaderSettings.uiTextScaleRange.$1) /
                                    7;
                            _s.uiTextScale = (_s.uiTextScale - step)
                                .clamp(
                                  ReaderSettings.uiTextScaleRange.$1,
                                  ReaderSettings.uiTextScaleRange.$2,
                                );
                          })
                      : null,
                ),
                SizedBox(
                  width: 36,
                  child: Text(
                    '${(_s.uiTextScale * 100).round()}%',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add_circle_outline),
                  iconSize: 20,
                  visualDensity: VisualDensity.compact,
                  onPressed: _s.uiTextScale < ReaderSettings.uiTextScaleRange.$2
                      ? () => _update(() {
                            final step =
                                (ReaderSettings.uiTextScaleRange.$2 -
                                        ReaderSettings.uiTextScaleRange.$1) /
                                    7;
                            _s.uiTextScale = (_s.uiTextScale + step)
                                .clamp(
                                  ReaderSettings.uiTextScaleRange.$1,
                                  ReaderSettings.uiTextScaleRange.$2,
                                );
                          })
                      : null,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          _sectionHeader('Dictionary'),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.book_outlined, color: scheme.onSurfaceVariant),
            title: const Text('Offline dictionary'),
            subtitle: _dictReady
                ? Text(
                    'Downloaded',
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  )
                : _dictDownloading
                    ? Text(
                        _dictStatus.isNotEmpty
                            ? _dictStatus
                            : _dictProgress > 0
                                ? 'Downloading… ${(_dictProgress * 100).toStringAsFixed(0)}%'
                                : 'Connecting…',
                        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                      )
                    : Text(
                        'Tap to download (~40 MB)',
                        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                      ),
            trailing: _dictDownloading
                ? SizedBox(
                    width: 48,
                    child: Center(
                      child: SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          value: _dictProgress > 0 ? _dictProgress : null,
                          color: scheme.primary,
                        ),
                      ),
                    ),
                  )
                : _dictReady
                    ? Icon(Icons.check_circle, color: scheme.primary)
                    : _dictError != null
                        ? IconButton(
                            icon: Icon(Icons.refresh, color: scheme.error),
                            onPressed: _startDictDownload,
                          )
                        : Icon(Icons.download, color: scheme.onSurfaceVariant),
            onTap: _dictDownloading
                ? null
                : _dictReady
                    ? null
                    : _startDictDownload,
          ),
          if (_dictDownloading && _dictProgress > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: LinearProgressIndicator(
                value: _dictProgress,
                backgroundColor: scheme.surfaceContainerHighest,
                color: scheme.primary,
              ),
            ),
          if (_dictError != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _dictError!,
                style: TextStyle(fontSize: 12, color: scheme.error),
              ),
            ),
          const SizedBox(height: 24),
          _sectionHeader('About'),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.info_outline, color: scheme.onSurfaceVariant),
            title: const Text('Version'),
            trailing: Text(
              _version,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 14),
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.book_outlined, color: scheme.onSurfaceVariant),
            title: const Text('Licenses'),
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'Burrow',
              applicationVersion: _version,
              applicationLegalese: 'Dictionary data © Open English WordNet 2024 (CC BY 4.0)\n'
                  'Licensed under the Creative Commons Attribution 4.0 International License.\n'
                  'https://creativecommons.org/licenses/by/4.0/',
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String label) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.6,
          color: scheme.primary,
        ),
      ),
    );
  }
}

class _ThemeGrid extends StatelessWidget {
  const _ThemeGrid({required this.selected, required this.onSelect});

  final AppThemeMode selected;
  final ValueChanged<AppThemeMode> onSelect;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: _themeCard(context, AppThemeMode.light)),
        const SizedBox(width: 12),
        Expanded(child: _themeCard(context, AppThemeMode.dark)),
        const SizedBox(width: 12),
        Expanded(child: _themeCard(context, AppThemeMode.oled)),
      ],
    );
  }

  Widget _themeCard(BuildContext context, AppThemeMode mode) {
    final scheme = Theme.of(context).colorScheme;
    final isSel = selected == mode;
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
      onTap: () => onSelect(mode),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Easing.emphasizedDecelerate,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: Burrow.r(18),
        ),
        child: Column(
          children: [
            AnimatedScale(
              scale: isSel ? 1.06 : 1,
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutBack,
              child: Container(
                height: 72,
                decoration: BoxDecoration(
                  color: preview,
                  borderRadius: Burrow.r(12),
                ),
                child: Stack(
                  children: [
                    Center(
                      child: Icon(icon,
                          size: 28, color: onPreview.withValues(alpha: 0.6)),
                    ),
                    if (isSel)
                      Positioned(
                        top: 6,
                        right: 6,
                        child: Icon(Icons.check_circle, size: 20, color: scheme.primary),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: isSel ? FontWeight.w800 : FontWeight.w600,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: scheme.onSurfaceVariant),
      title: Text(label),
      subtitle: Text(
        subtitle,
        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
      ),
      trailing: Switch(
        value: value,
        onChanged: onChanged,
      ),
    );
  }
}
