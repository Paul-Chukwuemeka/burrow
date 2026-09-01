import 'dart:async';

import 'package:flutter/material.dart';

import '../models/book.dart';
import '../models/reader_settings.dart';
import '../services/brightness_controller.dart';

/// Bottom sheet for reading preferences. Mutates the passed [settings] object
/// and calls [onChanged] when a tweak is *settled* so the reader can
/// repaginate.
///
/// Notification is deliberately not per-frame: font size and line height
/// change the text layout, and repagination is far too expensive to run on
/// every division a slider drag crosses. Sliders therefore update the shared
/// settings object continuously (so labels track the thumb) but only notify on
/// [Slider.onChangeEnd], with a debounce as a safety net. Discrete controls
/// notify immediately.
abstract final class SettingsSheet {
  /// Safety net for callers/gestures that never deliver `onChangeEnd`. Longer
  /// than a plausible gap between slider divisions during a drag, so a fast
  /// drag commits exactly once (on release) rather than mid-drag.
  static const commitDebounce = Duration(milliseconds: 400);

  static Future<void> show(
    BuildContext context, {
    required ReaderSettings settings,
    required VoidCallback onChanged,
    BookFormat format = BookFormat.epub,
  }) {
    return showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _ThemedSheet(
        settings: settings,
        onChanged: onChanged,
        format: format,
      ),
    );
  }
}

class _ThemedSheet extends StatefulWidget {
  const _ThemedSheet({
    required this.settings,
    required this.onChanged,
    this.format = BookFormat.epub,
  });
  final ReaderSettings settings;
  final VoidCallback onChanged;
  final BookFormat format;

  @override
  State<_ThemedSheet> createState() => _ThemedSheetState();
}

class _ThemedSheetState extends State<_ThemedSheet> {
  Timer? _debounce;

  ReaderSettings get settings => widget.settings;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  /// Notify now, cancelling any pending debounce.
  void _commit() {
    _debounce?.cancel();
    _debounce = null;
    widget.onChanged();
  }

  /// Notify once the value stops changing. Used while a slider is being
  /// dragged so an in-progress drag never triggers repagination.
  void _commitDebounced() {
    _debounce?.cancel();
    _debounce = Timer(SettingsSheet.commitDebounce, () {
      _debounce = null;
      widget.onChanged();
    });
  }

  /// A discrete change: apply and notify immediately.
  void _update(void Function() mutate) {
    setState(mutate);
    _commit();
  }

  /// A continuous change mid-drag: apply so labels track the thumb, but defer
  /// notification.
  void _preview(void Function() mutate) {
    setState(mutate);
    _commitDebounced();
  }

  // ── Shared sections ────────────────────────────────────────────────────────

