import 'package:flutter/material.dart';

import '../controllers/book_selection.dart';
import '../db/database.dart' as db;
import '../models/book.dart';
import '../services/library_service.dart';
import '../theme/burrow_tokens.dart';
import '../utils/book_title.dart';
import '../utils/comic_series.dart';
import '../widgets/book_card.dart';
import '../widgets/book_cover.dart';
import '../widgets/book_grid.dart';
import '../widgets/pill_chip.dart';
import 'book_info_screen.dart';

enum _SortMode { manual, title, recent }

enum _LayoutMode { grid, list }

class _BookGroup {
  final String? name;
  final List<Book> books;
  const _BookGroup(this.name, this.books);
}

class CollectionScreen extends StatefulWidget {
  const CollectionScreen({
    super.key,
    required this.collection,
    required this.library,
  });

  final db.Collection collection;
  final LibraryService library;

  @override
  State<CollectionScreen> createState() => _CollectionScreenState();
}

class _CollectionScreenState extends State<CollectionScreen> {
  late _SortMode _sort;
  late _LayoutMode _layout;
  List<Book> _books = [];
  bool _reorderMode = false;

  late final _selection = BookSelection();

  void _onSelectionChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _selection.addListener(_onSelectionChanged);
    _sort = _SortMode.values[widget.collection.sortType.clamp(0, 2)];
    _layout = widget.library.libraryLayout == 'list'
        ? _LayoutMode.list
        : _LayoutMode.grid;
    _loadBooks();
  }

  @override
  void dispose() {
    _selection.removeListener(_onSelectionChanged);
    _selection.dispose();
    super.dispose();
  }

  Future<void> _loadBooks() async {
    final books = await widget.library.getBooksForCollection(
      widget.collection.id,
    );
    if (!mounted) return;
    setState(() => _books = books);
  }

  String _sortLabel(_SortMode m) => switch (m) {
    _SortMode.manual => 'Manual',
    _SortMode.title => 'A–Z',
    _SortMode.recent => 'Recent',
  };

  void _applySort() {
    switch (_sort) {
      case _SortMode.manual:
        break; // Keep DB order
      case _SortMode.title:
        _books.sort(
          (a, b) => a.displayTitle.toLowerCase().compareTo(
            b.displayTitle.toLowerCase(),
          ),
        );
      case _SortMode.recent:
        _books.sort((a, b) => b.lastReadAt.compareTo(a.lastReadAt));
    }
  }

  Future<void> _openBookInfo(Book book) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BookInfoScreen(book: book, library: widget.library),
      ),
    );
    if (mounted) {
      _loadBooks();
      setState(() {});
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// Books currently selected, in visible order.
  List<Book> get _selectedBooks {
    final ids = _selection.selectedIds;
    return _books.where((b) => ids.contains(b.id)).toList();
  }

  void _selectAllVisible() {
    _selection.selectAll(_books.map((b) => b.id));
  }

  /// Contextual action bar shown while books are selected. Mirrors the
  /// library screen pattern (Task 4); the bulk action here removes from
  /// this collection instead of deleting.
  Widget _selectionBar() {
    final scheme = Theme.of(context).colorScheme;
    final selected = _selectedBooks;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Material(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(Burrow.shapeSm + 4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.close_rounded),
                color: scheme.onPrimaryContainer,
                tooltip: 'Clear selection',
                onPressed: _selection.clear,
              ),
              Expanded(
                child: Text(
                  '${_selection.count} selected',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: scheme.onPrimaryContainer,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
              ),
              TextButton(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 36),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: _selectAllVisible,
                child: const Text('Select all'),
              ),
              // Exactly one book: the single-book remove sheet stays
              // reachable.
              if (selected.length == 1)
                IconButton(
                  icon: const Icon(Icons.more_vert_rounded),
                  color: scheme.onPrimaryContainer,
                  tooltip: 'More actions',
                  onPressed: () => _showRemoveBook(selected.first),
                ),
              IconButton(
                icon: const Icon(Icons.delete_outline_rounded),
                color: scheme.onPrimaryContainer,
                tooltip: 'Remove from collection',
                onPressed: () => _showRemoveSelectedSheet(_selectedBooks),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Batch remove-from-collection sheet: one confirm step for N books, then
  /// a collected-errors [LibraryService.removeBookFromCollection] loop (no
  /// new service API). Notification comes from the loop's ops.
  void _showRemoveSelectedSheet(List<Book> books) {
    if (books.isEmpty) return;
    final scheme = Theme.of(context).colorScheme;
    final ids = [for (final b in books) b.id];
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        minimum: const EdgeInsets.only(bottom: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
              child: Text(
                books.length == 1
                    ? 'Remove "${books.first.displayTitle}" from this collection?'
                    : 'Remove ${books.length} books from this collection?',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(sheetContext),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: scheme.errorContainer,
                        foregroundColor: scheme.onErrorContainer,
                      ),
                      onPressed: () async {
                        Navigator.pop(sheetContext);
                        var removed = 0;
                        final errors = <Object>[];
                        for (final id in ids) {
                          try {
                            await widget.library.removeBookFromCollection(
                              widget.collection.id,
                              id,
                            );
                            removed++;
                          } catch (e) {
                            errors.add(e);
                          }
                        }
                        if (!mounted) return;
                        _selection.clear();
                        await _loadBooks();
                        if (!mounted) return;
                        if (errors.isEmpty) {
                          _snack(
                            'Removed $removed book${removed == 1 ? '' : 's'} '
                            'from "${widget.collection.name}"',
                          );
                        } else if (removed == 0) {
                          _snack('${errors.length} of ${ids.length} failed');
                        } else {
                          _snack(
                            'Removed $removed of ${ids.length} '
                            '(${errors.length} failed)',
                          );
                        }
                      },
                      child: const Text('Remove'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _onReorder(int oldIndex, int newIndex) async {
    if (oldIndex < newIndex) newIndex--;
    final item = _books.removeAt(oldIndex);
    _books.insert(newIndex, item);
    setState(() {});
    // Persist new order
    final bookIds = _books.map((b) => b.id).toList();
    await widget.library.reorderCollectionBook(widget.collection.id, bookIds);
  }

  void _showRemoveBook(Book book) {
    final scheme = Theme.of(context).colorScheme;
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        minimum: const EdgeInsets.only(bottom: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
              child: Text(
                'Remove "${book.displayTitle}" from this collection?',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(sheetContext),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: scheme.errorContainer,
                        foregroundColor: scheme.onErrorContainer,
                      ),
                      onPressed: () {
                        Navigator.pop(sheetContext);
                        widget.library.removeBookFromCollection(
                          widget.collection.id,
                          book.id,
                        );
                        _loadBooks();
                      },
                      child: const Text('Remove'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    _applySort();

    return PopScope(
      // Back clears the selection first instead of leaving the screen.
      canPop: !_selection.isSelecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selection.isSelecting) _selection.clear();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.collection.name),
              if (_books.isNotEmpty)
                Text(
                  '${_books.length} book${_books.length == 1 ? '' : 's'}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          actions: [
            if (_sort == _SortMode.manual)
              IconButton(
                icon: Icon(
                  _reorderMode ? Icons.done_rounded : Icons.reorder_rounded,
                ),
                tooltip: _reorderMode ? 'Done' : 'Reorder',
                onPressed: () => setState(() => _reorderMode = !_reorderMode),
              ),
            PillChip(
              label: _sortLabel(_sort),
              icon: Icons.sort_rounded,
              onTap: () => setState(() {
                _sort = _SortMode
                    .values[(_sort.index + 1) % _SortMode.values.length];
                if (_sort != _SortMode.manual) _reorderMode = false;
              }),
            ),
            const SizedBox(width: 8),
            if (!_reorderMode) ...[
              PillChip(
                label: _layout == _LayoutMode.grid ? 'Grid' : 'List',
                icon: _layout == _LayoutMode.grid
                    ? Icons.grid_view_rounded
                    : Icons.view_list_rounded,
                onTap: () {
                  final next = _LayoutMode
                      .values[(_layout.index + 1) % _LayoutMode.values.length];
                  setState(() => _layout = next);
                  widget.library.saveLibraryLayout(next.name);
                },
              ),
              const SizedBox(width: 8),
            ],
          ],
        ),
        body: _books.isEmpty
            ? Center(
                child: Text(
                  'No books in this collection',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              )
            : Column(
                children: [
                  if (_selection.isSelecting) _selectionBar(),
                  Expanded(
                    child: _reorderMode
                        ? _reorderableList(context)
                        : _layout == _LayoutMode.grid
                        ? _bookGrid(context)
                        : _bookList(),
                  ),
                ],
              ),
      ),
    );
  }

  List<_BookGroup> get _groupedBooks {
    final comics = _books
        .where((b) => b.format == BookFormat.cbz || b.format == BookFormat.cbr)
        .toList();
    final others = _books
        .where((b) => b.format != BookFormat.cbz && b.format != BookFormat.cbr)
        .toList();

    if (comics.isEmpty) {
      return [if (_books.isNotEmpty) _BookGroup(null, _books)];
    }

    final seriesMap = <String, List<Book>>{};
    for (final comic in comics) {
      final series = comic.effectiveSeriesName;
      if (series != null && series.isNotEmpty) {
        seriesMap.putIfAbsent(series, () => []).add(comic);
      } else {
        seriesMap.putIfAbsent('', () => []).add(comic);
      }
    }

    final groups = <_BookGroup>[];
    final sortedKeys = seriesMap.keys.toList()
      ..sort((a, b) {
        if (a.isEmpty) return 1;
        if (b.isEmpty) return -1;
        return a.toLowerCase().compareTo(b.toLowerCase());
      });

    for (final key in sortedKeys) {
      final books = seriesMap[key]!;
      books.sort((a, b) {
        final ai = a.effectiveSeriesIndex ?? double.infinity;
        final bi = b.effectiveSeriesIndex ?? double.infinity;
        return ai.compareTo(bi);
      });
      groups.add(_BookGroup(key.isEmpty ? null : key, books));
    }

    if (others.isNotEmpty) {
      groups.add(_BookGroup(null, others));
    }

    return groups;
  }

  Widget _bookGrid(BuildContext context) {
    if (_shouldShowSeriesFolders) return _seriesFolderGrid(context);
    final groups = _groupedBooks;
    if (groups.length == 1) {
      // Single group — no header, even when it has a series name.
      // Avoids the redundant "Series / 1 book" view.
      return _flatGrid(context, groups.first.books);
    }
    return _groupedGrid(context, groups);
  }

  Widget _flatGrid(BuildContext context, List<Book> books) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth - kBookGridPadding * 2;
        return GridView.builder(
          padding: const EdgeInsets.all(kBookGridPadding),
          gridDelegate: bookGridDelegate(width),
          itemCount: books.length,
          itemBuilder: (context, i) {
            final book = books[i];
            return BookCard(
              book: book,
              selected: _selection.selectedIds.contains(book.id),
              onTap: () => _selection.isSelecting
                  ? _selection.toggle(book.id)
                  : _openBookInfo(book),
              onLongPress: () => _selection.isSelecting
                  ? _selection.toggle(book.id)
                  : _selection.enter(book.id),
            );
          },
        );
      },
    );
  }

  Widget _groupedGrid(BuildContext context, List<_BookGroup> groups) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth - kBookGridPadding * 2;
        return ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: groups.length,
          itemBuilder: (context, gi) {
            final group = groups[gi];
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (group.name != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                    child: Text(
                      group.name!,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                GridView.builder(
                  padding: const EdgeInsets.symmetric(
                    horizontal: kBookGridPadding,
                  ),
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: bookGridDelegate(width),
                  itemCount: group.books.length,
                  itemBuilder: (context, i) {
                    final book = group.books[i];
                    return BookCard(
                      book: book,
                      selected: _selection.selectedIds.contains(book.id),
                      onTap: () => _selection.isSelecting
                          ? _selection.toggle(book.id)
                          : _openBookInfo(book),
                      onLongPress: () => _selection.isSelecting
                          ? _selection.toggle(book.id)
                          : _selection.enter(book.id),
                    );
                  },
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _bookList() {
    if (_shouldShowSeriesFolders) return _seriesFolderList();
    final groups = _groupedBooks;
    if (groups.length == 1) {
      return _flatList(groups.first.books);
    }
    return _groupedList(groups);
  }

  Widget _flatList(List<Book> books) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: books.length,
      itemBuilder: (context, i) {
        final book = books[i];
        return BookListCard(
          book: book,
          selected: _selection.selectedIds.contains(book.id),
          onTap: () => _selection.isSelecting
              ? _selection.toggle(book.id)
              : _openBookInfo(book),
          onLongPress: () => _selection.isSelecting
              ? _selection.toggle(book.id)
              : _selection.enter(book.id),
        );
      },
    );
  }

  Widget _groupedList(List<_BookGroup> groups) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: groups.length,
      itemBuilder: (context, gi) {
        final group = groups[gi];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (group.name != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                child: Text(
                  group.name!,
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
            for (final book in group.books)
              BookListCard(
                book: book,
                selected: _selection.selectedIds.contains(book.id),
                onTap: () => _selection.isSelecting
                    ? _selection.toggle(book.id)
                    : _openBookInfo(book),
                onLongPress: () => _selection.isSelecting
                    ? _selection.toggle(book.id)
                    : _selection.enter(book.id),
              ),
          ],
        );
      },
    );
  }

  /// Named comic-series groups (virtual folders). Single-series collections
  /// with no loose books skip folders and show books directly.
  List<_BookGroup> get _seriesFolders {
    final groups = _groupedBooks;
    return groups.where((g) => g.name != null).toList();
  }

  List<Book> get _looseBooks {
    final groups = _groupedBooks;
    return [for (final g in groups.where((g) => g.name == null)) ...g.books];
  }

  bool get _shouldShowSeriesFolders {
    final folders = _seriesFolders;
    if (folders.isEmpty) return false;
    if (folders.length >= 2) return true;
    // One series plus loose books: folder + loose section.
    return _looseBooks.isNotEmpty;
  }

  void _openSeries(String name, List<Book> books) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _SeriesBooksScreen(
          title: name,
          books: books,
          library: widget.library,
          layout: _layout,
        ),
      ),
    );
  }

  Widget _seriesFolderGrid(BuildContext context) {
    final folders = _seriesFolders;
    final loose = _looseBooks;
    final itemCount = folders.length + (loose.isNotEmpty ? 1 : 0);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth - kBookGridPadding * 2;
        return GridView.builder(
          padding: const EdgeInsets.all(kBookGridPadding),
          gridDelegate: bookGridDelegate(width),
          itemCount: itemCount,
          itemBuilder: (context, i) {
            if (i < folders.length) {
              final folder = folders[i];
              return _SeriesFolderCard(
                name: folder.name!,
                books: folder.books,
                onTap: () => _openSeries(folder.name!, folder.books),
              );
            }
            return _SeriesFolderCard(
              name: 'Ungrouped',
              books: loose,
              onTap: () => _openSeries('Ungrouped', loose),
            );
          },
        );
      },
    );
  }

  Widget _seriesFolderList() {
    final folders = _seriesFolders;
    final loose = _looseBooks;
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: folders.length + (loose.isNotEmpty ? 1 : 0),
      itemBuilder: (context, i) {
        if (i < folders.length) {
          final folder = folders[i];
          return _seriesFolderTile(
            context,
            folder.name!,
            folder.books,
            () => _openSeries(folder.name!, folder.books),
          );
        }
        return _seriesFolderTile(
          context,
          'Ungrouped',
          loose,
          () => _openSeries('Ungrouped', loose),
        );
      },
    );
  }

  Widget _seriesFolderTile(
    BuildContext context,
    String name,
    List<Book> books,
    VoidCallback onTap,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        leading: SizedBox(
          width: 36,
          height: 54,
          child: BookCover(book: books.first, borderRadius: 6, spine: false),
        ),
        title: Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          '${books.length} book${books.length == 1 ? '' : 's'}',
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: onTap,
      ),
    );
  }

  Widget _reorderableList(BuildContext context) {
    return ReorderableListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      itemCount: _books.length,
      onReorder: _onReorder,
      itemBuilder: (context, i) {
        final book = _books[i];
        return PressableScale(
          key: ValueKey(book.id),
          child: Card(
            margin: const EdgeInsets.symmetric(vertical: 4),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 4,
              ),
              leading: SizedBox(
                width: 36,
                height: 54,
                child: BookCover(book: book, borderRadius: 6, spine: false),
              ),
              title: Text(
                book.displayTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                book.progressLabel,
                style: TextStyle(
                  fontSize: 12,
                  color: book.isStarted
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              trailing: const Icon(Icons.drag_handle_rounded),
            ),
          ),
        );
      },
    );
  }
}

