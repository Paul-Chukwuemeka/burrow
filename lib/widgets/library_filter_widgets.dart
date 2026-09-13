import 'package:flutter/material.dart';

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

class FilterRow extends StatelessWidget {
  const FilterRow({
    required this.filter,
    required this.onFilter,
    required this.activeFilterCount,
    required this.onFilterTap,
  });

  final BookFormat? filter;
  final ValueChanged<BookFormat?> onFilter;
  final int activeFilterCount;
  final VoidCallback onFilterTap;

  @override
  Widget build(BuildContext context) {
    Widget chip(String label, BookFormat? value) {
      return PillChip(
        label: label,
        selected: filter == value,
        onTap: () => onFilter(value),
      );
    }

    return SizedBox(
      height: 64,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        children: [
          chip('All', null),
          const SizedBox(width: 8),
          chip('EPUB', BookFormat.epub),
          const SizedBox(width: 8),
          chip('TXT', BookFormat.txt),
          const SizedBox(width: 8),
          chip('PDF', BookFormat.pdf),
          const SizedBox(width: 8),
          FilterIconButton(activeCount: activeFilterCount, onTap: onFilterTap),
        ],
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
        child: Material(
          color: activeCount > 0 ? scheme.primary : Colors.transparent,
          shape: StadiumBorder(
            side: BorderSide(
              color: activeCount > 0
                  ? scheme.primary
                  : scheme.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Icon(
                      Icons.tune_rounded,
                      size: 18,
                      color: activeCount > 0
                          ? scheme.onPrimary
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                  if (activeCount > 0)
                    Positioned(
                      top: -6,
                      right: -8,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: scheme.onPrimary,
                          shape: BoxShape.circle,
                        ),
                        child: Text(
                          '$activeCount',
                          style: TextStyle(
                            color: scheme.primary,
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
          ),
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
  bool _genresExpanded = false;

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
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ClipRect(
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxHeight: _genresExpanded
                                  ? double.infinity
                                  : 130,
                            ),
                            child: Wrap(
                              spacing: 8,
                              runSpacing: 8,
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
                        ),
                        if (sortedGenres.length > 6)
                          GestureDetector(
                            onTap: () => setState(
                              () => _genresExpanded = !_genresExpanded,
                            ),
                            child: Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(
                                _genresExpanded ? 'Show less' : 'Show more',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                if (sortedGenres.isNotEmpty) const SizedBox(height: 24),
                if (sortedSeries.isNotEmpty)
                  FilterSection(
                    label: 'Series',
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
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
