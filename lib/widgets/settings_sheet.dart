import 'dart:async';

import 'package:flutter/material.dart';

import '../models/book.dart';
import '../models/reader_settings.dart';

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
    VoidCallback? onPdfFitWidth,
    VoidCallback? onPdfFitPage,
  }) {
    return showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _ThemedSheet(
        settings: settings,
        onChanged: onChanged,
        format: format,
        onPdfFitWidth: onPdfFitWidth,
        onPdfFitPage: onPdfFitPage,
      ),
    );
  }
}

class _ThemedSheet extends StatefulWidget {
  const _ThemedSheet({
    required this.settings,
    required this.onChanged,
    this.format = BookFormat.epub,
    this.onPdfFitWidth,
    this.onPdfFitPage,
  });
  final ReaderSettings settings;
  final VoidCallback onChanged;
  final BookFormat format;
  final VoidCallback? onPdfFitWidth;
  final VoidCallback? onPdfFitPage;

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
            onTap: () => _update(() => settings.readerTheme = mode),
          ),
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
          Icon(Icons.font_download_outlined, color: theme.muted, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: settings.fontFamily ?? '',
                isExpanded: true,
                isDense: true,
                borderRadius: BorderRadius.circular(12),
                selectedItemBuilder: (context) {
                  return [
                    for (final font in kReaderFonts)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          font.label,
                          style: TextStyle(fontSize: 14, color: theme.text),
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
                      child: _HoverableDropdownItem(font: font, theme: theme),
                    ),
                ],
                onChanged: (v) => _update(
                  () =>
                      settings.fontFamily = (v == null || v.isEmpty) ? null : v,
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
          const SizedBox(width: 12),
          Text('Font size', style: TextStyle(fontSize: 14, color: theme.text)),
          const Spacer(),
          IconButton(
            icon: Icon(
              Icons.remove_circle_outline,
              color: theme.accent,
              size: 20,
            ),
            visualDensity: VisualDensity.compact,
            onPressed: settings.fontSize > ReaderSettings.fontSizeRange.$1
                ? () {
                    _preview(
                      () => settings.fontSize = (settings.fontSize - 1).clamp(
                        ReaderSettings.fontSizeRange.$1,
                        ReaderSettings.fontSizeRange.$2,
                      ),
                    );
                    _commit();
                  }
                : null,
          ),
          SizedBox(
            width: 28,
            child: Text(
              '${settings.fontSize.round()}',
              style: TextStyle(color: theme.muted, fontSize: 14),
              textAlign: TextAlign.center,
            ),
          ),
          IconButton(
            icon: Icon(Icons.add_circle_outline, color: theme.accent, size: 20),
            visualDensity: VisualDensity.compact,
            onPressed: settings.fontSize < ReaderSettings.fontSizeRange.$2
                ? () {
                    _preview(
                      () => settings.fontSize = (settings.fontSize + 1).clamp(
                        ReaderSettings.fontSizeRange.$1,
                        ReaderSettings.fontSizeRange.$2,
                      ),
                    );
                    _commit();
                  }
                : null,
          ),
        ],
      ),
      // ── Line height ─────────────────────────────────────────────
      Row(
        children: [
          Icon(Icons.format_line_spacing, color: theme.muted, size: 20),
          const SizedBox(width: 12),
          Text(
            'Line height',
            style: TextStyle(fontSize: 14, color: theme.text),
          ),
          const Spacer(),
          IconButton(
            icon: Icon(
              Icons.remove_circle_outline,
              color: theme.accent,
              size: 20,
            ),
            visualDensity: VisualDensity.compact,
            onPressed: settings.lineHeight > ReaderSettings.lineHeightRange.$1
                ? () {
                    _preview(
                      () => settings.lineHeight = (settings.lineHeight - 0.1)
                          .clamp(
                            ReaderSettings.lineHeightRange.$1,
                            ReaderSettings.lineHeightRange.$2,
                          ),
                    );
                    _commit();
                  }
                : null,
          ),
          SizedBox(
            width: 28,
            child: Text(
              settings.lineHeight.toStringAsFixed(1),
              style: TextStyle(color: theme.muted, fontSize: 14),
              textAlign: TextAlign.center,
            ),
          ),
          IconButton(
            icon: Icon(Icons.add_circle_outline, color: theme.accent, size: 20),
            visualDensity: VisualDensity.compact,
            onPressed: settings.lineHeight < ReaderSettings.lineHeightRange.$2
                ? () {
                    _preview(
                      () => settings.lineHeight = (settings.lineHeight + 0.1)
                          .clamp(
                            ReaderSettings.lineHeightRange.$1,
                            ReaderSettings.lineHeightRange.$2,
                          ),
                    );
                    _commit();
                  }
                : null,
          ),
        ],
      ),
      // ── Text justification ───────────────────────────────────
      const SizedBox(height: 8),
      Row(
        children: [
          Icon(Icons.format_align_left, color: theme.muted, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Justification',
              style: TextStyle(fontSize: 14, color: theme.text),
            ),
          ),
          SegmentedButton<TextJustification>(
            segments: [
              ButtonSegment(
                value: TextJustification.left,
                label: Text('Left', style: TextStyle(color: theme.text)),
              ),
              ButtonSegment(
                value: TextJustification.justify,
                label: Text('Justify', style: TextStyle(color: theme.text)),
              ),
            ],
            selected: {settings.textJustification},
            showSelectedIcon: false,
            onSelectionChanged: (s) =>
                _update(() => settings.textJustification = s.first),
          ),
        ],
      ),
      // ── Horizontal margin ─────────────────────────────────────
      Row(
        children: [
          Icon(Icons.swap_horiz, color: theme.muted, size: 20),
          const SizedBox(width: 12),
          Text('Margin', style: TextStyle(fontSize: 14, color: theme.text)),
          const Spacer(),
          IconButton(
            icon: Icon(
              Icons.remove_circle_outline,
              color: theme.accent,
              size: 20,
            ),
            visualDensity: VisualDensity.compact,
            onPressed: settings.horizontalMargin > 8
                ? () {
                    _preview(
                      () => settings.horizontalMargin =
                          (settings.horizontalMargin - 2).clamp(8.0, 40.0),
                    );
                    _commit();
                  }
                : null,
          ),
          SizedBox(
            width: 28,
            child: Text(
              '${settings.horizontalMargin.round()}',
              style: TextStyle(color: theme.muted, fontSize: 14),
              textAlign: TextAlign.center,
            ),
          ),
          IconButton(
            icon: Icon(Icons.add_circle_outline, color: theme.accent, size: 20),
            visualDensity: VisualDensity.compact,
            onPressed: settings.horizontalMargin < 40
                ? () {
                    _preview(
                      () => settings.horizontalMargin =
                          (settings.horizontalMargin + 2).clamp(8.0, 40.0),
                    );
                    _commit();
                  }
                : null,
          ),
        ],
      ),
      // ── CSS style overrides ───────────────────────────────────────
      _buildCssOverrides(theme),
      _buildMisc(theme),
    ],
  );

  Widget _buildCssOverrides(ReaderTheme theme) {
    final settings = widget.settings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Row(
          children: [
            Icon(Icons.code, color: theme.muted, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Respect EPUB styles',
                style: TextStyle(color: theme.text, fontSize: 14),
              ),
            ),
            Switch(
              value: settings.respectCssStyles,
              activeThumbColor: theme.accent,
              onChanged: (v) => _update(() => settings.respectCssStyles = v),
            ),
          ],
        ),
        if (settings.respectCssStyles) ...[
          _CssOverrideToggle(
            label: 'Override font size',
            value: settings.overrideCssFontSize,
            onChanged: (v) => _update(() => settings.overrideCssFontSize = v),
            theme: theme,
          ),
          _CssOverrideToggle(
            label: 'Override font family',
            value: settings.overrideCssFontFamily,
            onChanged: (v) => _update(() => settings.overrideCssFontFamily = v),
            theme: theme,
          ),
          _CssOverrideToggle(
            label: 'Override colors',
            value: settings.overrideCssColor,
            onChanged: (v) => _update(() => settings.overrideCssColor = v),
            theme: theme,
          ),
          _CssOverrideToggle(
            label: 'Override text align',
            value: settings.overrideCssTextAlign,
            onChanged: (v) => _update(() => settings.overrideCssTextAlign = v),
            theme: theme,
          ),
          _CssOverrideToggle(
            label: 'Override margins',
            value: settings.overrideCssMargin,
            onChanged: (v) => _update(() => settings.overrideCssMargin = v),
            theme: theme,
          ),
        ],
      ],
    );
  }

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
            segments: [
              ButtonSegment(
                value: PdfLayoutDirection.vertical,
                label: Text('Vert', style: TextStyle(color: theme.text)),
                icon: Icon(Icons.swap_vert, size: 16),
              ),
              ButtonSegment(
                value: PdfLayoutDirection.horizontalLtr,
                label: Text('\u2190', style: TextStyle(color: theme.text)),
                icon: Icon(Icons.arrow_back, size: 16),
              ),
              ButtonSegment(
                value: PdfLayoutDirection.horizontalRtl,
                label: Text('\u2192', style: TextStyle(color: theme.text)),
                icon: Icon(Icons.arrow_forward, size: 16),
              ),
            ],
            selected: {settings.pdfLayoutDirection},
            showSelectedIcon: false,
            onSelectionChanged: (s) =>
                _update(() => settings.pdfLayoutDirection = s.first),
          ),
        ],
      ),
      _ToggleRow(
        icon: Icons.view_stream,
        label: 'Continuous scroll',
        value: settings.pdfContinuousScroll,
        theme: theme,
        onChanged: (v) => _update(() => settings.pdfContinuousScroll = v),
      ),
      // ── Zoom fit ───────────────────────────────────────────────
      if (widget.onPdfFitWidth != null || widget.onPdfFitPage != null)
        Row(
          children: [
            Icon(Icons.zoom_in, color: theme.muted, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Zoom fit',
                style: TextStyle(fontSize: 14, color: theme.text),
              ),
            ),
            if (widget.onPdfFitWidth != null)
              TextButton(
                onPressed: widget.onPdfFitWidth,
                child: Text(
                  'Width',
                  style: TextStyle(color: theme.accent, fontSize: 13),
                ),
              ),
            if (widget.onPdfFitPage != null)
              TextButton(
                onPressed: widget.onPdfFitPage,
                child: Text(
                  'Page',
                  style: TextStyle(color: theme.accent, fontSize: 13),
                ),
              ),
          ],
        ),
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
          () => settings.comicReadingMode = v
              ? ComicReadingMode.paginated
              : ComicReadingMode.vertical,
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
              segments: [
                ButtonSegment(
                  value: ComicReadingDirection.ltr,
                  label: Text('\u2190', style: TextStyle(color: theme.text)),
                  icon: Icon(Icons.arrow_back, size: 16),
                ),
                ButtonSegment(
                  value: ComicReadingDirection.rtl,
                  label: Text('\u2192', style: TextStyle(color: theme.text)),
                  icon: Icon(Icons.arrow_forward, size: 16),
                ),
              ],
              selected: {settings.comicReadingDirection},
              showSelectedIcon: false,
              onSelectionChanged: (s) =>
                  _update(() => settings.comicReadingDirection = s.first),
            ),
          ],
        ),
      ],
      // ── Image fit ─────────────────────────────────────────────
      Row(
        children: [
          Icon(Icons.fit_screen, color: theme.muted, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Image fit',
              style: TextStyle(fontSize: 14, color: theme.text),
            ),
          ),
          SegmentedButton<ComicFitMode>(
            segments: [
              ButtonSegment(
                value: ComicFitMode.contain,
                label: Text('Fit', style: TextStyle(color: theme.text)),
              ),
              ButtonSegment(
                value: ComicFitMode.fitWidth,
                label: Text('Width', style: TextStyle(color: theme.text)),
              ),
              ButtonSegment(
                value: ComicFitMode.fitHeight,
                label: Text('Height', style: TextStyle(color: theme.text)),
              ),
            ],
            selected: {settings.comicFitMode},
            showSelectedIcon: false,
            onSelectionChanged: (s) =>
                _update(() => settings.comicFitMode = s.first),
          ),
        ],
      ),
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
            ? Icon(
                Icons.dark_mode_outlined,
                size: 18,
                color: selected ? colors.accent : colors.muted,
              )
            : mode == ReaderThemeMode.dusk
            ? Icon(
                Icons.nightlight_outlined,
                size: 18,
                color: selected ? colors.accent : colors.muted,
              )
            : mode == ReaderThemeMode.oled
            ? Icon(
                Icons.lens_blur_outlined,
                size: 18,
                color: selected ? colors.accent : colors.muted,
              )
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
  const _HoverableDropdownItem({required this.font, required this.theme});

  final ReaderFont font;
  final ReaderTheme theme;

  @override
  State<_HoverableDropdownItem> createState() => _HoverableDropdownItemState();
}

class _HoverableDropdownItemState extends State<_HoverableDropdownItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
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
          color: _hovered ? widget.theme.muted.withValues(alpha: 0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: TextStyle(fontSize: 14, color: widget.theme.text),
        ),
      ),
    );
  }
}

class _CssOverrideToggle extends StatelessWidget {
  const _CssOverrideToggle({
    required this.label,
    required this.value,
    required this.onChanged,
    required this.theme,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  final ReaderTheme theme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 30),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(color: theme.muted, fontSize: 13),
            ),
          ),
          Switch(
            value: value,
            activeThumbColor: theme.accent,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}
