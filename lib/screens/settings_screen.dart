import 'package:flutter/material.dart';

import '../models/reader_settings.dart';
import '../services/library_service.dart';
import '../theme/burrow_tokens.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.library});

  final LibraryService library;

  static void show(BuildContext context, {required LibraryService library}) {
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => SettingsScreen(library: library),
      ),
    );
  }

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  ReaderSettings get _s => widget.library.settings;

  void _update(void Function() mutate) {
    setState(mutate);
    widget.library.saveSettings();
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
          const SizedBox(height: 24),
          _sectionHeader('About'),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.info_outline, color: scheme.onSurfaceVariant),
            title: const Text('Version'),
            trailing: Text(
              '1.0.0',
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
              applicationVersion: '1.0.0',
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
          border: Border.all(
            color: isSel ? scheme.primary : scheme.outlineVariant,
            width: isSel ? 2 : 1,
          ),
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
                  border: Border.all(
                    color: onPreview.withValues(alpha: 0.15),
                  ),
                ),
                child: Center(
                  child: Icon(icon,
                      size: 28, color: onPreview.withValues(alpha: 0.6)),
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