  Widget _buildHandle(ReaderTheme theme) => Center(
        child: Container(
          width: 36,
          height: 4,
          decoration: BoxDecoration(
            color: theme.muted.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      );

  Widget _buildThemeDots(ReaderTheme theme) => Row(
        children: [
          for (final mode in ReaderThemeMode.values)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: _ThemeDot(
                mode: mode,
                selected: settings.readerTheme == mode,
                onTap: () =>
                    _update(() => settings.readerTheme = mode),
              ),
            ),
        ],
      );

  Widget _buildBrightness(ReaderTheme theme) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          _ToggleRow(
            icon: Icons.brightness_auto,
            label: 'System brightness',
            value: settings.brightness == null,
            theme: theme,
            onChanged: (v) {
              if (v) {
                _update(() => settings.brightness = null);
                return;
              }
              BrightnessController.instance.current().then((lv) {
                if (!mounted) return;
                _update(() => settings.brightness = lv);
              });
            },
          ),
          Row(
            children: [
              Icon(Icons.brightness_low, color: theme.muted, size: 20),
              Expanded(
                child: Slider(
                  value: settings.brightness ?? 1.0,
                  min: kMinBrightness,
                  max: 1.0,
                  divisions: 19,
                  activeColor: theme.accent,
                  onChanged: settings.brightness == null
                      ? null
                      : (v) => _preview(() => settings.brightness = v),
                  onChangeEnd:
                      settings.brightness == null ? null : (_) => _commit(),
                  label:
                      '${((settings.brightness ?? 1.0) * 100).round()}%',
                ),
              ),
              SizedBox(
                width: 28,
                child: Text(
                  '${((settings.brightness ?? 1.0) * 100).round()}',
                  style: TextStyle(
                    color: settings.brightness == null
                        ? theme.muted.withValues(alpha: 0.4)
                        : theme.muted,
                  ),
                ),
              ),
            ],
          ),
        ],
      );

  Widget _buildMisc(ReaderTheme theme) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ToggleRow(
            icon: Icons.screen_lock_portrait,
            label: 'Keep screen on',
            value: settings.keepScreenOn,
            theme: theme,
            onChanged: (v) => _update(() => settings.keepScreenOn = v),
          ),
          _ToggleRow(
            icon: Icons.volume_up,
            label: 'Volume keys turn pages',
            value: settings.volumeKeyTurns,
            theme: theme,
            onChanged: (v) => _update(() => settings.volumeKeyTurns = v),
          ),
        ],
      );

  // ── Format-specific panels ─────────────────────────────────────────────────

  Widget _buildReflowablePanel(ReaderTheme theme) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildThemeDots(theme),
          const SizedBox(height: 12),
          // ── Font family ─────────────────────────────────────────────
          Row(
            children: [
              Icon(Icons.font_download_outlined,
                  color: theme.muted, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: settings.fontFamily ?? '',
                    isExpanded: true,
                    isDense: true,
                    borderRadius: BorderRadius.circular(12),
                    selectedItemBuilder: (context) {
                      final cs = Theme.of(context).colorScheme;
                      return [
                        for (final font in kReaderFonts)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              font.label,
                              style: TextStyle(
                                fontSize: 14,
                                color: cs.onSurface,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ];
                    },
                    items: [
                      for (final font in kReaderFonts)
                        DropdownMenuItem(
                          value: font.family ?? '',
                          child: _HoverableDropdownItem(font: font),
                        ),
                    ],
                    onChanged: (v) => _update(
                      () => settings.fontFamily =
                          (v == null || v.isEmpty) ? null : v,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // ── Font size ────────────────────────────────────────────────
          Row(
            children: [
              Icon(Icons.text_fields, color: theme.muted, size: 20),
              Expanded(
                child: Slider(
                  value: settings.fontSize,
                  min: 13,
                  max: 30,
                  divisions: 17,
                  activeColor: theme.accent,
                  label: settings.fontSize.round().toString(),
                  onChanged: (v) =>
                      _preview(() => settings.fontSize = v),
                  onChangeEnd: (_) => _commit(),
                ),
              ),
              SizedBox(
                width: 28,
                child: Text(
                  '${settings.fontSize.round()}',
                  style: TextStyle(color: theme.muted),
                ),
              ),
            ],
          ),
          // ── Line height ─────────────────────────────────────────────
          Row(
            children: [
              Icon(Icons.format_line_spacing,
                  color: theme.muted, size: 20),
              Expanded(
                child: Slider(
                  value: settings.lineHeight,
                  min: 1.2,
                  max: 2.2,
                  divisions: 10,
                  activeColor: theme.accent,
                  label: settings.lineHeight.toStringAsFixed(1),
                  onChanged: (v) =>
                      _preview(() => settings.lineHeight = v),
                  onChangeEnd: (_) => _commit(),
                ),
              ),
              SizedBox(
                width: 28,
                child: Text(
                  settings.lineHeight.toStringAsFixed(1),
                  style: TextStyle(color: theme.muted),
                ),
              ),
            ],
          ),
          _buildBrightness(theme),
          _buildMisc(theme),
        ],
      );

  Widget _buildPdfPanel(ReaderTheme theme) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildThemeDots(theme),
          const SizedBox(height: 12),
          // ── Scroll direction ─────────────────────────────────────────
          Row(
            children: [
              Icon(Icons.swap_horiz, color: theme.muted, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Scroll direction',
                  style: TextStyle(fontSize: 14, color: theme.text),
                ),
              ),
              SegmentedButton<PdfLayoutDirection>(
                segments: const [
                  ButtonSegment(
                    value: PdfLayoutDirection.vertical,
                    label: Text('Vert'),
                    icon: Icon(Icons.swap_vert, size: 16),
                  ),
                  ButtonSegment(
                    value: PdfLayoutDirection.horizontalLtr,
                    label: Text('\u2190'),
                    icon: Icon(Icons.arrow_back, size: 16),
                  ),
                  ButtonSegment(
                    value: PdfLayoutDirection.horizontalRtl,
                    label: Text('\u2192'),
                    icon: Icon(Icons.arrow_forward, size: 16),
                  ),
                ],
                selected: {settings.pdfLayoutDirection},
                showSelectedIcon: false,
                onSelectionChanged: (s) => _update(
                    () => settings.pdfLayoutDirection = s.first),
              ),
            ],
          ),
          _ToggleRow(
            icon: Icons.view_stream,
            label: 'Continuous scroll',
            value: settings.pdfContinuousScroll,
            theme: theme,
            onChanged: (v) =>
                _update(() => settings.pdfContinuousScroll = v),
          ),
          _buildBrightness(theme),
          _buildMisc(theme),
        ],
      );

  Widget _buildComicsPanel(ReaderTheme theme) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildThemeDots(theme),
          const SizedBox(height: 12),
          // ── Reading mode ─────────────────────────────────────────────
          _ToggleRow(
            icon: Icons.menu_book,
            label: 'Paginated reading',
            value: settings.comicReadingMode == ComicReadingMode.paginated,
            theme: theme,
            onChanged: (v) => _update(
              () => settings.comicReadingMode =
                  v ? ComicReadingMode.paginated : ComicReadingMode.vertical,
            ),
          ),
          // ── Scroll direction (paginated only) ───────────────────────
          if (settings.comicReadingMode == ComicReadingMode.paginated) ...[
            Row(
              children: [
                Icon(Icons.swap_horiz, color: theme.muted, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Scroll direction',
                    style: TextStyle(fontSize: 14, color: theme.text),
                  ),
                ),
                SegmentedButton<ComicReadingDirection>(
                  segments: const [
                    ButtonSegment(
                      value: ComicReadingDirection.ltr,
                      label: Text('\u2190'),
                      icon: Icon(Icons.arrow_back, size: 16),
                    ),
                    ButtonSegment(
                      value: ComicReadingDirection.rtl,
                      label: Text('\u2192'),
                      icon: Icon(Icons.arrow_forward, size: 16),
                    ),
                  ],
                  selected: {settings.comicReadingDirection},
                  showSelectedIcon: false,
                  onSelectionChanged: (s) => _update(
                      () => settings.comicReadingDirection = s.first),
                ),
              ],
            ),
          ],
          _buildBrightness(theme),
          _buildMisc(theme),
        ],
      );

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = settings.colors;
    final panel = switch (widget.format) {
      BookFormat.epub || BookFormat.txt => _buildReflowablePanel(theme),
      BookFormat.pdf => _buildPdfPanel(theme),
      BookFormat.cbz || BookFormat.cbr => _buildComicsPanel(theme),
    };

    return Container(
      decoration: BoxDecoration(
        color: theme.background,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHandle(theme),
            const SizedBox(height: 16),
            panel,
          ],
        ),
      ),
    );
  }
}

