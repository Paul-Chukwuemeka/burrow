import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../db/database.dart' as db;
import '../models/book.dart';
import '../models/library_enums.dart';
import '../models/reader_settings.dart';
import '../services/import_helper.dart';
import '../services/library_service.dart';
import '../services/scan_service.dart';
import '../theme/burrow_tokens.dart';
import '../utils/book_title.dart';
import '../utils/date_format.dart';
import '../utils/file_size.dart';
import '../widgets/book_card.dart';
import '../widgets/book_cover.dart';
import '../widgets/library_filter_widgets.dart';
import '../widgets/library_header.dart';
import '../widgets/library_sheet_widgets.dart';
import '../widgets/library_state_widgets.dart';
import '../widgets/library_tile_widgets.dart';
import '../widgets/pill_chip.dart';
import 'author_screen.dart';
import 'book_info_screen.dart';
import 'collection_screen.dart';
import 'reader_screen.dart';
import 'settings_screen.dart';
import 'smart_group_screen.dart';
import 'stats_screen.dart';

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
  bool _searchOpen = false;

  String _query = '';
  Set<BookFormat> _formatFilters = {};
  SortMode _sort = SortMode.recent;
  late LayoutMode _layout;
  LibraryTab _tab = LibraryTab.books;
  _ReadingStatus _statusFilter = _ReadingStatus.all;
  String? _genreFilter;
  String? _seriesFilter;

  StatusType? _activeStatus;
  int _statusCompleted = 0;
  int _statusTotal = 0;
  String? _statusBookTitle;
  String? _statusResult;

  List<Book>? _cachedVisibleBooks;
  String? _cacheKey;

  final _searchController = TextEditingController();
  StreamSubscription<MetadataStatus>? _metadataSubscription;

  @override
  void initState() {
    super.initState();
    final saved = widget.library.libraryLayout;
    _layout = saved == 'list' ? LayoutMode.list : LayoutMode.grid;
    widget.library.addListener(_onLibraryChanged);

    _loadFilters();

    _metadataSubscription = widget.library.metadataStatus.listen((status) {
      if (!mounted) return;
      setState(() {
        switch (status.type) {
          case MetadataStatusType.started:
            _activeStatus = StatusType.extracting;
            _statusTotal = status.total;
            _statusCompleted = status.completed;
            _statusBookTitle = null;
            break;
          case MetadataStatusType.progress:
            _activeStatus = StatusType.extracting;
            _statusTotal = status.total;
            _statusCompleted = status.completed;
            _statusBookTitle = status.bookTitle;
            break;
          case MetadataStatusType.completed:
            _activeStatus = null;
            _statusBookTitle = null;
            break;
        }
      });
    });
  }

  @override
  void dispose() {
    widget.library.removeListener(_onLibraryChanged);
    _metadataSubscription?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onLibraryChanged() {
    if (!mounted) return;
    final saved = widget.library.libraryLayout;
    final newLayout = saved == 'list' ? LayoutMode.list : LayoutMode.grid;
    _cacheKey = null;
    setState(() => _layout = newLayout);
  }

  Future<void> _loadFilters() async {
    final data = await widget.library.loadFilters();
    if (data == null || !mounted) return;
    setState(() {
      final sortName = data['sort'] as String?;
      if (sortName != null) {
        _sort = SortMode.values.firstWhere(
          (e) => e.name == sortName,
          orElse: () => SortMode.recent,
        );
      }
      final statusName = data['status'] as String?;
      if (statusName != null) {
        _statusFilter = _ReadingStatus.values.firstWhere(
          (e) => e.name == statusName,
          orElse: () => _ReadingStatus.all,
        );
      }
      _genreFilter = data['genre'] as String?;
      _seriesFilter = data['series'] as String?;
      final formatNames = data['formats'] as List<dynamic>?;
      if (formatNames != null) {
        _formatFilters = {
          for (final f in formatNames)
            BookFormat.values.firstWhere(
              (e) => e.name == f,
              orElse: () => BookFormat.epub,
            ),
        };
      }
    });
  }

  void _saveFilters() {
    widget.library.saveFilters(
      sort: _sort.name,
      status: _statusFilter.name,
      genre: _genreFilter,
      series: _seriesFilter,
      formats: [for (final f in _formatFilters) f.name],
    );
  }

  String get _sortLabel => switch (_sort) {
    SortMode.recent => 'Recent',
    SortMode.added => 'Added',
    SortMode.title => 'A–Z',
  };

  int get _activeFilterCount {
    var count = _formatFilters.length;
    if (_statusFilter != _ReadingStatus.all) count++;
    if (_genreFilter != null) count++;
    if (_seriesFilter != null) count++;
    return count;
  }

  Future<void> _showFilterSheet(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: false,
      builder: (context) => FilterSheet(
        statusFilter: _statusFilter == _ReadingStatus.all
            ? ReadingStatus.all
            : _statusFilter == _ReadingStatus.reading
            ? ReadingStatus.reading
            : _statusFilter == _ReadingStatus.finished
            ? ReadingStatus.finished
            : ReadingStatus.new_,
        genreFilter: _genreFilter,
        seriesFilter: _seriesFilter,
        formatFilters: _formatFilters,
        books: widget.library.books,
        onStatusChanged: (s) {
          setState(() {
            _statusFilter = switch (s) {
              ReadingStatus.all => _ReadingStatus.all,
              ReadingStatus.reading => _ReadingStatus.reading,
              ReadingStatus.finished => _ReadingStatus.finished,
              ReadingStatus.new_ => _ReadingStatus.new_,
            };
          });
          _saveFilters();
        },
        onGenreChanged: (g) {
          setState(() => _genreFilter = g);
          _saveFilters();
        },
        onSeriesChanged: (s) {
          setState(() => _seriesFilter = s);
          _saveFilters();
        },
        onFormatsChanged: (f) {
          setState(() => _formatFilters = Set.of(f));
          _saveFilters();
        },
        onClearAll: () {
          setState(() {
            _statusFilter = _ReadingStatus.all;
            _genreFilter = null;
            _seriesFilter = null;
            _formatFilters = {};
          });
          _saveFilters();
        },
      ),
    );
  }

  List<Book> get _visibleBooks {
    final key =
        '$_formatFilters:$_statusFilter:$_genreFilter:$_seriesFilter:$_query:$_sort:${widget.library.books.length}';
    if (_cacheKey == key && _cachedVisibleBooks != null) {
      return _cachedVisibleBooks!;
    }

    final genreLower = _genreFilter?.toLowerCase();
    final seriesLower = _seriesFilter?.toLowerCase();
    final q = _query.trim().toLowerCase();

    var books = widget.library.sorted.where((b) {
      if (_formatFilters.isNotEmpty && !_formatFilters.contains(b.format))
        return false;
      switch (_statusFilter) {
        case _ReadingStatus.all:
          break;
        case _ReadingStatus.reading:
          if (!(b.isStarted && !b.isFinished)) return false;
        case _ReadingStatus.finished:
          if (!b.isFinished) return false;
        case _ReadingStatus.new_:
          if (b.isStarted) return false;
      }
      if (genreLower != null) {
        if (b.genre == null) return false;
        if (!b.genre!
            .split(',')
            .any((g) => g.trim().toLowerCase() == genreLower)) {
          return false;
        }
      }
      if (seriesLower != null) {
        if (b.seriesName?.toLowerCase() != seriesLower) return false;
      }
      if (q.isNotEmpty) {
        if (!b.displayTitle.toLowerCase().contains(q) &&
            !b.author.toLowerCase().contains(q)) {
          return false;
        }
      }
      return true;
    }).toList();

    switch (_sort) {
      case SortMode.recent:
        break;
      case SortMode.added:
        books.sort((a, b) => b.addedAt.compareTo(a.addedAt));
      case SortMode.title:
        books.sort(
          (a, b) => a.displayTitle.toLowerCase().compareTo(
            b.displayTitle.toLowerCase(),
          ),
        );
    }

    _cacheKey = key;
    _cachedVisibleBooks = books;
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
    try {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ReaderScreen(
            book: book,
            library: widget.library,
            heroTag: heroTag,
          ),
        ),
      );
    } on IOException {
      if (mounted) {
        _snack('"${book.displayTitle}" could not be opened');
      }
      return;
    }
    if (mounted) setState(() {});
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
      allowedExtensions: const ['epub', 'txt', 'pdf', 'cbz', 'cbr'],
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

  /// Runs the scan type chosen in Settings.
  Future<void> _scanPreferred() async {
    switch (widget.library.settings.scanMode) {
      case ScanMode.device:
        await _scanDevice();
      case ScanMode.folder:
        await _pickFolderAndScan();
      case ScanMode.quick:
        await _quickRefresh();
    }
  }

  Future<void> _onRefresh() async {
    await _quickRefresh();
  }

  /// Quick refresh: scans only the folders that contain known books.
  /// Much faster than a full device scan because it skips unrelated directories.
  Future<void> _quickRefresh() async {
    final folders = _knownFolders();

    if (folders.isEmpty) {
      // No books yet -- fall back to full device scan.
      await _scanDevice();
      return;
    }

    await _runScan(ScanService.scanFolders(folders, knownPaths: _knownPaths()));
  }

  Set<String> _knownPaths() => widget.library.books.map((b) => b.path).toSet();

  /// Extracts unique parent folders from all known book paths.
  Set<String> _knownFolders() =>
      widget.library.books.map((b) => File(b.path).parent.path).toSet();

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
      _snack(
        count > 0
            ? 'Restored $count book${count == 1 ? '' : 's'} from backup'
            : 'Backup matches the current library',
      );
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
      _activeStatus = StatusType.scanning;
      _statusCompleted = 0;
      _statusTotal = 0;
      _statusBookTitle = null;
      _statusResult = null;
    });
    try {
      final (paths, added, failed) = await BookImporter.runScan(
        widget.library,
        scan,
        onScanComplete: (pathCount) {
          if (!mounted) return;
          setState(() {
            if (pathCount > 0) {
              _activeStatus = StatusType.importing;
              _statusTotal = pathCount;
              _statusCompleted = 0;
            }
          });
        },
        onProgress: (completed, total) {
          if (!mounted) return;
          setState(() {
            _statusCompleted = completed;
            _statusTotal = total;
          });
        },
      );
      if (!mounted) return;
      final msg = paths.isEmpty
          ? 'No new books found'
          : 'Added ${added.length} book${added.length == 1 ? '' : 's'}'
                '${failed > 0 ? ', $failed unreadable' : ''}';
      setState(() {
        _activeStatus = StatusType.completed;
        _statusResult = msg;
      });
      await Future<void>.delayed(const Duration(seconds: 2));
      if (mounted) {
        setState(() {
          _activeStatus = null;
          _statusResult = null;
        });
      }
    } catch (e) {
      debugPrint('Scan failed: $e');
      if (mounted) {
        setState(() {
          _activeStatus = StatusType.completed;
          _statusResult = e is TimeoutException
              ? 'Scan timed out — try a specific folder'
              : 'Scan failed. Please try again.';
        });
        Future<void>.delayed(const Duration(seconds: 2), () {
          if (mounted) {
            setState(() {
              _activeStatus = null;
              _statusResult = null;
            });
          }
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importPaths(List<String> paths, {bool openFirst = true}) async {
    final errors = <String>[];
    final (added, failed) = await BookImporter.importPaths(
      widget.library,
      paths,
      onFormatError: (e) => errors.add(e.message),
      onError: (_) => errors.add('Could not open file'),
    );
    if (!mounted) return;
    if (openFirst && added.isNotEmpty) await _openBook(added.first);
    if (paths.length > 1) {
      final msg = StringBuffer(
        'Added ${added.length} book${added.length == 1 ? '' : 's'}',
      );
      if (errors.isNotEmpty) {
        msg.write(' (${errors.length} failed)');
      }
      _snack(msg.toString());
    } else if (errors.isNotEmpty) {
      _snack(errors.first);
    }
  }

  void _runFromFab(Future<void> Function() action) {
    setState(() => _fabOpen = false);
    action().catchError((e) {
      debugPrint('FAB action failed: $e');
    });
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
                    : Text(
                        book.author,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
              ),
              const SizedBox(height: 4),
              SheetAction(
                icon: Icons.menu_book_outlined,
                label: 'Read now',
                iconColor: scheme.onSecondaryContainer,
                iconBg: scheme.secondaryContainer,
                onTap: () {
                  Navigator.pop(sheetContext);
                  _openBook(book);
                },
              ),
              SheetAction(
                icon: Icons.edit_outlined,
                label: 'Edit metadata',
                iconColor: scheme.onTertiaryContainer,
                iconBg: scheme.tertiaryContainer,
                onTap: () {
                  Navigator.pop(sheetContext);
                  _showEditMetadataSheet(book);
                },
              ),
              SheetAction(
                icon: Icons.info_outline_rounded,
                label: 'Book details',
                iconColor: scheme.onSurfaceVariant,
                iconBg: scheme.surfaceContainerHighest,
                onTap: () {
                  Navigator.pop(sheetContext);
                  _showBookDetailsSheet(book);
                },
              ),
              SheetAction(
                icon: Icons.collections_bookmark_outlined,
                label: 'Add to collection',
                iconColor: scheme.onPrimaryContainer,
                iconBg: scheme.primaryContainer,
                onTap: () {
                  Navigator.pop(sheetContext);
                  _showAddToCollectionSheet(book);
                },
              ),
              SheetAction(
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
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
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
                onChanged: (_) => setSheetState(() {}),
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
                      onPressed: titleController.text.trim().isEmpty
                          ? null
                          : () {
                              final newTitle = titleController.text.trim();
                              final newAuthor = authorController.text.trim();
                              widget.library.updateBook(
                                book.id,
                                title: newTitle,
                                author: newAuthor,
                              );
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
      ),
    );
  }

  Future<void> _showBookDetailsSheet(Book book) async {
    final file = File(book.path);
    String fileSize;
    try {
      fileSize = formatFileSize(await file.length());
    } catch (_) {
      fileSize = 'Unknown';
    }

    if (!mounted) return;
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
                  : Text(
                      book.author,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
            ),
            const Divider(indent: 16, endIndent: 16),
            DetailRow(label: 'Format', value: book.format.name.toUpperCase()),
            DetailRow(label: 'File size', value: fileSize),
            DetailRow(label: 'Added', value: formatDate(book.addedAt)),
            if (book.lastReadAt > 0)
              DetailRow(label: 'Last read', value: formatDate(book.lastReadAt)),
            DetailRow(label: 'Progress', value: book.progressLabel),
            DetailRow(label: 'Path', value: book.path, isFile: true),
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
                        onPressed: () async {
                          Navigator.pop(sheetContext);
                          await widget.library.deleteBookWithFile(
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
                ...collections.map(
                  (c) => CollectionPickerTile(
                    collection: c,
                    isInCollection: widget.library.isBookInCollection(
                      c.id,
                      book.id,
                    ),
                    onToggle: () async {
                      final isIn = await widget.library.isBookInCollection(
                        c.id,
                        book.id,
                      );
                      if (isIn) {
                        await widget.library.removeBookFromCollection(
                          c.id,
                          book.id,
                        );
                      } else {
                        await widget.library.addBookToCollection(c.id, book.id);
                      }
                      setSheetState(() {});
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
                  final id = await widget.library.createCollection(name);
                  if (id.isNotEmpty) {
                    await widget.library.addBookToCollection(id, book.id);
                  }
                  if (sheetContext.mounted) Navigator.pop(sheetContext);
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
                      if (name.isNotEmpty && sheetContext.mounted) {
                        Navigator.pop(sheetContext);
                        final id = await widget.library.createCollection(name);
                        if (id.isNotEmpty) {
                          await widget.library.addBookToCollection(id, book.id);
                        }
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
    final allBooks = widget.library.books;
    final books = _visibleBooks;
    final recent =
        (_query.isEmpty &&
            _formatFilters.isEmpty &&
            _statusFilter == _ReadingStatus.all &&
            _genreFilter == null &&
            _seriesFilter == null)
        ? widget.library.mostRecent
        : null;
    final hasLibrary = allBooks.isNotEmpty;
    final filtered =
        books.length != allBooks.length ||
        _query.isNotEmpty ||
        _formatFilters.isNotEmpty ||
        _statusFilter != _ReadingStatus.all ||
        _genreFilter != null ||
        _seriesFilter != null;

    return DefaultTabController(
      length: 3,
      initialIndex: _tab.index,
      child: Scaffold(
        body: Stack(
          children: [
            RefreshIndicator(
              onRefresh: _onRefresh,
              child: CustomScrollView(
                slivers: [
                  BurrowHeader(
                    tab: _tab,
                    onTabChanged: (tab) => setState(() {
                      _tab = tab;
                      _query = '';
                      _searchController.clear();
                      _searchOpen = false;
                    }),
                    activeFilterCount: _activeFilterCount,
                    onFilterTap: () => _showFilterSheet(context),
                    onStats: () =>
                        StatsScreen.show(context, library: widget.library),
                    onExport: _exportLibrary,
                    onImportBackup: _importLibrary,
                    onSettings: () =>
                        SettingsScreen.show(context, library: widget.library),
                    onSearch: () => setState(() {
                      _searchOpen = !_searchOpen;
                      if (!_searchOpen) {
                        _query = '';
                        _searchController.clear();
                      }
                    }),
                  ),
                  if (hasLibrary && widget.library.isScanning)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
                        child: _ScanningBanner(library: widget.library),
                      ),
                    ),
                  if (hasLibrary)
                    ..._tabContent(context, books, recent, filtered),
                  if (!hasLibrary)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: _busy || widget.library.isScanning
                          ? const BusyState()
                          : EmptyState(
                              onPickFile: _pickFile,
                              onScan: _scanPreferred,
                            ),
                    ),
                ],
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                ignoring: !_fabOpen,
                child: AnimatedOpacity(
                  opacity: _fabOpen ? 1 : 0,
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOut,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.scrim.withValues(alpha: 0.45),
                    ),
                    child: GestureDetector(
                      onTap: () => setState(() => _fabOpen = false),
                    ),
                  ),
                ),
              ),
            ),
            if (_activeStatus != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: StatusBanner(
                  status: _activeStatus!,
                  completed: _statusCompleted,
                  total: _statusTotal,
                  bookTitle: _statusBookTitle,
                  result: _statusResult,
                ),
              ),
            if (_searchOpen) _buildSearchOverlay(context),
          ],
        ),
        floatingActionButton: _tab == LibraryTab.books
            ? _buildFab(context)
            : null,
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
      LibraryTab.books => _libraryContent(context, books, recent, filtered),
      LibraryTab.authors => _authorsContent(context),
      LibraryTab.collections => _collectionsContent(context),
    };
  }

  List<Widget> _libraryContent(
    BuildContext context,
    List<Book> books,
    Book? recent,
    bool filtered,
  ) {
    return [
      if (recent != null)
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
          sliver: SliverToBoxAdapter(
            child: ContinueCard(
              book: recent,
              onTap: () => _openBookInfo(recent, heroTag: 'hero-${recent.id}'),
            ),
          ),
        ),
      if (books.isEmpty)
        const SliverFillRemaining(hasScrollBody: false, child: NoResults())
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
                      filtered
                          ? '${books.length} found'
                          : 'All books · ${books.length}',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                      ),
                    ),
                  ),
                ),
                PillChip(
                  label: _sortLabel,
                  icon: Icons.sort_rounded,
                  onTap: () => setState(() {
                    _sort = SortMode
                        .values[(_sort.index + 1) % SortMode.values.length];
                  }),
                ),
                const SizedBox(width: 8),
                PillChip(
                  label: _layout == LayoutMode.grid ? 'Grid' : 'List',
                  icon: _layout == LayoutMode.grid
                      ? Icons.grid_view_rounded
                      : Icons.view_list_rounded,
                  onTap: () {
                    final next = LayoutMode
                        .values[(_layout.index + 1) % LayoutMode.values.length];
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
          sliver: _layout == LayoutMode.grid
              ? SliverLayoutBuilder(
                  builder: (context, constraints) =>
                      _bookGrid(constraints.crossAxisExtent, books),
                )
              : _bookList(books),
        ),
      ],
      const SliverPadding(
        padding: EdgeInsets.only(bottom: Burrow.fabClearance),
      ),
    ];
  }

  List<Widget> _authorsContent(BuildContext context) {
    final authors = widget.library.uniqueAuthors;
    if (authors.isEmpty) {
      return [
        const SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyTabState(
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
            return AuthorTile(
              name: author,
              bookCount: count,
              onTap: () => _openAuthorScreen(author),
            );
          },
        ),
      ),
      const SliverPadding(
        padding: EdgeInsets.only(bottom: Burrow.fabClearance),
      ),
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
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        sliver: SliverList(
          delegate: SliverChildListDelegate([
            SmartGroupTile(
              icon: Icons.auto_stories_outlined,
              label: 'Reading',
              count: widget.library.books
                  .where((b) => b.isStarted && !b.isFinished)
                  .length,
              onTap: () => _openSmartGroup('Reading'),
            ),
            SmartGroupTile(
              icon: Icons.check_circle_outline_rounded,
              label: 'Finished',
              count: widget.library.books.where((b) => b.isFinished).length,
              onTap: () => _openSmartGroup('Finished'),
            ),
            SmartGroupTile(
              icon: Icons.fiber_new_outlined,
              label: 'New',
              count: widget.library.books.where((b) => !b.isStarted).length,
              onTap: () => _openSmartGroup('New'),
            ),
          ]),
        ),
      ),
      if (collections.isEmpty)
        const SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: 20),
          sliver: SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: EmptyTabState(
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
              return CollectionTile(
                collection: c,
                library: widget.library,
                onTap: () => _openCollectionScreen(c),
                onLongPress: () => _showCollectionActions(c),
              );
            },
          ),
        ),
      const SliverPadding(
        padding: EdgeInsets.only(bottom: Burrow.fabClearance),
      ),
    ];
  }

  Future<void> _openAuthorScreen(String author) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AuthorScreen(author: author, library: widget.library),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _openCollectionScreen(db.Collection collection) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            CollectionScreen(collection: collection, library: widget.library),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _openSmartGroup(String group) async {
    List<Book> books;
    switch (group) {
      case 'Reading':
        books = widget.library.books
            .where((b) => b.isStarted && !b.isFinished)
            .toList();
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
              onSubmitted: (_) async {
                final name = controller.text.trim();
                if (name.isNotEmpty) {
                  await widget.library.createCollection(name);
                  if (sheetContext.mounted) Navigator.pop(sheetContext);
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
                        if (sheetContext.mounted) Navigator.pop(sheetContext);
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
            SheetAction(
              icon: Icons.edit_outlined,
              label: 'Rename',
              iconColor: scheme.onTertiaryContainer,
              iconBg: scheme.tertiaryContainer,
              onTap: () {
                Navigator.pop(sheetContext);
                _showRenameCollectionSheet(collection);
              },
            ),
            SheetAction(
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
              onSubmitted: (_) async {
                final name = controller.text.trim();
                if (name.isNotEmpty) {
                  await widget.library.renameCollection(collection.id, name);
                  if (sheetContext.mounted) Navigator.pop(sheetContext);
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
                        await widget.library.renameCollection(
                          collection.id,
                          name,
                        );
                        if (sheetContext.mounted) Navigator.pop(sheetContext);
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

  Widget _bookGrid(double width, List<Book> books) {
    const maxTileExtent = 300.0;
    const crossSpacing = 12.0;
    const mainSpacing = 14.0;
    const cardPadding = 6.0;
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
        return BookCard(
          book: book,
          onTap: () => _openBookInfo(book, heroTag: 'tile-${book.id}'),
          onLongPress: () => _showBookActions(book),
        );
      },
    );
  }

  Widget _bookList(List<Book> books) {
    return SliverList.builder(
      itemCount: books.length,
      itemBuilder: (context, i) {
        final book = books[i];
        return BookListCard(
          book: book,
          onTap: () => _openBookInfo(book, heroTag: 'tile-${book.id}'),
          onLongPress: () => _showBookActions(book),
        );
      },
    );
  }

  Widget _buildSearchOverlay(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final q = _query.trim().toLowerCase();
    final searchResults = q.isEmpty
        ? <Book>[]
        : widget.library.books.where((b) {
            return b.displayTitle.toLowerCase().contains(q) ||
                b.author.toLowerCase().contains(q);
          }).take(10).toList();

    return Positioned.fill(
      child: GestureDetector(
        onTap: () => setState(() {
          _searchOpen = false;
          _query = '';
          _searchController.clear();
        }),
        child: ColoredBox(
          color: scheme.scrim.withValues(alpha: 0.4),
          child: GestureDetector(
            onTap: () {},
            child: Column(
              children: [
                Material(
                  color: scheme.surface,
                  elevation: 2,
                  child: SafeArea(
                    bottom: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                      child: Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.arrow_back_rounded),
                            onPressed: () => setState(() {
                              _searchOpen = false;
                              _query = '';
                              _searchController.clear();
                            }),
                          ),
                          Expanded(
                            child: TextField(
                              controller: _searchController,
                              autofocus: true,
                              onChanged: (v) => setState(() => _query = v),
                              style: Theme.of(context).textTheme.bodyLarge,
                              decoration: InputDecoration(
                                hintText: 'Search your burrow',
                                suffixIcon: _query.isNotEmpty
                                    ? IconButton(
                                        icon: const Icon(Icons.close_rounded, size: 20),
                                        onPressed: () {
                                          _searchController.clear();
                                          setState(() => _query = '');
                                        },
                                      )
                                    : null,
                                filled: true,
                                fillColor: scheme.surfaceContainerHighest,
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                                border: InputBorder.none,
                                enabledBorder: InputBorder.none,
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: Burrow.r(Burrow.shapeLg),
                                  borderSide: BorderSide(color: scheme.primary, width: 2),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: ColoredBox(
                    color: scheme.surface,
                    child: searchResults.isEmpty
                        ? Center(
                            child: Text(
                              q.isEmpty ? 'Type to search' : 'No results found',
                              style: TextStyle(
                                color: scheme.onSurfaceVariant,
                                fontSize: 16,
                              ),
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            itemCount: searchResults.length,
                            itemBuilder: (context, i) {
                              final book = searchResults[i];
                              return ListTile(
                                leading: SizedBox(
                                  width: 36,
                                  height: 54,
                                  child: BookCover(book: book, borderRadius: 4, spine: false),
                                ),
                                title: Text(
                                  book.displayTitle,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: book.author.isEmpty
                                    ? null
                                    : Text(
                                        book.author,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                onTap: () {
                                  setState(() {
                                    _searchOpen = false;
                                    _query = '';
                                    _searchController.clear();
                                  });
                                  _openBookInfo(book);
                                },
                              );
                            },
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFab(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (_fabOpen) ...[
          FabMenuItem(
            icon: Icons.upload_file_outlined,
            label: 'Import file',
            scheme: scheme,
            delay: 0.0,
            onTap: () => _runFromFab(_pickFile),
          ),
          const SizedBox(height: 12),
          FabMenuItem(
            icon: switch (widget.library.settings.scanMode) {
              ScanMode.device => Icons.travel_explore_outlined,
              ScanMode.folder => Icons.folder_open_outlined,
              ScanMode.quick => Icons.refresh_rounded,
            },
            label: switch (widget.library.settings.scanMode) {
              ScanMode.device => 'Scan device',
              ScanMode.folder => 'Scan folder…',
              ScanMode.quick => 'Quick refresh',
            },
            scheme: scheme,
            delay: 0.12,
            onTap: () => _runFromFab(_scanPreferred),
          ),
          const SizedBox(height: 18),
        ],
        FloatingActionButton(
          onPressed: _busy ? null : () => setState(() => _fabOpen = !_fabOpen),
          tooltip: 'Add book',
          backgroundColor: _fabOpen ? scheme.secondaryContainer : null,
          foregroundColor: _fabOpen ? scheme.onSecondaryContainer : null,
          shape: RoundedRectangleBorder(borderRadius: Burrow.r(Burrow.shapeLg)),
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

/// Shows scan progress when a background scan (from onboarding) is running.
class _ScanningBanner extends StatelessWidget {
  const _ScanningBanner({required this.library});

  final LibraryService library;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final total = library.scanTotal;
    final imported = library.scanImported;
    final hasProgress = total > 0;

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(Burrow.shapeSm + 4),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: scheme.primary,
              value: hasProgress ? imported / total : null,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              hasProgress
                  ? 'Importing books… $imported / $total'
                  : 'Scanning for books…',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: scheme.onPrimaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
