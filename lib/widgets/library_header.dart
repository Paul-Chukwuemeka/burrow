import 'package:flutter/material.dart';

import '../models/library_enums.dart';
import '../theme/burrow_tokens.dart';
import 'library_filter_widgets.dart';

class BurrowHeader extends StatelessWidget {
  const BurrowHeader({
    required this.tab,
    required this.onTabChanged,
    this.activeFilterCount = 0,
    this.onFilterTap,
    this.onStats,
    this.onRemoveAllMissing,
    this.missingCount = 0,
    this.onSettings,
    this.onSearch,
  });

  final LibraryTab tab;
  final ValueChanged<LibraryTab> onTabChanged;
  final int activeFilterCount;
  final VoidCallback? onFilterTap;
  final VoidCallback? onStats;
  final VoidCallback? onRemoveAllMissing;
  final int missingCount;
  final VoidCallback? onSettings;
  final VoidCallback? onSearch;

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
        if (onSearch != null)
          IconButton(
            icon: Icon(Icons.search_rounded, color: scheme.onSurface),
            onPressed: onSearch,
            tooltip: 'Search',
          ),
        if (onFilterTap != null)
          FilterIconButton(activeCount: activeFilterCount, onTap: onFilterTap!),
        if (onStats != null)
          IconButton(
            icon: Icon(Icons.bar_chart_rounded, color: scheme.onSurface),
            onPressed: onStats,
            tooltip: 'Reading stats',
          ),
        if (onRemoveAllMissing != null || onSettings != null)
          PopupMenuButton<String>(
            icon: Icon(Icons.more_vert_rounded, color: scheme.onSurface),
            tooltip: 'More options',
            onSelected: (key) {
              if (key == 'remove-missing' && missingCount > 0) {
                onRemoveAllMissing?.call();
              }
              if (key == 'settings') onSettings?.call();
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'remove-missing',
                enabled: missingCount > 0,
                child: ListTile(
                  leading: const Icon(Icons.delete_sweep_outlined),
                  title: Text(
                    missingCount > 0
                        ? 'Remove all missing ($missingCount)'
                        : 'Remove all missing',
                  ),
                ),
              ),
              const PopupMenuItem(
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
          // The label pill is part of the tap target: tapping the visible
          // label must run the action, not dead-end.
          Material(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.96),
            shape: RoundedRectangleBorder(
              borderRadius: Burrow.r(Burrow.shapeSm),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
                child: Text(
                  label,
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w700,
                  ),
                ),
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
