import 'dart:io';

import 'package:flutter/material.dart';

import '../controllers/book_selection.dart';
import '../models/book.dart';
import '../services/library_service.dart';
import '../theme/burrow_tokens.dart';
import '../utils/book_title.dart';
import '../widgets/book_card.dart';
import '../widgets/book_cover.dart';
import '../widgets/book_grid.dart';
import '../widgets/pill_chip.dart';
import 'book_info_screen.dart';
import 'reader_screen.dart';

enum _SortMode { title, recent, added }

enum _LayoutMode { grid, list }

class AuthorScreen extends StatefulWidget {
  const AuthorScreen({super.key, required this.author, required this.library});

  final String author;
  final LibraryService library;

  @override
  State<AuthorScreen> createState() => _AuthorScreenState();
}

class _AuthorScreenState extends State<AuthorScreen> {
  _SortMode _sort = _SortMode.title;
  late _LayoutMode _layout;

  late final _selection = BookSelection();

  void _onSelectionChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _selection.addListener(_onSelectionChanged);
    _layout = widget.library.libraryLayout == 'list'
        ? _LayoutMode.list
        : _LayoutMode.grid;
  }

  @override
  void dispose() {
    _selection.removeListener(_onSelectionChanged);
    _selection.dispose();
    super.dispose();
  }

  String _sortLabel(_SortMode m) => switch (m) {
    _SortMode.title => 'A–Z',
    _SortMode.recent => 'Recent',
    _SortMode.added => 'Added',
  };

  List<Book> get _books {
    var list = widget.library.booksByAuthor(widget.author);
    switch (_sort) {
      case _SortMode.title:
        list.sort(
          (a, b) => a.displayTitle.toLowerCase().compareTo(
            b.displayTitle.toLowerCase(),
          ),
        );
      case _SortMode.recent:
        list.sort((a, b) => b.lastReadAt.compareTo(a.lastReadAt));
      case _SortMode.added:
        list.sort((a, b) => b.addedAt.compareTo(a.addedAt));
    }
    return list;
  }

  Future<void> _openBook(Book book) async {
    if (!await File(book.path).exists()) {
      if (!mounted) return;
      final missing = widget.library.isMissing(book.id);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            missing
                ? '"${book.displayTitle}" is marked Missing — locate or remove it'
                : '"${book.displayTitle}" is no longer on this device',
          ),
        ),
      );
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ReaderScreen(book: book, library: widget.library),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _openBookInfo(Book book) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BookInfoScreen(book: book, library: widget.library),
      ),
    );
    if (mounted) setState(() {});
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
  /// library screen pattern (Task 4).
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
              // Exactly one book: the full single-book sheet stays reachable.
              if (selected.length == 1)
                IconButton(
                  icon: const Icon(Icons.more_vert_rounded),
                  color: scheme.onPrimaryContainer,
                  tooltip: 'More actions',
                  onPressed: () => _showBookActions(selected.first),
                ),
              IconButton(
                icon: const Icon(Icons.collections_bookmark_outlined),
                color: scheme.onPrimaryContainer,
                tooltip: 'Add to collection',
                onPressed: () => _showAddBooksToCollectionSheet(_selectedBooks),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline_rounded),
                color: scheme.onPrimaryContainer,
                tooltip: 'Delete',
                onPressed: () => _showRemoveBooksSheet(_selectedBooks),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Batch confirm sheet mirroring [_showRemoveBookSheet] semantics: one
  /// confirm step for N books, then a single [LibraryService.deleteBooks]
  /// call. Errors are collected, never thrown mid-batch.
  void _showRemoveBooksSheet(List<Book> books) {
    if (books.isEmpty) return;
    bool deleteFile = false;
    final scheme = Theme.of(context).colorScheme;
    final ids = [for (final b in books) b.id];
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          minimum: const EdgeInsets.only(bottom: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
                child: Text(
                  books.length == 1
                      ? 'Remove "${books.first.displayTitle}"?'
                      : 'Remove ${books.length} books?',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
              ),
              CheckboxListTile(
                value: deleteFile,
                onChanged: (v) => setSheetState(() => deleteFile = v ?? false),
                title: const Text('Also delete files from disk'),
                controlAffinity: ListTileControlAffinity.leading,
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
                          final (deleted, errors) = await widget.library
                              .deleteBooks(ids, deleteFile: deleteFile);
                          if (!mounted) return;
                          _selection.clear();
                          if (errors.isEmpty) {
                            _snack(
                              'Deleted $deleted book${deleted == 1 ? '' : 's'}',
                            );
                          } else if (deleted == 0) {
                            _snack('${errors.length} of ${ids.length} failed');
                          } else {
                            _snack(
                              'Deleted $deleted of ${ids.length} '
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
      ),
    );
  }

  /// Batch add-to-collection picker: one tap adds every selected book via a
  /// single [LibraryService.addBooksToCollection] call.
  void _showAddBooksToCollectionSheet(List<Book> books) {
    if (books.isEmpty) return;
    final collections = widget.library.collections;
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
                books.length == 1
                    ? 'Add "${books.first.displayTitle}" to…'
                    : 'Add ${books.length} books to…',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (collections.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  'No collections yet',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              )
            else
              ...collections.map(
                (c) => ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                  leading: Icon(
                    Icons.collections_bookmark_outlined,
                    color: scheme.onPrimaryContainer,
                  ),
                  title: Text(c.name),
                  onTap: () async {
                    Navigator.pop(sheetContext);
                    final (added, errors) = await widget.library
                        .addBooksToCollection(c.id, [
                          for (final b in books) b.id,
                        ]);
                    if (!mounted) return;
                    _selection.clear();
                    if (errors.isEmpty) {
                      _snack(
                        'Added $added book${added == 1 ? '' : 's'} to "${c.name}"',
                      );
                    } else if (added == 0) {
                      _snack('${errors.length} of ${books.length} failed');
                    } else {
                      _snack(
                        'Added $added of ${books.length} '
                        '(${errors.length} failed)',
                      );
                    }
                  },
                ),
              ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () {
                    Navigator.pop(sheetContext);
                    _showCreateCollectionAndAddBooksSheet(books);
                  },
                  icon: const Icon(Icons.add_rounded, size: 20),
                  label: const Text('Create new collection'),
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _showCreateCollectionAndAddBooksSheet(List<Book> books) {
    final controller = TextEditingController();
    final scheme = Theme.of(context).colorScheme;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.fromLTRB(
          24,
          24,
          24,
          MediaQuery.of(sheetContext).viewInsets.bottom + 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'New collection',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Name',
                border: OutlineInputBorder(),
              ),
              textCapitalization: TextCapitalization.words,
              onSubmitted: (_) async {
                final name = controller.text.trim();
                if (name.isEmpty) return;
                final id = await widget.library.createCollection(name);
                if (id.isNotEmpty) {
                  await widget.library.addBooksToCollection(id, [
                    for (final b in books) b.id,
                  ]);
                }
                if (!mounted) return;
                _selection.clear();
                _snack('Added ${books.length} books to "$name"');
                if (sheetContext.mounted) Navigator.pop(sheetContext);
              },
            ),
            const SizedBox(height: 20),
            Row(
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
                    onPressed: () async {
                      final name = controller.text.trim();
                      if (name.isEmpty || !sheetContext.mounted) return;
                      Navigator.pop(sheetContext);
                      final id = await widget.library.createCollection(name);
                      if (id.isNotEmpty) {
                        await widget.library.addBooksToCollection(id, [
                          for (final b in books) b.id,
                        ]);
                      }
                      if (!mounted) return;
                      _selection.clear();
                      _snack('Added ${books.length} books to "$name"');
                    },
                    child: const Text('Create & add'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ).whenComplete(() => controller.dispose());
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final books = _books;

    return PopScope(
      // Back clears the selection first instead of leaving the screen.
      canPop: !_selection.isSelecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selection.isSelecting) _selection.clear();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.author),
          actions: [
            PillChip(
              label: _sortLabel(_sort),
              icon: Icons.sort_rounded,
              onTap: () => setState(() {
                _sort = _SortMode
                    .values[(_sort.index + 1) % _SortMode.values.length];
              }),
            ),
            const SizedBox(width: 8),
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
        ),
        body: books.isEmpty
            ? Center(
                child: Text(
                  'No books by ${widget.author}',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              )
            : Column(
                children: [
                  if (_selection.isSelecting) _selectionBar(),
                  Expanded(
                    child: _layout == _LayoutMode.grid
                        ? _bookGrid(context, books)
                        : _bookList(books),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _bookGrid(BuildContext context, List<Book> books) {
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

  Widget _bookList(List<Book> books) {
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

  void _showBookActions(Book book) {
    final scheme = Theme.of(context).colorScheme;
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        minimum: const EdgeInsets.only(bottom: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 24),
              leading: SizedBox(
                width: 46,
                height: 69,
                child: BookCover(book: book, borderRadius: 10, spine: false),
              ),
              title: Text(
                book.displayTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(height: 4),
            ListTile(
              leading: Icon(
                Icons.menu_book_outlined,
                color: scheme.onSecondaryContainer,
              ),
              title: const Text('Read now'),
              onTap: () {
                Navigator.pop(sheetContext);
                _openBook(book);
              },
            ),
          ],
        ),
      ),
    );
  }
}
