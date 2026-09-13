import 'dart:io';

import 'package:flutter/material.dart';

import '../models/book.dart';
import '../services/library_service.dart';
import '../utils/book_title.dart';
import '../widgets/book_card.dart';
import '../widgets/book_cover.dart';
import '../widgets/book_grid.dart';
import '../widgets/pill_chip.dart';
import 'book_info_screen.dart';
import 'reader_screen.dart';

enum _SortMode { title, recent, added }

enum _LayoutMode { grid, list }

class SmartGroupScreen extends StatefulWidget {
  const SmartGroupScreen({
    super.key,
    required this.title,
    required this.books,
    required this.library,
  });

  final String title;
  final List<Book> books;
  final LibraryService library;

  @override
  State<SmartGroupScreen> createState() => _SmartGroupScreenState();
}

class _SmartGroupScreenState extends State<SmartGroupScreen> {
  _SortMode _sort = _SortMode.title;
  late _LayoutMode _layout;

  @override
  void initState() {
    super.initState();
    _layout = widget.library.libraryLayout == 'list'
        ? _LayoutMode.list
        : _LayoutMode.grid;
  }

  String _sortLabel(_SortMode m) => switch (m) {
    _SortMode.title => 'A–Z',
    _SortMode.recent => 'Recent',
    _SortMode.added => 'Added',
  };

  List<Book> get _sortedBooks {
    final list = [...widget.books];
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('"${book.displayTitle}" is no longer on this device'),
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final books = _sortedBooks;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          PillChip(
            label: _sortLabel(_sort),
            icon: Icons.sort_rounded,
            onTap: () => setState(() {
              _sort =
                  _SortMode.values[(_sort.index + 1) % _SortMode.values.length];
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
                'No books in this group',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            )
          : _layout == _LayoutMode.grid
          ? _bookGrid(context, books)
          : _bookList(books),
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
              onTap: () => _openBookInfo(book),
              onLongPress: () => _showBookActions(book),
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
          onTap: () => _openBookInfo(book),
          onLongPress: () => _showBookActions(book),
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
