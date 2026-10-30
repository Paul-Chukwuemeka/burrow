import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../models/book.dart';
import '../theme/burrow_tokens.dart';
import 'pill_chip.dart';

enum ReadingStatus { all, reading, finished, new_ }

class SearchField extends StatelessWidget {
  const SearchField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        style: Theme.of(context).textTheme.bodyLarge,
        decoration: InputDecoration(
          hintText: 'Search your burrow',
          prefixIcon: const Icon(Icons.search_rounded),
          suffixIcon: controller.text.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close_rounded, size: 20),
                  onPressed: () {
                    controller.clear();
                    onChanged('');
                  },
                ),
          filled: true,
          fillColor: scheme.surfaceContainerHighest,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 14),
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: OutlineInputBorder(
            borderRadius: Burrow.r(Burrow.shapeLg),
            borderSide: BorderSide(color: scheme.primary, width: 2),
          ),
        ),
      ),
    );
  }
}

class FilterIconButton extends StatelessWidget {
  const FilterIconButton({required this.activeCount, required this.onTap});

  final int activeCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: 'Filters${activeCount > 0 ? ' ($activeCount active)' : ''}',
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            IconButton(
              icon: Icon(
                Icons.tune_rounded,
                color: activeCount > 0 ? scheme.primary : scheme.onSurface,
              ),
              onPressed: onTap,
            ),
            if (activeCount > 0)
              Positioned(
                top: 4,
                right: 4,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    '$activeCount',
                    style: TextStyle(
                      color: scheme.onPrimary,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      height: 1,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class FilterSheet extends StatefulWidget {
  const FilterSheet({
    required this.statusFilter,
    required this.genreFilter,
    required this.seriesFilter,
    required this.formatFilters,
    required this.books,
    required this.onStatusChanged,
    required this.onGenreChanged,
    required this.onSeriesChanged,
    required this.onFormatsChanged,
    required this.onClearAll,
  });

  final ReadingStatus statusFilter;
  final String? genreFilter;
  final String? seriesFilter;
  final Set<BookFormat> formatFilters;
  final List<Book> books;
  final ValueChanged<ReadingStatus> onStatusChanged;
  final ValueChanged<String?> onGenreChanged;
  final ValueChanged<String?> onSeriesChanged;
  final ValueChanged<Set<BookFormat>> onFormatsChanged;
  final VoidCallback onClearAll;

  @override
  State<FilterSheet> createState() => FilterSheetState();
}

class FilterSheetState extends State<FilterSheet> {
  late ReadingStatus _status;
  late String? _genre;
  late String? _series;
  late Set<BookFormat> _formats;

  @override
  void initState() {
    super.initState();
    _status = widget.statusFilter;
    _genre = widget.genreFilter;
    _series = widget.seriesFilter;
    _formats = Set<BookFormat>.from(widget.formatFilters);
  }

  void _toggleFormat(BookFormat f) {
    setState(() {
      if (_formats.contains(f)) {
        _formats.remove(f);
      } else {
        _formats.add(f);
      }
      widget.onFormatsChanged(_formats);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final genres = <String>{};
    for (final b in widget.books) {
      if (b.genre != null) {
        for (final g in b.genre!.split(',')) {
          final trimmed = g.trim();
          if (trimmed.isNotEmpty) genres.add(trimmed);
        }
      }
    }
    final sortedGenres = genres.toList()..sort();

    final seriesSet = <String>{};
    for (final b in widget.books) {
      if (b.seriesName != null && b.seriesName!.isNotEmpty) {
        seriesSet.add(b.seriesName!);
      }
    }
    final sortedSeries = seriesSet.toList()..sort();

    final hasActive =
        _status != ReadingStatus.all ||
        _genre != null ||
        _series != null ||
        _formats.isNotEmpty;

    return DraggableScrollableSheet(
      initialChildSize: 0.5,
      minChildSize: 0.3,
      maxChildSize: 0.85,
      expand: false,
      builder: (context, scrollController) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Filters',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (hasActive)
                  TextButton(
                    onPressed: () {
                      widget.onClearAll();
                      Navigator.of(context).pop();
                    },
                    child: const Text('Clear all'),
                  ),
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
              children: [
                FilterSection(
                  label: 'Reading status',
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      PillChip(
                        label: 'All',
                        selected: _status == ReadingStatus.all,
                        onTap: () => setState(() {
                          _status = ReadingStatus.all;
                          widget.onStatusChanged(_status);
                        }),
                      ),
                      PillChip(
                        label: 'Reading',
                        selected: _status == ReadingStatus.reading,
                        onTap: () => setState(() {
                          _status = ReadingStatus.reading;
                          widget.onStatusChanged(_status);
                        }),
                      ),
                      PillChip(
                        label: 'Finished',
                        selected: _status == ReadingStatus.finished,
                        onTap: () => setState(() {
                          _status = ReadingStatus.finished;
                          widget.onStatusChanged(_status);
                        }),
                      ),
                      PillChip(
                        label: 'New',
                        selected: _status == ReadingStatus.new_,
                        onTap: () => setState(() {
                          _status = ReadingStatus.new_;
                          widget.onStatusChanged(_status);
                        }),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                FilterSection(
                  label: 'Format',
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      PillChip(
                        label: 'All formats',
                        selected: _formats.isEmpty,
                        onTap: () => setState(() {
                          _formats.clear();
                          widget.onFormatsChanged(_formats);
                        }),
                      ),
                      for (final f in BookFormat.values)
                        PillChip(
                          label: f.name.toUpperCase(),
                          selected: _formats.contains(f),
                          onTap: () => _toggleFormat(f),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                if (sortedGenres.isNotEmpty)
                  FilterSection(
                    label: 'Genre',
                    child: _CollapsibleChipWrap(
                      children: [
                        PillChip(
                          label: 'All genres',
                          selected: _genre == null,
                          onTap: () => setState(() {
                            _genre = null;
                            widget.onGenreChanged(null);
                          }),
                        ),
                        for (final g in sortedGenres)
                          PillChip(
                            label: g,
                            selected:
                                _genre?.toLowerCase() ==
                                g.toLowerCase(),
                            onTap: () => setState(() {
                              _genre = g;
                              widget.onGenreChanged(g);
                            }),
                          ),
                      ],
                    ),
                  ),
                if (sortedGenres.isNotEmpty) const SizedBox(height: 24),
                if (sortedSeries.isNotEmpty)
                  FilterSection(
                    label: 'Series',
                    child: _CollapsibleChipWrap(
                      children: [
                        PillChip(
                          label: 'All series',
                          selected: _series == null,
                          onTap: () => setState(() {
                            _series = null;
                            widget.onSeriesChanged(null);
                          }),
                        ),
                        for (final s in sortedSeries)
                          PillChip(
                            label: s,
                            selected: _series?.toLowerCase() == s.toLowerCase(),
                            onTap: () => setState(() {
                              _series = s;
                              widget.onSeriesChanged(s);
                            }),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Chip geometry shared by the filter sheet's collapsible chip sections:
/// one chip line is 48px tall (PillChip's minimum) with 8px between lines.
const double _chipLineHeight = 48;
const double _chipRunSpacing = 8;

/// Collapsed previews hide everything past the third chip line.
const double _chipThreeLines = _chipLineHeight * 3 + _chipRunSpacing * 2;

/// A chip list that collapses to three lines behind a "Show more" toggle.
///
/// The toggle appears only when the chips actually need more than three lines,
/// measured from layout — so it never shows up to reveal nothing.
class _CollapsibleChipWrap extends StatefulWidget {
  const _CollapsibleChipWrap({required this.children});

  final List<Widget> children;

  @override
  State<_CollapsibleChipWrap> createState() => _CollapsibleChipWrapState();
}

class _CollapsibleChipWrapState extends State<_CollapsibleChipWrap> {
  bool _expanded = false;
  bool _overflows = false;

  void _onNaturalHeight(double height) {
    final overflows = height > _chipThreeLines;
    if (overflows != _overflows && mounted) {
      setState(() => _overflows = overflows);
    }
  }

  void _toggle() => setState(() => _expanded = !_expanded);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRect(
          child: _MeasuredClampWrap(
            clampHeight: _expanded ? double.infinity : _chipThreeLines,
            onNaturalHeight: _onNaturalHeight,
            child: Wrap(
              spacing: 8,
              runSpacing: _chipRunSpacing,
              children: widget.children,
            ),
          ),
        ),
        if (_overflows)
          GestureDetector(
            onTap: _toggle,
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _expanded ? 'Show less' : 'Show more',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Lays out its child at full natural height but clamps its own height to
/// [clampHeight] (with [ClipRect] above truncating paint and hit tests), and
/// reports the child's natural height through [onNaturalHeight] once per frame.
class _MeasuredClampWrap extends SingleChildRenderObjectWidget {
  const _MeasuredClampWrap({
    required this.clampHeight,
    required this.onNaturalHeight,
    super.child,
  });

  final double clampHeight;
  final ValueChanged<double> onNaturalHeight;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMeasuredClamp(clampHeight, onNaturalHeight);

  @override
  void updateRenderObject(BuildContext context, covariant _RenderMeasuredClamp renderObject) {
    renderObject
      ..clampHeight = clampHeight
      ..onNaturalHeight = onNaturalHeight;
  }
}

class _RenderMeasuredClamp extends RenderProxyBox {
  _RenderMeasuredClamp(double clampHeight, ValueChanged<double> onNaturalHeight)
    : _clampHeight = clampHeight,
      _onNaturalHeight = onNaturalHeight;

  double _clampHeight;
  double get clampHeight => _clampHeight;
  set clampHeight(double v) {
    if (_clampHeight == v) return;
    _clampHeight = v;
    markNeedsLayout();
  }

  ValueChanged<double> _onNaturalHeight;
  set onNaturalHeight(ValueChanged<double> v) => _onNaturalHeight = v;

  double? _reportedHeight;

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    // Lay out the child without a height limit so overflow past the clamp is
    // measurable, then clamp this render object's own height for display.
    child.layout(constraints.copyWith(maxHeight: double.infinity), parentUsesSize: true);
    size = constraints.constrain(
      Size(child.size.width, math.min(child.size.height, clampHeight)),
    );
    final natural = child.size.height;
    if (_reportedHeight != natural) {
      _reportedHeight = natural;
      // Callbacks must not run during layout; defer to after the frame.
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (attached) _onNaturalHeight(natural);
      });
    }
  }
}

class FilterSection extends StatelessWidget {
  const FilterSection({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 10),
        child,
      ],
    );
  }
}
