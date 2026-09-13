import 'package:flutter/material.dart';

import '../models/book.dart';
import '../models/library_enums.dart';
import '../theme/burrow_tokens.dart';

class BurrowHeader extends StatelessWidget {
  const BurrowHeader({
    required this.tab,
    required this.onTabChanged,
    this.filter,
    this.onFormatFilterChanged,
    this.onStats,
    this.onExport,
    this.onImportBackup,
    this.onSettings,
  });

  final LibraryTab tab;
  final ValueChanged<LibraryTab> onTabChanged;
  final BookFormat? filter;
  final ValueChanged<BookFormat?>? onFormatFilterChanged;
  final VoidCallback? onStats;
  final VoidCallback? onExport;
  final VoidCallback? onImportBackup;
  final VoidCallback? onSettings;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SliverAppBar(
      pinned: true,
      title: Text(
        'burrow',
        style: Theme.of(context).textTheme.headlineSmall?.copyWith(
          fontWeight: FontWeight.w800,
          letterSpacing: -0.5,
          color: scheme.onSurface,
        ),
      ),
      actions: [
        if (onFormatFilterChanged != null)
          PopupMenuButton<BookFormat?>(
            icon: Icon(
              filter != null
                  ? Icons.filter_list_rounded
                  : Icons.filter_list_off_rounded,
              color: filter != null ? scheme.primary : scheme.onSurface,
            ),
            tooltip: 'Filter formats',
            onSelected: onFormatFilterChanged,
            itemBuilder: (_) => [
              PopupMenuItem(
                value: null,
                child: ListTile(
                  leading: Icon(
                    filter == null
                        ? Icons.check_circle_rounded
                        : Icons.circle_outlined,
                    color: filter == null ? scheme.primary : null,
                    size: 20,
                  ),
                  title: const Text('All formats'),
                ),
              ),
              for (final f in BookFormat.values)
                PopupMenuItem(
                  value: f,
                  child: ListTile(
                    leading: Icon(
                      filter == f
                          ? Icons.check_circle_rounded
                          : Icons.circle_outlined,
                      color: filter == f ? scheme.primary : null,
                      size: 20,
                    ),
                    title: Text(f.name.toUpperCase()),
                  ),
                ),
            ],
          ),
        if (onStats != null)
          IconButton(
            icon: Icon(Icons.bar_chart_rounded, color: scheme.onSurface),
            onPressed: onStats,
            tooltip: 'Reading stats',
          ),
        if (onExport != null && onImportBackup != null)
          PopupMenuButton<String>(
            icon: Icon(Icons.more_vert_rounded, color: scheme.onSurface),
            tooltip: 'More options',
            onSelected: (key) {
              if (key == 'export') onExport!();
              if (key == 'import') onImportBackup!();
              if (key == 'settings') onSettings?.call();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'export',
                child: ListTile(
                  leading: Icon(Icons.ios_share_rounded),
                  title: Text('Export library'),
                ),
              ),
              PopupMenuItem(
                value: 'import',
                child: ListTile(
                  leading: Icon(Icons.restore_rounded),
                  title: Text('Restore backup'),
                ),
              ),
              PopupMenuItem(
                value: 'settings',
                child: ListTile(
                  leading: Icon(Icons.settings_outlined),
                  title: Text('Settings'),
                ),
              ),
            ],
          ),
      ],
      bottom: TabBar(
        onTap: (i) => onTabChanged(LibraryTab.values[i]),
        tabs: const [
          Tab(text: 'Books'),
          Tab(text: 'Authors'),
          Tab(text: 'Collections'),
        ],
        labelColor: scheme.primary,
        unselectedLabelColor: scheme.onSurfaceVariant,
        indicatorColor: scheme.primary,
        indicatorSize: TabBarIndicatorSize.label,
        labelStyle: const TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 14,
          letterSpacing: 0.2,
        ),
        unselectedLabelStyle: const TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 14,
        ),
      ),
    );
  }
}

class FabMenuItem extends StatelessWidget {
  const FabMenuItem({
    required this.icon,
    required this.label,
    required this.scheme,
    required this.delay,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final ColorScheme scheme;
  final double delay;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 380),
      curve: Interval(delay, 1, curve: Easing.emphasizedDecelerate),
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(24 * (1 - t), 0),
          child: Transform.scale(scale: 0.8 + 0.2 * t, child: child),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.96),
              borderRadius: Burrow.r(Burrow.shapeSm),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: scheme.onSurface,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Material(
            color: scheme.primary,
            shape: RoundedRectangleBorder(
              borderRadius: Burrow.r(Burrow.shapeLg),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              child: SizedBox(
                width: 54,
                height: 54,
                child: Icon(icon, size: 22, color: scheme.onPrimary),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
