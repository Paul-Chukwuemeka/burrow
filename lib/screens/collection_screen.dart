import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../db/database.dart' as db;
import '../models/book.dart';
import '../services/library_service.dart';
import '../theme/burrow_tokens.dart';
import '../utils/book_title.dart';
import '../widgets/book_cover.dart';
import 'book_info_screen.dart';

enum _SortMode { manual, title, recent }

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
  List<Book> _books = [];
  bool _reorderMode = false;

  @override
  void initState() {
    super.initState();
    _sort = _SortMode.values[widget.collection.sortType.clamp(0, 2)];
    _loadBooks();
  }

  Future<void> _loadBooks() async {
    final books = await widget.library.getBooksForCollection(widget.collection.id);
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
        _books.sort((a, b) => a.displayTitle
            .toLowerCase()
            .compareTo(b.displayTitle.toLowerCase()));
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
                            widget.collection.id, book.id);
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

    return Scaffold(
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
              icon: Icon(_reorderMode ? Icons.done_rounded : Icons.reorder_rounded),
              tooltip: _reorderMode ? 'Done' : 'Reorder',
              onPressed: () => setState(() => _reorderMode = !_reorderMode),
            ),
          _PillChip(
            label: _sortLabel(_sort),
            icon: Icons.sort_rounded,
            onTap: () => setState(() {
              _sort = _SortMode.values[(_sort.index + 1) % _SortMode.values.length];
              if (_sort != _SortMode.manual) _reorderMode = false;
            }),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _books.isEmpty
          ? Center(
              child: Text(
                'No books in this collection',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            )
          : _reorderMode
              ? _reorderableList(context)
              : _bookGrid(context),
    );
  }

  Widget _bookGrid(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const maxTileExtent = 200.0;
        const crossSpacing = 12.0;
        const mainSpacing = 14.0;
        const cardPadding = 6.0;
        const textBlock = 58.0;

        final width = constraints.maxWidth;
        final columns = math.max(1, (width / maxTileExtent).ceil());
        final tileWidth = (width - crossSpacing * (columns - 1)) / columns;
        final coverWidth = tileWidth - cardPadding * 2;
        final mainAxisExtent =
            cardPadding + coverWidth / Burrow.coverAspectRatio + textBlock;

        return GridView.builder(
          padding: const EdgeInsets.all(20),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: crossSpacing,
            mainAxisSpacing: mainSpacing,
            mainAxisExtent: mainAxisExtent,
          ),
          itemCount: _books.length,
          itemBuilder: (context, i) {
            final book = _books[i];
            return _PressableScale(
              child: _CollectionBookTile(
                book: book,
                onTap: () => _openBookInfo(book),
                onLongPress: () => _showRemoveBook(book),
              ),
            );
          },
        );
      },
    );
  }

  Widget _reorderableList(BuildContext context) {
    return ReorderableListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      itemCount: _books.length,
      onReorder: _onReorder,
      itemBuilder: (context, i) {
        final book = _books[i];
        return _PressableScale(
          key: ValueKey(book.id),
          child: Card(
            margin: const EdgeInsets.symmetric(vertical: 4),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
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

class _PressableScale extends StatefulWidget {
  const _PressableScale({super.key, required this.child});
  final Widget child;

  @override
  State<_PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<_PressableScale> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => setState(() => _down = true),
      onPointerUp: (_) => setState(() => _down = false),
      onPointerCancel: (_) => setState(() => _down = false),
      child: AnimatedScale(
        scale: _down ? 0.96 : 1,
        duration: Duration(milliseconds: _down ? 90 : 220),
        curve: _down ? Curves.easeOut : Curves.easeOutBack,
        child: widget.child,
      ),
    );
  }
}

class _CollectionBookTile extends StatelessWidget {
  const _CollectionBookTile({
    required this.book,
    required this.onTap,
    required this.onLongPress,
  });

  final Book book;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: BookCover(book: book, borderRadius: Burrow.shapeMd - 2),
        ),
        const SizedBox(height: 7),
        Text(
          book.displayTitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: scheme.onSurface,
            height: 1.15,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          book.progressLabel,
          style: TextStyle(
            fontSize: 11,
            color: book.isStarted ? scheme.primary : scheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _PillChip extends StatelessWidget {
  const _PillChip({
    required this.label,
    required this.onTap,
    this.icon,
  });

  final String label;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      child: Material(
        color: Colors.transparent,
        shape: StadiumBorder(
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 18, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 6),
                ],
                Text(
                  label,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    letterSpacing: 0.15,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