class _ThemeDot extends StatelessWidget {
  const _ThemeDot({
    required this.mode,
    required this.selected,
    required this.onTap,
  });

  final ReaderThemeMode mode;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = ReaderTheme.byMode(mode);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: colors.background,
          border: Border.all(
            color: selected ? colors.accent : colors.muted,
            width: selected ? 3 : 1.5,
          ),
        ),
        child: mode == ReaderThemeMode.dark
            ? Icon(Icons.dark_mode_outlined,
                size: 18, color: selected ? colors.accent : colors.muted)
            : mode == ReaderThemeMode.dusk
                ? Icon(Icons.nightlight_outlined,
                    size: 18,
                    color: selected ? colors.accent : colors.muted)
                : mode == ReaderThemeMode.oled
                    ? Icon(Icons.lens_blur_outlined,
                        size: 18,
                        color: selected ? colors.accent : colors.muted)
                    : null,
      ),
    );
  }
}

class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.theme,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final bool value;
  final ReaderTheme theme;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: theme.muted, size: 20),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              label,
              style: TextStyle(fontSize: 14, color: theme.text),
            ),
          ),
        ),
        Switch(
          value: value,
          activeThumbColor: theme.accent,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

class _HoverableDropdownItem extends StatefulWidget {
  const _HoverableDropdownItem({required this.font});

  final ReaderFont font;

  @override
  State<_HoverableDropdownItem> createState() => _HoverableDropdownItemState();
}

class _HoverableDropdownItemState extends State<_HoverableDropdownItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = widget.font.subtitle != null
        ? '${widget.font.label}  \u00b7  ${widget.font.subtitle}'
        : widget.font.label;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: _hovered ? scheme.surfaceContainerHigh : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 14,
            color: scheme.onSurface,
          ),
        ),
      ),
    );
  }
}