/// Folder tile for a virtual comic series: lead cover + name + count.
class _SeriesFolderCard extends StatelessWidget {
  const _SeriesFolderCard({
    required this.name,
    required this.books,
    required this.onTap,
  });

  final String name;
  final List<Book> books;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  BookCover(
                    book: books.first,
                    borderRadius: 0,
                    spine: false,
                    enforceAspect: false,
                  ),
                  Positioned(
                    right: 6,
                    bottom: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: scheme.scrim.withValues(alpha: 0.7),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.folder_rounded,
                            size: 14,
                            color: scheme.surface,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '${books.length}',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: scheme.surface,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Text(
                '${books.length} book${books.length == 1 ? '' : 's'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Drill-in view for one virtual series folder: flat books, no sub-groups.
class _SeriesBooksScreen extends StatelessWidget {
  const _SeriesBooksScreen({
    required this.title,
    required this.books,
    required this.library,
    required this.layout,
  });

  final String title;
  final List<Book> books;
  final LibraryService library;
  final _LayoutMode layout;

  Future<void> _openBookInfo(BuildContext context, Book book) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BookInfoScreen(book: book, library: library),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title),
            Text(
              '${books.length} book${books.length == 1 ? '' : 's'}',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
      body: layout == _LayoutMode.grid
          ? LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth - kBookGridPadding * 2;
                return GridView.builder(
                  padding: const EdgeInsets.all(kBookGridPadding),
                  gridDelegate: bookGridDelegate(width),
                  itemCount: books.length,
                  itemBuilder: (context, i) {
                    final book = books[i];
                    return BookCard(
                      book: book,
                      onTap: () => _openBookInfo(context, book),
                    );
                  },
                );
              },
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: books.length,
              itemBuilder: (context, i) {
                final book = books[i];
                return BookListCard(
                  book: book,
                  onTap: () => _openBookInfo(context, book),
                );
              },
            ),
    );
  }
}
