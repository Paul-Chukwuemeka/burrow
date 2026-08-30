import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/book.dart';
import '../services/library_service.dart';
import '../theme/burrow_tokens.dart';
import '../widgets/book_cover.dart';
import 'book_info_screen.dart';
import 'reader_screen.dart';

enum _SortMode { title, recent, added }

class GenreScreen extends StatefulWidget {
  const GenreScreen({
    super.key,
    required this.genre,
    required this.library,
  });

  final String genre;
  final LibraryService library;

  @override
  State<GenreScreen> createState() => _GenreScreenState();
}

class _GenreScreenState extends State<GenreScreen> {
  _SortMode _sort = _SortMode.title;

  String _sortLabel(_SortMode m) => switch (m) {
        _SortMode.title => 'A\u2013Z',
        _SortMode.recent => 'Recent',
        _SortMode.added => 'Added',
      };

  List<Book> get _books {
    var list = widget.library.booksByGenre(widget.genre);
    switch (_sort) {
      case _SortMode.title:
        list.sort((a, b) => a.displayTitle
            .toLowerCase()
            .compareTo(b.displayTitle.toLowerCase()));
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('"${book.displayTitle}" is no longer on this device')),
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final books = _books;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.genre),
        actions: [
          _PillChip(
            label: _sortLabel(_sort),
            icon: Icons.sort_rounded,
            onTap: () => setState(() {
              _sort = _SortMode.values[(_sort.index + 1) % _SortMode.values.length];
            }),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: books.isEmpty
          ? Center(
              child: Text(
                'No books in this genre',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            )
          : _bookGrid(context, books),
    );
  }

  Widget _bookGrid(BuildContext context, List<Book> books) {
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
          itemCount: books.length,
          itemBuilder: (context, i) {
            final book = books[i];
            return _PressableScale(
              child: _GenreBookTile(
                book: book,
                onTap: () => _openBookInfo(book),
                onLongPress: () => _showBookActions(book),
              ),
            );
          },
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
              leading: Icon(Icons.menu_book_outlined, color: scheme.onSecondaryContainer),
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

class _PressableScale extends StatefulWidget {
  const _PressableScale({required this.child});
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

class _GenreBookTile extends StatelessWidget {
  const _GenreBookTile({
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
