import 'package:flutter/material.dart';

import '../../models/reader_settings.dart';
import '../../services/library_service.dart';
import '../../theme/burrow_tokens.dart';

class ThemePicker extends StatelessWidget {
  const ThemePicker({
    super.key,
    required this.library,
    required this.onChanged,
  });

  final LibraryService library;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
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
    final selected = library.settings.appThemeMode == mode;
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
      onTap: () {
        library.settings.appThemeMode = mode;
        library.saveSettings();
        onChanged();
      },
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
}
