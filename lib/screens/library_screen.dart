import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../db/database.dart' as db;
import '../models/book.dart';
import '../services/import_helper.dart';
import '../services/library_service.dart';
import '../services/scan_service.dart';
import '../theme/burrow_tokens.dart';
import '../utils/book_title.dart';
import '../widgets/book_cover.dart';
import '../widgets/progress_bar.dart';
import 'author_screen.dart';
import 'book_info_screen.dart';
import 'collection_screen.dart';
import 'reader_screen.dart';
import 'settings_screen.dart';
import 'smart_group_screen.dart';
import 'stats_screen.dart';

enum _SortMode { recent, added, title }

enum _LayoutMode { grid, list }

enum _LibraryTab { books, authors, collections }

enum _ReadingStatus { all, reading, finished, new_ }

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, required this.library});

  final LibraryService library;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  bool _busy = false;
  bool _fabOpen = false;

  String _query = '';
  BookFormat? _filter;
  _SortMode _sort = _SortMode.recent;
  late _LayoutMode _layout;
  _LibraryTab _tab = _LibraryTab.books;
  _ReadingStatus _statusFilter = _ReadingStatus.all;
  String? _genreFilter;
  String? _seriesFilter;

  final _searchController = TextEditingController();

  static const _allowedExtensions = ['epub', 'txt', 'pdf'];

  @override
  void initState() {
    super.initState();
    final saved = widget.library.libraryLayout;
    _layout = saved == 'list' ? _LayoutMode.list : _LayoutMode.grid;
  }

  String get _sortLabel => switch (_sort) {
        _SortMode.recent => 'Recent',
        _SortMode.added => 'Added',
        _SortMode.title => 'A–Z',
      };

  int get _activeFilterCount {
    var count = 0;
    if (_statusFilter != _ReadingStatus.all) count++;
    if (_genreFilter != null) count++;
    if (_seriesFilter != null) count++;
    return count;
  }

  Future<void> _showFilterSheet(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _FilterSheet(
        statusFilter: _statusFilter,
        genreFilter: _genreFilter,
        seriesFilter: _seriesFilter,
        books: widget.library.books,
        onStatusChanged: (s) => setState(() => _statusFilter = s),
        onGenreChanged: (g) => setState(() => _genreFilter = g),
        onSeriesChanged: (s) => setState(() => _seriesFilter = s),
        onClearAll: () => setState(() {
          _statusFilter = _ReadingStatus.all;
          _genreFilter = null;
          _seriesFilter = null;
        }),
      ),
    );
  }

  /// Books after applying search, format filter and local sorting.
  List<Book> get _visibleBooks {
    var books = widget.library.sorted;
    final filter = _filter;
    if (filter != null) {
      books = books.where((b) => b.format == filter).toList();
    }
    // Reading status filter.
    switch (_statusFilter) {
      case _ReadingStatus.all:
        break;
      case _ReadingStatus.reading:
        books = books.where((b) => b.isStarted && !b.isFinished).toList();
      case _ReadingStatus.finished:
        books = books.where((b) => b.isFinished).toList();
      case _ReadingStatus.new_:
        books = books.where((b) => !b.isStarted).toList();
    }
    // Genre filter.
    if (_genreFilter != null) {
      final g = _genreFilter!;
      books = books
          .where((b) =>
              b.genre != null &&
              b.genre!
                  .split(',')
                  .map((s) => s.trim())
                  .any((s) => s.toLowerCase() == g.toLowerCase()))
          .toList();
    }
    // Series filter.
    if (_seriesFilter != null) {
      final s = _seriesFilter!;
      books = books
          .where((b) =>
              b.seriesName != null &&
              b.seriesName!.toLowerCase() == s.toLowerCase())
          .toList();
    }
    final q = _query.trim().toLowerCase();
    if (q.isNotEmpty) {
      books = books
          .where((b) =>
              b.displayTitle.toLowerCase().contains(q) ||
              b.author.toLowerCase().contains(q))
          .toList();
    }
    switch (_sort) {
      case _SortMode.recent:
        break; // Already ordered by the service.
      case _SortMode.added:
        books.sort((a, b) => b.addedAt.compareTo(a.addedAt));
      case _SortMode.title:
        books.sort((a, b) => a.displayTitle
            .toLowerCase()
            .compareTo(b.displayTitle.toLowerCase()));
    }
    return books;
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openBook(Book book, {String? heroTag}) async {
    if (!await File(book.path).exists()) {
      _snack('"${book.displayTitle}" is no longer on this device');
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ReaderScreen(
          book: book,
          library: widget.library,
          heroTag: heroTag,
        ),
      ),
    );
    if (mounted) setState(() {}); // Refresh progress labels after returning.
  }

  Future<void> _openBookInfo(Book book, {String? heroTag}) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BookInfoScreen(
          book: book,
          library: widget.library,
          heroTag: heroTag,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _pickFile() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: _allowedExtensions,
    );
    if (files.isEmpty) return;
    final paths = files.map((f) => f.path).whereType<String>().toList();
    await _importPaths(paths, openFirst: paths.length == 1);
  }

  Future<void> _pickFolderAndScan() async {
    final dir = await FilePicker.getDirectoryPath();
    if (dir == null) return;
    await _runScan(ScanService.scanFolder(dir, knownPaths: _knownPaths()));
  }

  Future<void> _scanDevice() async {
    final granted = await ScanService.ensurePermission();
    if (!granted) {
      _snack('Storage permission is required to scan the device');
      return;
    }
    await _runScan(ScanService.scanDevice(knownPaths: _knownPaths()));
  }

  Set<String> _knownPaths() => widget.library.books.map((b) => b.path).toSet();

  /// Exports the library and opens the system share sheet with the file.
  Future<void> _exportLibrary() async {
    try {
      final path = await widget.library.exportLibrary();
      if (!mounted) return;
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(path)],
          subject: 'Burrow library backup',
          text: 'Burrow library backup',
        ),
      );
    } catch (_) {
      _snack('Export failed');
    }
  }

  /// Picks a previously exported backup file and restores it.
  Future<void> _importLibrary() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    final path = files.isEmpty ? null : files.first.path;
    if (path == null) return;
    try {
      final count = await widget.library.importLibrary(path);
      if (!mounted) return;
      _snack(count > 0
          ? 'Restored $count book${count == 1 ? '' : 's'} from backup'
          : 'Backup matches the current library');
    } on FormatException catch (e) {
      _snack(e.message);
    } catch (_) {
      _snack('Could not read backup file');
    }
  }

  Future<void> _runScan(Future<List<String>> scan) async {
    setState(() {
      _busy = true;
      _fabOpen = false;
    });
    try {
      final (paths, added, failed) =
          await BookImporter.runScan(widget.library, scan);
      if (!mounted) return;
      _snack(
        paths.isEmpty
            ? 'No new books found'
            : 'Added ${added.length} book${added.length == 1 ? '' : 's'}'
                '${failed > 0 ? ', $failed unreadable' : ''}',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importPaths(List<String> paths, {bool openFirst = true}) async {
    final (added, failed) = await BookImporter.importPaths(
      widget.library,
      paths,
      onFormatError: (e) => _snack(e.message),
      onError: (_) => _snack('Could not open file'),
    );
    if (!mounted) return;
    if (openFirst && added.isNotEmpty) await _openBook(added.first);
    if (paths.length > 1) {
      _snack('Added ${added.length} book${added.length == 1 ? '' : 's'}');
    }
  }

  void _runFromFab(Future<void> Function() action) {
    setState(() => _fabOpen = false);
    action();
  }

  void _showBookActions(Book book) {
    final scheme = Theme.of(context).colorScheme;
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        minimum: const EdgeInsets.only(bottom: 20),
        child: SingleChildScrollView(
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
              subtitle: book.author.isEmpty
                  ? null
                  : Text(book.author,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(height: 4),
            _SheetAction(
              icon: Icons.menu_book_outlined,
              label: 'Read now',
              iconColor: scheme.onSecondaryContainer,
              iconBg: scheme.secondaryContainer,
              onTap: () {
                Navigator.pop(sheetContext);
                _openBook(book);
              },
            ),
            _SheetAction(
              icon: Icons.edit_outlined,
              label: 'Edit metadata',
              iconColor: scheme.onTertiaryContainer,
              iconBg: scheme.tertiaryContainer,
              onTap: () {
                Navigator.pop(sheetContext);
                _showEditMetadataSheet(book);
              },
            ),
            _SheetAction(
              icon: Icons.info_outline_rounded,
              label: 'Book details',
              iconColor: scheme.onSurfaceVariant,
              iconBg: scheme.surfaceContainerHighest,
              onTap: () {
                Navigator.pop(sheetContext);
                _showBookDetailsSheet(book);
              },
            ),
            _SheetAction(
              icon: Icons.collections_bookmark_outlined,
              label: 'Add to collection',
              iconColor: scheme.onPrimaryContainer,
              iconBg: scheme.primaryContainer,
              onTap: () {
                Navigator.pop(sheetContext);
                _showAddToCollectionSheet(book);
              },
            ),
            _SheetAction(
              icon: Icons.delete_outline_rounded,
              label: 'Remove from library',
              iconColor: scheme.onErrorContainer,
              iconBg: scheme.errorContainer,
              labelColor: scheme.error,
              onTap: () {
                Navigator.pop(sheetContext);
                _showRemoveBookSheet(book);
              },
            ),
          ],
          ),
        ),
      ),
    );
  }

  void _showEditMetadataSheet(Book book) {
    final titleController = TextEditingController(text: book.title);
    final authorController = TextEditingController(text: book.author);
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
              'Edit metadata',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: titleController,
              decoration: const InputDecoration(
                labelText: 'Title',
                border: OutlineInputBorder(),
              ),
              textCapitalization: TextCapitalization.sentences,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: authorController,
              decoration: const InputDecoration(
                labelText: 'Author',
                border: OutlineInputBorder(),
              ),
              textCapitalization: TextCapitalization.words,
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
                    onPressed: () {
                      final newTitle = titleController.text.trim();
                      final newAuthor = authorController.text.trim();
                      if (newTitle.isNotEmpty) {
                        widget.library.updateBook(
                          book.id,
                          title: newTitle,
                          author: newAuthor,
                        );
                      }
                      Navigator.pop(sheetContext);
                    },
                    child: const Text('Save'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showBookDetailsSheet(Book book) {
    final file = File(book.path);
    final fileSize = file.existsSync()
        ? _formatFileSize(file.lengthSync())
        : 'Unknown';
    final addedDate = DateTime.fromMillisecondsSinceEpoch(book.addedAt);
    final lastReadDate = book.lastReadAt > 0
        ? DateTime.fromMillisecondsSinceEpoch(book.lastReadAt)
        : null;

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
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: book.author.isEmpty
                  ? null
                  : Text(book.author,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            const Divider(indent: 16, endIndent: 16),
            _DetailRow(label: 'Format', value: book.format.name.toUpperCase()),
            _DetailRow(label: 'File size', value: fileSize),
            _DetailRow(
              label: 'Added',
              value:
                  '${addedDate.day}/${addedDate.month}/${addedDate.year}',
            ),
            if (lastReadDate != null)
              _DetailRow(
                label: 'Last read',
                value:
                    '${lastReadDate.day}/${lastReadDate.month}/${lastReadDate.year}',
              ),
            _DetailRow(
              label: 'Progress',
              value: book.progressLabel,
            ),
            _DetailRow(label: 'Path', value: book.path, isFile: true),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _showRemoveBookSheet(Book book) {
    bool deleteFile = false;
    final scheme = Theme.of(context).colorScheme;
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
                  'Remove "${book.displayTitle}"?',
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
                title: const Text('Also delete file from disk'),
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
                        onPressed: () {
                          Navigator.pop(sheetContext);
                          widget.library.deleteBookWithFile(
                            book.id,
                            deleteFile: deleteFile,
                          );
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

  void _showAddToCollectionSheet(Book book) {
    final collections = widget.library.collections;
    final scheme = Theme.of(context).colorScheme;
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
                  'Add "${book.displayTitle}" to…',
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
                ...collections.map((c) => _CollectionPickerTile(
                      collection: c,
                      isInCollection: widget.library.isBookInCollection(c.id, book.id),
                      onToggle: () async {
                        final isIn = await widget.library.isBookInCollection(c.id, book.id);
                        if (isIn) {
                          await widget.library.removeBookFromCollection(c.id, book.id);
                        } else {
                          await widget.library.addBookToCollection(c.id, book.id);
                        }
                        setSheetState(() {});
                      },
                    )),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.pop(sheetContext);
                      _showCreateCollectionAndAddSheet(book);
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
      ),
    );
  }

  void _showCreateCollectionAndAddSheet(Book book) {
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
                if (name.isNotEmpty) {
                  await widget.library.createCollection(name);
                  final collections = widget.library.collections;
                  if (collections.isNotEmpty) {
                    await widget.library.addBookToCollection(
                        collections.last.id, book.id);
                  }
                  Navigator.pop(sheetContext);
                }
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
                      if (name.isNotEmpty) {
                        await widget.library.createCollection(name);
                        final collections = widget.library.collections;
                        if (collections.isNotEmpty) {
                          await widget.library.addBookToCollection(
                              collections.last.id, book.id);
                        }
                        Navigator.pop(sheetContext);
                      }
                    },
                    child: const Text('Create & add'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final allBooks = widget.library.books;
    final books = _visibleBooks;
    final recent =
        (_query.isEmpty && _filter == null && _statusFilter == _ReadingStatus.all && _genreFilter == null && _seriesFilter == null)
            ? widget.library.mostRecent
            : null;
    final hasLibrary = allBooks.isNotEmpty;
    final filtered = books.length != allBooks.length || _query.isNotEmpty || _statusFilter != _ReadingStatus.all || _genreFilter != null || _seriesFilter != null;

    return DefaultTabController(
      length: 3,
      initialIndex: _tab.index,
      child: Scaffold(
        body: Stack(
          children: [
            CustomScrollView(
              slivers: [
                _BurrowHeader(
                  tab: _tab,
                  onTabChanged: (tab) => setState(() {
                    _tab = tab;
                    _query = '';
                    _searchController.clear();
                  }),
                  onStats: () => StatsScreen.show(
                    context,
                    library: widget.library,
                  ),
                  onExport: _exportLibrary,
                  onImportBackup: _importLibrary,
                  onSettings: () => SettingsScreen.show(
                    context,
                    library: widget.library,
                  ),
                ),
                if (hasLibrary && _busy)
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 20),
                      child: LinearProgressIndicator(minHeight: 4),
                    ),
                  ),
                if (hasLibrary) ..._tabContent(context, books, recent, filtered),
                if (!hasLibrary)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: _busy
                        ? const _BusyState()
                        : _EmptyState(
                            onPickFile: _pickFile,
                            onScan: _scanDevice,
                          ),
                  ),
              ],
            ),
            // Scrim behind the FAB menu.
            Positioned.fill(
              child: IgnorePointer(
                ignoring: !_fabOpen,
                child: AnimatedOpacity(
                  opacity: _fabOpen ? 1 : 0,
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOut,
                  child: DecoratedBox(
                    decoration:
                        BoxDecoration(color: scheme.scrim.withValues(alpha: 0.45)),
                    child:
                        GestureDetector(onTap: () => setState(() => _fabOpen = false)),
                  ),
                ),
              ),
            ),
          ],
        ),
        floatingActionButton: _tab == _LibraryTab.books ? _buildFab(context) : null,
      ),
    );
  }

  List<Widget> _tabContent(
    BuildContext context,
    List<Book> books,
    Book? recent,
    bool filtered,
  ) {
    return switch (_tab) {
      _LibraryTab.books => _libraryContent(context, books, recent, filtered),
      _LibraryTab.authors => _authorsContent(context),
      _LibraryTab.collections => _collectionsContent(context),
    };
  }

  List<Widget> _libraryContent(
    BuildContext context,
    List<Book> books,
    Book? recent,
    bool filtered,
  ) {
    return [
      SliverToBoxAdapter(
        child: _SearchField(
          controller: _searchController,
          onChanged: (v) => setState(() => _query = v),
        ),
      ),
      SliverToBoxAdapter(
        child: _FilterRow(
          filter: _filter,
          onFilter: (f) => setState(() => _filter = f),
          activeFilterCount: _activeFilterCount,
          onFilterTap: () => _showFilterSheet(context),
        ),
      ),
      if (recent != null)
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
          sliver: SliverToBoxAdapter(
            child: _ContinueCard(
              book: recent,
              onTap: () => _openBookInfo(recent, heroTag: 'hero-${recent.id}'),
            ),
          ),
        ),
      if (books.isEmpty)
        const SliverFillRemaining(
          hasScrollBody: false,
          child: _NoResults(),
        )
      else ...[
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
          sliver: SliverToBoxAdapter(
            child: Row(
              children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      filtered ? '${books.length} found' : 'All books · ${books.length}',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.2,
                          ),
                    ),
                  ),
                ),
                _PillChip(
                  label: _sortLabel,
                  icon: Icons.sort_rounded,
                  onTap: () => setState(() {
                    _sort =
                        _SortMode.values[(_sort.index + 1) % _SortMode.values.length];
                  }),
                ),
                const SizedBox(width: 8),
                _PillChip(
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
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          sliver: _layout == _LayoutMode.grid
              ? SliverLayoutBuilder(
                  builder: (context, constraints) =>
                      _bookGrid(constraints.crossAxisExtent, books),
                )
              : _bookList(books),
        ),
      ],
      // Reserve the FAB zone so the docked button never covers the last row.
      const SliverPadding(padding: EdgeInsets.only(bottom: Burrow.fabClearance)),
    ];
  }

  List<Widget> _authorsContent(BuildContext context) {
    final authors = widget.library.uniqueAuthors;
    if (authors.isEmpty) {
      return [
        const SliverFillRemaining(
          hasScrollBody: false,
          child: _EmptyTabState(
            icon: Icons.person_outline_rounded,
            message: 'No authors yet',
            detail: 'Books with author metadata will appear here',
          ),
        ),
      ];
    }
    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
        sliver: SliverToBoxAdapter(
          child: Text(
            'Authors · ${authors.length}',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                ),
          ),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        sliver: SliverList.builder(
          itemCount: authors.length,
          itemBuilder: (context, i) {
            final author = authors[i];
            final count = widget.library.authorBookCount(author);
            return _AuthorTile(
              name: author,
              bookCount: count,
              onTap: () => _openAuthorScreen(author),
            );
          },
        ),
      ),
      const SliverPadding(padding: EdgeInsets.only(bottom: Burrow.fabClearance)),
    ];
  }

  List<Widget> _collectionsContent(BuildContext context) {
    final collections = widget.library.collections;
    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
        sliver: SliverToBoxAdapter(
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Collections',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                      ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add_rounded),
                onPressed: _showCreateCollectionSheet,
                tooltip: 'Create collection',
              ),
            ],
          ),
        ),
      ),
      // Smart groups
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        sliver: SliverList(
          delegate: SliverChildListDelegate([
            _SmartGroupTile(
              icon: Icons.auto_stories_outlined,
              label: 'Reading',
              count: widget.library.books.where((b) => b.isStarted && !b.isFinished).length,
              onTap: () => _openSmartGroup('Reading'),
            ),
            _SmartGroupTile(
              icon: Icons.check_circle_outline_rounded,
              label: 'Finished',
              count: widget.library.books.where((b) => b.isFinished).length,
              onTap: () => _openSmartGroup('Finished'),
            ),
            _SmartGroupTile(
              icon: Icons.fiber_new_outlined,
              label: 'New',
              count: widget.library.books.where((b) => !b.isStarted).length,
              onTap: () => _openSmartGroup('New'),
            ),
          ]),
        ),
      ),
      // User collections
      if (collections.isEmpty)
        const SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: 20),
          sliver: SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: _EmptyTabState(
                icon: Icons.collections_bookmark_outlined,
                message: 'No collections yet',
                detail: 'Tap + to create one and organize your books',
              ),
            ),
          ),
        )
      else
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          sliver: SliverList.builder(
            itemCount: collections.length,
            itemBuilder: (context, i) {
              final c = collections[i];
              return _CollectionTile(
                collection: c,
                library: widget.library,
                onTap: () => _openCollectionScreen(c),
                onLongPress: () => _showCollectionActions(c),
              );
            },
          ),
        ),
      const SliverPadding(padding: EdgeInsets.only(bottom: Burrow.fabClearance)),
    ];
  }

  Future<void> _openAuthorScreen(String author) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AuthorScreen(
          author: author,
          library: widget.library,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _openCollectionScreen(db.Collection collection) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CollectionScreen(
          collection: collection,
          library: widget.library,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _openSmartGroup(String group) async {
    // Build a synthetic list of books for the smart group.
    List<Book> books;
    switch (group) {
      case 'Reading':
        books = widget.library.books.where((b) => b.isStarted && !b.isFinished).toList();
      case 'Finished':
        books = widget.library.books.where((b) => b.isFinished).toList();
      case 'New':
        books = widget.library.books.where((b) => !b.isStarted).toList();
      default:
        books = [];
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SmartGroupScreen(
          title: group,
          books: books,
          library: widget.library,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  void _showCreateCollectionSheet() {
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
              onSubmitted: (_) {
                final name = controller.text.trim();
                if (name.isNotEmpty) {
                  widget.library.createCollection(name);
                  Navigator.pop(sheetContext);
                }
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
                    onPressed: () {
                      final name = controller.text.trim();
                      if (name.isNotEmpty) {
                        widget.library.createCollection(name);
                        Navigator.pop(sheetContext);
                      }
                    },
                    child: const Text('Create'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showCollectionActions(db.Collection collection) {
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
                collection.name,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
              ),
            ),
            _SheetAction(
              icon: Icons.edit_outlined,
              label: 'Rename',
              iconColor: scheme.onTertiaryContainer,
              iconBg: scheme.tertiaryContainer,
              onTap: () {
                Navigator.pop(sheetContext);
                _showRenameCollectionSheet(collection);
              },
            ),
            _SheetAction(
              icon: Icons.delete_outline_rounded,
              label: 'Delete collection',
              iconColor: scheme.onErrorContainer,
              iconBg: scheme.errorContainer,
              labelColor: scheme.error,
              onTap: () {
                Navigator.pop(sheetContext);
                widget.library.deleteCollection(collection.id);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showRenameCollectionSheet(db.Collection collection) {
    final controller = TextEditingController(text: collection.name);
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
              'Rename collection',
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
              onSubmitted: (_) {
                final name = controller.text.trim();
                if (name.isNotEmpty) {
                  widget.library.renameCollection(collection.id, name);
                  Navigator.pop(sheetContext);
                }
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
                    onPressed: () {
                      final name = controller.text.trim();
                      if (name.isNotEmpty) {
                        widget.library.renameCollection(collection.id, name);
                        Navigator.pop(sheetContext);
                      }
                    },
                    child: const Text('Save'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Grid whose tiles are sized so every cover is exactly
  /// [Burrow.coverAspectRatio] (2:3): column count adapts to screen width,
  /// then the fixed main-axis extent derives from the resulting tile width.
  Widget _bookGrid(double width, List<Book> books) {
    const maxTileExtent = 200.0;
    const crossSpacing = 12.0;
    const mainSpacing = 14.0;
    const cardPadding = 6.0;
    // Fixed-height text block under the cover: gap 7 + two title lines 30 +
    // gap 2 + status line 13 + bottom padding 6.
    const textBlock = 58.0;

    final columns = math.max(1, (width / maxTileExtent).ceil());
    final tileWidth = (width - crossSpacing * (columns - 1)) / columns;
    final coverWidth = tileWidth - cardPadding * 2;
    final mainAxisExtent =
        cardPadding + coverWidth / Burrow.coverAspectRatio + textBlock;

    return SliverGrid.builder(
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        crossAxisSpacing: crossSpacing,
        mainAxisSpacing: mainSpacing,
        mainAxisExtent: mainAxisExtent,
      ),
      itemCount: books.length,
      itemBuilder: (context, i) {
        final book = books[i];
        return _Reveal(
          key: ValueKey(book.id),
          delay: Duration(milliseconds: 40 * (i.clamp(0, 11))),
          child: _BookTile(
            book: book,
            onTap: () => _openBookInfo(book, heroTag: 'tile-${book.id}'),
            onLongPress: () => _showBookActions(book),
          ),
        );
      },
    );
  }

  Widget _bookList(List<Book> books) {
    return SliverList.builder(
      itemCount: books.length,
      itemBuilder: (context, i) {
        final book = books[i];
        return _Reveal(
          key: ValueKey(book.id),
          delay: Duration(milliseconds: 30 * (i.clamp(0, 11))),
          child: _BookListTile(
            book: book,
            onTap: () => _openBookInfo(book, heroTag: 'tile-${book.id}'),
            onLongPress: () => _showBookActions(book),
          ),
        );
      },
    );
  }

  Widget _buildFab(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (_fabOpen) ...[
          _FabMenuItem(
            icon: Icons.upload_file_outlined,
            label: 'Import file',
            scheme: scheme,
            delay: 0.0,
            onTap: () => _runFromFab(_pickFile),
          ),
          const SizedBox(height: 12),
          _FabMenuItem(
            icon: Icons.folder_open_outlined,
            label: 'Scan folder…',
            scheme: scheme,
            delay: 0.12,
            onTap: () => _runFromFab(_pickFolderAndScan),
          ),
          const SizedBox(height: 12),
          _FabMenuItem(
            icon: Icons.travel_explore_outlined,
            label: 'Scan device',
            scheme: scheme,
            delay: 0.24,
            onTap: () => _runFromFab(_scanDevice),
          ),
          const SizedBox(height: 18),
        ],
        FloatingActionButton(
          onPressed: _busy ? null : () => setState(() => _fabOpen = !_fabOpen),
          tooltip: 'Add book',
          backgroundColor: _fabOpen ? scheme.secondaryContainer : null,
          foregroundColor: _fabOpen ? scheme.onSecondaryContainer : null,
          shape: RoundedRectangleBorder(
            borderRadius: Burrow.r(Burrow.shapeLg),
          ),
          child: AnimatedRotation(
            turns: _fabOpen ? 0.125 : 0,
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutBack,
            child: const Icon(Icons.add, size: 28),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------

/// Compact large-title app bar: plain lowercase wordmark, no icon, with a
/// shorter expanded height than [SliverAppBar.large] so more shelf shows.
class _BurrowHeader extends StatelessWidget {
  const _BurrowHeader({
    required this.tab,
    required this.onTabChanged,
    this.onStats,
    this.onExport,
    this.onImportBackup,
    this.onSettings,
  });

  final _LibraryTab tab;
  final ValueChanged<_LibraryTab> onTabChanged;
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
        onTap: (i) => onTabChanged(_LibraryTab.values[i]),
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

// ---------------------------------------------------------------------------
// Pieces
// ---------------------------------------------------------------------------

/// Springy press feedback shared by tappable cards and tiles.
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

/// Staggered entrance: fades, slides and scales its child in once.
class _Reveal extends StatefulWidget {
  const _Reveal({super.key, required this.delay, required this.child});

  final Duration delay;
  final Widget child;

  @override
  State<_Reveal> createState() => _RevealState();
}

class _RevealState extends State<_Reveal> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 480),
  );

  @override
  void initState() {
    super.initState();
    Future.delayed(widget.delay, () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final animation = CurvedAnimation(
      parent: _controller,
      curve: Easing.emphasizedDecelerate,
    );
    return FadeTransition(
      opacity: animation,
      child: SlideTransition(
        position: Tween(begin: const Offset(0, 0.08), end: Offset.zero)
            .animate(animation),
        child: ScaleTransition(
          scale: Tween(begin: 0.94, end: 1.0).animate(animation),
          child: widget.child,
        ),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onChanged});

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

class _FilterRow extends StatelessWidget {
  const _FilterRow({
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
      return _PillChip(
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
          _FilterIconButton(
            activeCount: activeFilterCount,
            onTap: onFilterTap,
          ),
        ],
      ),
    );
  }
}

class _FilterIconButton extends StatelessWidget {
  const _FilterIconButton({
    required this.activeCount,
    required this.onTap,
  });

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
               color: activeCount > 0 ? scheme.primary : scheme.outlineVariant.withValues(alpha: 0.5),
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

class _FilterSheet extends StatefulWidget {
  const _FilterSheet({
    required this.statusFilter,
    required this.genreFilter,
    required this.seriesFilter,
    required this.books,
    required this.onStatusChanged,
    required this.onGenreChanged,
    required this.onSeriesChanged,
    required this.onClearAll,
  });

  final _ReadingStatus statusFilter;
  final String? genreFilter;
  final String? seriesFilter;
  final List<Book> books;
  final ValueChanged<_ReadingStatus> onStatusChanged;
  final ValueChanged<String?> onGenreChanged;
  final ValueChanged<String?> onSeriesChanged;
  final VoidCallback onClearAll;

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late _ReadingStatus _status;
  late String? _genre;
  late String? _series;

  @override
  void initState() {
    super.initState();
    _status = widget.statusFilter;
    _genre = widget.genreFilter;
    _series = widget.seriesFilter;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);

    // Collect unique genres.
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

    // Collect unique series.
    final seriesSet = <String>{};
    for (final b in widget.books) {
      if (b.seriesName != null && b.seriesName!.isNotEmpty) {
        seriesSet.add(b.seriesName!);
      }
    }
    final sortedSeries = seriesSet.toList()..sort();

    final hasActive = _status != _ReadingStatus.all ||
        _genre != null ||
        _series != null;

    return DraggableScrollableSheet(
      initialChildSize: 0.5,
      minChildSize: 0.3,
      maxChildSize: 0.85,
      expand: false,
      builder: (context, scrollController) => Column(
        children: [
          // Handle bar.
          Container(
            margin: const EdgeInsets.only(top: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: scheme.onSurfaceVariant.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // Header.
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
          // Content.
          Expanded(
            child: ListView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
              children: [
                // Reading status.
                _FilterSection(
                  label: 'Reading status',
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _PillChip(
                        label: 'All',
                        selected: _status == _ReadingStatus.all,
                        onTap: () => setState(() {
                          _status = _ReadingStatus.all;
                          widget.onStatusChanged(_status);
                        }),
                      ),
                      _PillChip(
                        label: 'Reading',
                        selected: _status == _ReadingStatus.reading,
                        onTap: () => setState(() {
                          _status = _ReadingStatus.reading;
                          widget.onStatusChanged(_status);
                        }),
                      ),
                      _PillChip(
                        label: 'Finished',
                        selected: _status == _ReadingStatus.finished,
                        onTap: () => setState(() {
                          _status = _ReadingStatus.finished;
                          widget.onStatusChanged(_status);
                        }),
                      ),
                      _PillChip(
                        label: 'New',
                        selected: _status == _ReadingStatus.new_,
                        onTap: () => setState(() {
                          _status = _ReadingStatus.new_;
                          widget.onStatusChanged(_status);
                        }),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                // Genre.
                if (sortedGenres.isNotEmpty)
                  _FilterSection(
                    label: 'Genre',
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _PillChip(
                          label: 'All genres',
                          selected: _genre == null,
                          onTap: () => setState(() {
                            _genre = null;
                            widget.onGenreChanged(null);
                          }),
                        ),
                        for (final g in sortedGenres)
                          _PillChip(
                            label: g,
                            selected: _genre?.toLowerCase() == g.toLowerCase(),
                            onTap: () => setState(() {
                              _genre = g;
                              widget.onGenreChanged(g);
                            }),
                          ),
                      ],
                    ),
                  ),
                if (sortedGenres.isNotEmpty) const SizedBox(height: 24),
                // Series.
                if (sortedSeries.isNotEmpty)
                  _FilterSection(
                    label: 'Series',
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _PillChip(
                          label: 'All series',
                          selected: _series == null,
                          onTap: () => setState(() {
                            _series = null;
                            widget.onSeriesChanged(null);
                          }),
                        ),
                        for (final s in sortedSeries)
                          _PillChip(
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

class _FilterSection extends StatelessWidget {
  const _FilterSection({
    required this.label,
    required this.child,
  });

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

/// Expressive filter pill: filled primary when selected, outlined when not.
///
/// Enforces the 48dp minimum interactive target at the widget level so the
/// guarantee survives any ambient [ChipTheme].
class _PillChip extends StatelessWidget {
  const _PillChip({
    required this.label,
    required this.onTap,
    this.selected = false,
    this.icon,
  });

  final String label;
  final VoidCallback onTap;
  final bool selected;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        child: Material(
          color: selected ? scheme.primary : Colors.transparent,
          shape: StadiumBorder(
            side: BorderSide(
              color: selected ? scheme.primary : scheme.outlineVariant.withValues(alpha: 0.5),
            ),
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
                    Icon(icon, size: 18, color: scheme.primary),
                    const SizedBox(width: 6),
                  ],
                  Text(
                    label,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      letterSpacing: 0.15,
                      color: selected
                          ? scheme.onPrimary
                          : scheme.onSurfaceVariant,
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

/// Hero "keep reading" card on a tonal primary surface. Large shape family,
/// sharing the grid's corner-rounding direction so the hierarchy reads as
/// one system.
class _ContinueCard extends StatelessWidget {
  const _ContinueCard({required this.book, required this.onTap});

  final Book book;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final onCard = scheme.onPrimaryContainer;
    return Semantics(
      button: true,
      label:
          'Continue reading ${book.displayTitle}. ${book.progressSemantics}',
      excludeSemantics: true,
      child: _PressableScale(
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: Burrow.r(Burrow.shapeLg),
            boxShadow: [
              BoxShadow(
                color: scheme.primary.withValues(alpha: 0.25),
                blurRadius: 22,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Material(
            color: scheme.primaryContainer,
            shape: RoundedSuperellipseBorder(
              borderRadius: Burrow.r(Burrow.shapeLg),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 86,
                      child: Hero(
                        tag: 'hero-${book.id}',
                        child: BookCover(
                          book: book,
                          borderRadius: Burrow.shapeMd - 2,
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.auto_stories_rounded,
                                  size: 15,
                                  color: onCard.withValues(alpha: 0.8)),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  'CONTINUE READING',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context)
                                      .textTheme
                                      .labelSmall
                                      ?.copyWith(
                                        color: onCard.withValues(alpha: 0.8),
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: 0.9,
                                      ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            book.displayTitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context)
                                .textTheme
                                .titleLarge
                                ?.copyWith(
                                    fontWeight: FontWeight.w800, color: onCard),
                          ),
                          if (book.author.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                book.author,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(
                                        color: onCard.withValues(alpha: 0.75)),
                              ),
                            ),
                          const SizedBox(height: 14),
                          SegmentedProgressBar(
                            value: book.progress.clamp(0, 1),
                            height: 8,
                            track: onCard.withValues(alpha: 0.22),
                            fill: onCard,
                          ),
                          const SizedBox(height: 10),
                          Align(
                            alignment: Alignment.centerRight,
                            child: Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: onCard.withValues(alpha: 0.14),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(Icons.play_arrow_rounded,
                                  size: 24, color: onCard),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Grid card: a contained tappable unit — tonal surface, medium squircle,
/// hairline outline — holding a uniform 2:3 cover, tonal format badge and a
/// thin segmented progress bar once reading has started.
class _BookTile extends StatelessWidget {
  const _BookTile({
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
    final titleStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
          fontWeight: FontWeight.w700,
          fontSize: 12.5,
          height: 1.2,
        );

    return MergeSemantics(
      child: Semantics(
        button: true,
        label:
            '${book.displayTitle}${book.author.isEmpty ? '' : ' by ${book.author}'}. ${book.progressSemantics}',
        hint: 'Double tap to read; long press for options',
        excludeSemantics: true,
        child: _PressableScale(
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: Burrow.r(Burrow.shapeMd),
              boxShadow: [
                BoxShadow(
                  color: scheme.scrim.withValues(alpha: 0.06),
                  blurRadius: 8,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Material(
              color: scheme.surfaceContainerLow,
              shape: RoundedSuperellipseBorder(
                borderRadius: Burrow.r(Burrow.shapeMd),
                side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onTap,
                onLongPress: onLongPress,
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: _CoverArea(book: book)),
                      const SizedBox(height: 7),
                      SizedBox(
                        height: 16,
                        child: Text(
                          book.displayTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: titleStyle,
                        ),
                      ),
                      if (book.author.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: Text(
                            book.author,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                  fontSize: 11,
                                ),
                          ),
                        ),
                      const SizedBox(height: 2),
                      SizedBox(
                        height: 13,
                        child: _StatusLine(book: book),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Horizontal list tile: cover thumbnail on the left, title/author/status on
/// the right.  Used when the library is in list layout mode.
class _BookListTile extends StatelessWidget {
  const _BookListTile({
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
    final titleStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(
          fontWeight: FontWeight.w700,
          fontSize: 14,
          height: 1.25,
          color: scheme.onSurface,
        );
    final metaStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
          fontSize: 12,
        );

    final file = File(book.path);
    final fileSize =
        file.existsSync() ? _formatFileSize(file.lengthSync()) : '';
    final formatLabel = book.format.name.toUpperCase();

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        button: true,
        label:
            '${book.displayTitle}${book.author.isEmpty ? '' : ' by ${book.author}'}. ${book.progressSemantics}',
        hint: 'Double tap to read; long press for options',
        excludeSemantics: true,
        child: _PressableScale(
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: Burrow.r(Burrow.shapeMd),
              boxShadow: [
                BoxShadow(
                  color: scheme.scrim.withValues(alpha: 0.06),
                  blurRadius: 8,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Material(
              color: scheme.surfaceContainerLow,
              shape: RoundedSuperellipseBorder(
                borderRadius: Burrow.r(Burrow.shapeMd),
                side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onTap,
                onLongPress: onLongPress,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Cover thumbnail (2:3 aspect ratio).
                      SizedBox(
                        width: 88,
                        height: 132,
                        child: _CoverArea(book: book, showProgress: false),
                      ),
                      const SizedBox(width: 12),
                      // Text block.
                      Expanded(
                        child: SizedBox(
                          height: 132,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    book.displayTitle,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: titleStyle,
                                  ),
                                  const SizedBox(height: 2),
                                  if (book.author.isNotEmpty)
                                    Text(
                                      book.author,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: metaStyle,
                                    ),
                                  const SizedBox(height: 3),
                                  Text(
                                    fileSize.isEmpty
                                        ? formatLabel
                                        : '$formatLabel, $fileSize',
                                    style: metaStyle,
                                  ),
                                ],
                              ),
                              if (book.showProgress) ...[
                                const SizedBox(height: 6),
                                SegmentedProgressBar(
                                  value: book.progress,
                                  track: scheme.surfaceContainerHighest,
                                  fill: scheme.primary,
                                  height: 4,
                                ),
                                const SizedBox(height: 6),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Cover with overlaid badge and progress bar; sized by the parent grid to a
/// strict 2:3 frame.
class _CoverArea extends StatelessWidget {
  const _CoverArea({required this.book, this.showProgress = true});

  final Book book;
  final bool showProgress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final started = book.showProgress;
    final (badgeBg, badgeFg) = Burrow.formatTonal(scheme, book.format);

    return Stack(
      fit: StackFit.expand,
      children: [
        Hero(
          tag: 'tile-${book.id}',
          child: BookCover(book: book, borderRadius: Burrow.shapeMd - 6),
        ),
        // Legibility scrim under the progress bar.
        if (started && showProgress)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 26,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.5),
                  ],
                ),
              ),
            ),
          ),
        Positioned(
          top: 6,
          right: 6,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!book.isStarted)
                Container(
                  margin: const EdgeInsets.only(right: 4),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(99),
                  ),
                  child: Text(
                    'NEW',
                    style: TextStyle(
                      color: scheme.onPrimary,
                      fontSize: 8,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                      height: 1,
                    ),
                  ),
                ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: badgeBg.withValues(alpha: 0.95),
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text(
                  book.format.name.toUpperCase(),
                  style: TextStyle(
                    color: badgeFg,
                    fontSize: 8,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
                    height: 1,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (started && showProgress)
          Positioned(
            left: 7,
            right: 7,
            bottom: 7,
            child: SegmentedProgressBar(
              value: book.progress.clamp(0, 1),
              height: 4,
              animate: false,
              track: Colors.white.withValues(alpha: 0.38),
              fill: Colors.white,
            ),
          ),
      ],
    );
  }
}

/// Status metadata line: started books show a bar plus percent;
/// finished shows "Finished". Unstarted books show nothing (the "NEW" badge
/// lives on the cover).
class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.book});

  final Book book;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
          color: scheme.onSurfaceVariant,
          fontWeight: book.isFinished ? FontWeight.w700 : FontWeight.w500,
          height: 1,
        );

    if (!book.isStarted) {
      return const SizedBox.shrink();
    }
    if (book.isFinished) {
      return Row(
        children: [
          Icon(Icons.check_circle_rounded, size: 12, color: scheme.primary),
          const SizedBox(width: 3),
          Expanded(
            child: Text(
              'Finished',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
        ],
      );
    }
    return const SizedBox.shrink();
  }
}

/// One labelled pill + tonal round icon, as in an M3 Expressive FAB menu.
class _FabMenuItem extends StatelessWidget {
  const _FabMenuItem({
    required this.icon,
    required this.label,
    required this.scheme,
    required this.delay,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final ColorScheme scheme;

  /// Normalized stagger start, 0..1 of the entrance duration.
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

class _SheetAction extends StatelessWidget {
  const _SheetAction({
    required this.icon,
    required this.label,
    required this.iconColor,
    required this.iconBg,
    required this.onTap,
    this.labelColor,
  });

  final IconData icon;
  final String label;
  final Color iconColor;
  final Color iconBg;
  final Color? labelColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Material(
        color: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: Burrow.r(Burrow.shapeMd)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration:
                      BoxDecoration(color: iconBg, shape: BoxShape.circle),
                  child: Icon(icon, size: 21, color: iconColor),
                ),
                const SizedBox(width: 14),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color:
                        labelColor ?? Theme.of(context).colorScheme.onSurface,
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

class _BusyState extends StatelessWidget {
  const _BusyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(strokeWidth: 3),
          const SizedBox(height: 20),
          Text(
            'Growing your burrow…',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: Theme.of(context).hintColor,
                ),
          ),
        ],
      ),
    );
  }
}

class _NoResults extends StatelessWidget {
  const _NoResults();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 84,
            height: 84,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.search_off_rounded,
                size: 38, color: scheme.outline),
          ),
          const SizedBox(height: 18),
          Text(
            'Nothing matches',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            'Try another word or clear the filters.',
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: Theme.of(context).hintColor),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onPickFile, required this.onScan});

  final VoidCallback onPickFile;
  final VoidCallback onScan;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 104,
              height: 104,
              decoration: ShapeDecoration(
                color: scheme.secondaryContainer,
                shape: RoundedSuperellipseBorder(borderRadius: Burrow.r(36)),
              ),
              child: Icon(Icons.auto_stories_outlined,
                  size: 46, color: scheme.onSecondaryContainer),
            ),
            const SizedBox(height: 24),
            Text(
              'Your burrow is empty',
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            Text(
              'Import a file or scan your device\nfor EPUB, TXT and PDF books.',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: Theme.of(context).hintColor),
            ),
            const SizedBox(height: 30),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                minimumSize: const Size(210, 54),
                shape: RoundedRectangleBorder(
                  borderRadius: Burrow.r(Burrow.shapeLg),
                ),
                textStyle:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
              onPressed: onPickFile,
              icon: const Icon(Icons.upload_file_outlined),
              label: const Text('Import file'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(210, 54),
                shape: RoundedRectangleBorder(
                  borderRadius: Burrow.r(Burrow.shapeLg),
                ),
              ),
              onPressed: onScan,
              icon: const Icon(Icons.travel_explore_outlined),
              label: const Text('Scan device'),
            ),
          ],
        ),
      ),
    );
  }
}

String _formatFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.label,
    required this.value,
    this.isFile = false,
  });

  final String label;
  final String value;
  final bool isFile;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 13,
                color: theme.colorScheme.onSurface,
              ),
              overflow: isFile ? TextOverflow.ellipsis : null,
              maxLines: isFile ? 2 : null,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Authors / Collections / Smart Groups helpers
// ---------------------------------------------------------------------------

class _AuthorTile extends StatelessWidget {
  const _AuthorTile({
    required this.name,
    required this.bookCount,
    required this.onTap,
  });

  final String name;
  final int bookCount;
  final VoidCallback onTap;

  Color _avatarColor(ColorScheme scheme) {
    final h = name.hashCode;
    final hue = (h % 360).abs().toDouble();
    return HSLColor.fromAHSL(1, hue, 0.35, 0.55).toColor();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _PressableScale(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        leading: CircleAvatar(
          radius: 24,
          backgroundColor: _avatarColor(scheme),
          child: Text(
            name.isNotEmpty ? name[0].toUpperCase() : '?',
            style: TextStyle(
              color: scheme.onPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 18,
            ),
          ),
        ),
        title: Text(
          name,
          style: const TextStyle(fontWeight: FontWeight.w600),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          '$bookCount book${bookCount == 1 ? '' : 's'}',
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
        ),
        trailing: Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
        onTap: onTap,
      ),
    );
  }
}

class _CollectionTile extends StatefulWidget {
  const _CollectionTile({
    required this.collection,
    required this.library,
    required this.onTap,
    required this.onLongPress,
  });

  final db.Collection collection;
  final LibraryService library;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  State<_CollectionTile> createState() => _CollectionTileState();
}

class _CollectionTileState extends State<_CollectionTile> {
  int? _count;

  @override
  void initState() {
    super.initState();
    _loadCount();
  }

  Future<void> _loadCount() async {
    final count = await widget.library.getCollectionBookCount(widget.collection.id);
    if (!mounted) return;
    setState(() => _count = count);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _PressableScale(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        leading: CircleAvatar(
          radius: 24,
          backgroundColor: scheme.secondaryContainer,
          child: Icon(Icons.collections_bookmark_outlined,
              color: scheme.onSecondaryContainer),
        ),
        title: Text(
          widget.collection.name,
          style: const TextStyle(fontWeight: FontWeight.w600),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: _count != null && _count! > 0
            ? Text(
                '$_count book${_count == 1 ? '' : 's'}',
                style: TextStyle(color: scheme.onSurfaceVariant),
              )
            : null,
        trailing: Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
      ),
    );
  }
}

class _SmartGroupTile extends StatelessWidget {
  const _SmartGroupTile({
    required this.icon,
    required this.label,
    required this.count,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _PressableScale(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        leading: CircleAvatar(
          radius: 24,
          backgroundColor: scheme.tertiaryContainer,
          child: Icon(icon, color: scheme.onTertiaryContainer),
        ),
        title: Text(
          label,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          '$count book${count == 1 ? '' : 's'}',
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
        ),
        trailing: Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
        onTap: onTap,
      ),
    );
  }
}

class _EmptyTabState extends StatelessWidget {
  const _EmptyTabState({
    required this.icon,
    required this.message,
    required this.detail,
  });

  final IconData icon;
  final String message;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 64, color: scheme.outlineVariant),
          const SizedBox(height: 16),
          Text(
            message,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            detail,
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _CollectionPickerTile extends StatelessWidget {
  const _CollectionPickerTile({
    required this.collection,
    required this.isInCollection,
    required this.onToggle,
  });

  final db.Collection collection;
  final Future<bool> isInCollection;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<bool>(
      future: isInCollection,
      builder: (context, snapshot) {
        final inCollection = snapshot.data ?? false;
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 24),
          leading: Icon(
            inCollection
                ? Icons.check_circle_rounded
                : Icons.circle_outlined,
            color: inCollection ? scheme.primary : scheme.outlineVariant,
          ),
          title: Text(
            collection.name,
            style: const TextStyle(fontWeight: FontWeight.w500),
          ),
          onTap: onToggle,
        );
      },
    );
  }
}
