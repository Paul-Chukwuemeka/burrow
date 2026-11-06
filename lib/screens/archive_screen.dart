import 'package:flutter/material.dart';

import '../controllers/book_selection.dart';
import '../models/book.dart';
import '../models/library_enums.dart';
import '../services/library_service.dart';
import '../theme/burrow_tokens.dart';
import '../utils/book_title.dart';
import '../widgets/book_card.dart';
import '../widgets/book_cover.dart';

/// Lists one archive tier and offers restore, move and permanent-delete actions.
///
/// [ArchiveTier.hidden] is only reached after the PIN gate in the library
/// header; this screen does not prompt again.
class ArchiveScreen extends StatefulWidget {
  const ArchiveScreen({
    super.key,
    required this.library,
    required this.tier,
  });

  final LibraryService library;
  final ArchiveTier tier;

  static Future<void> show(
    BuildContext context, {
    required LibraryService library,
    required ArchiveTier tier,
  }) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ArchiveScreen(library: library, tier: tier),
      ),
    );
  }

  @override
  State<ArchiveScreen> createState() => _ArchiveScreenState();
}

class _ArchiveScreenState extends State<ArchiveScreen> {
  final _selection = BookSelection();

  bool get _isHidden => widget.tier == ArchiveTier.hidden;

  String get _title => _isHidden ? 'Hidden archive' : 'Archive';

  List<Book> get _books => _isHidden
      ? widget.library.hiddenArchiveBooks
      : widget.library.archivedBooks;

  @override
  void initState() {
    super.initState();
    _selection.addListener(_onSelectionChanged);
  }

  @override
  void dispose() {
    _selection
      ..removeListener(_onSelectionChanged)
      ..dispose();
    super.dispose();
  }

  void _onSelectionChanged() {
    if (mounted) setState(() {});
  }

  List<Book> get _selectedBooks {
    final ids = _selection.selectedIds;
    return _books.where((b) => ids.contains(b.id)).toList();
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _restore(Iterable<String> ids) async {
    final count = await widget.library.restoreBooks(ids);
    _selection.clear();
    if (!mounted) return;
    setState(() {});
    _snack(
      count == 1
          ? 'Restored 1 book'
          : 'Restored $count books',
    );
  }

  Future<void> _move(Iterable<String> ids) async {
    final target = _isHidden ? ArchiveTier.archive : ArchiveTier.hidden;
    final count = await widget.library.moveArchiveBooks(ids, target);
    _selection.clear();
    if (!mounted) return;
    setState(() {});
    final label = target == ArchiveTier.hidden ? 'hidden archive' : 'archive';
    _snack(count == 1 ? 'Moved 1 book to $label' : 'Moved $count books to $label');
  }

  Future<void> _delete(Iterable<String> ids) async {
    final list = ids.toList();
    if (list.isEmpty) return;
    var deleteFile = false;
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (dialogContext) => StatefulBuilder(
            builder: (context, setDialogState) => AlertDialog(
              title: Text(
                list.length == 1
                    ? 'Delete this book permanently?'
                    : 'Delete ${list.length} books permanently?',
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'The book will be removed from the archive. This cannot be '
                    'undone.',
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: deleteFile,
                    onChanged: (v) =>
                        setDialogState(() => deleteFile = v ?? false),
                    title: const Text('Also delete files from disk'),
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                    foregroundColor: Theme.of(context).colorScheme.onError,
                  ),
                  child: const Text('Delete'),
                ),
              ],
            ),
          ),
        ) ??
        false;
    if (!confirmed) return;
    final (deleted, errors) = await widget.library.deleteBooks(
      list,
      deleteFile: deleteFile,
    );
    _selection.clear();
    if (!mounted) return;
    setState(() {});
    if (errors.isNotEmpty) {
      _snack('Deleted $deleted; ${errors.length} failed');
    } else {
      _snack(deleted == 1 ? 'Deleted 1 book' : 'Deleted $deleted books');
    }
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
                width: 42,
                height: 63,
                child: BookCover(book: book, borderRadius: 8, spine: false),
              ),
              title: Text(
                book.displayTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: book.author.isEmpty ? null : Text(book.author),
            ),
            _ArchiveAction(
              icon: Icons.restore_rounded,
              label: 'Restore',
              onTap: () {
                Navigator.pop(sheetContext);
                _restore([book.id]);
              },
            ),
            _ArchiveAction(
              icon: Icons.swap_horiz_rounded,
              label: _isHidden ? 'Move to archive' : 'Move to hidden archive',
              onTap: () {
                Navigator.pop(sheetContext);
                _move([book.id]);
              },
            ),
            _ArchiveAction(
              icon: Icons.delete_outline_rounded,
              label: 'Delete permanently',
              color: scheme.error,
              iconColor: scheme.error,
              iconBg: scheme.errorContainer,
              onTap: () {
                Navigator.pop(sheetContext);
                _delete([book.id]);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final books = _books;
    return Scaffold(
      appBar: AppBar(
        leading: _selection.isSelecting
            ? IconButton(
                icon: const Icon(Icons.close_rounded),
                tooltip: 'Clear selection',
                onPressed: _selection.clear,
              )
            : null,
        title: Text(
          _selection.isSelecting ? '${_selection.count} selected' : _title,
        ),
        actions: [
          if (_selection.isSelecting) ...[
            IconButton(
              icon: const Icon(Icons.select_all_rounded),
              tooltip: 'Select all',
              onPressed: () =>
                  _selection.selectAll(books.map((b) => b.id)),
            ),
            IconButton(
              icon: const Icon(Icons.restore_rounded),
              tooltip: 'Restore',
              onPressed: () => _restore(_selection.selectedIds),
            ),
            IconButton(
              icon: const Icon(Icons.swap_horiz_rounded),
              tooltip: _isHidden ? 'Move to archive' : 'Move to hidden archive',
              onPressed: () => _move(_selection.selectedIds),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded),
              tooltip: 'Delete permanently',
              onPressed: () => _delete(_selection.selectedIds),
            ),
          ],
        ],
      ),
      body: books.isEmpty
          ? _EmptyArchive(isHidden: _isHidden)
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(
                20,
                8,
                20,
                Burrow.fabClearance,
              ),
              itemCount: books.length,
              itemBuilder: (context, index) {
                final book = books[index];
                return BookListCard(
                  book: book,
                  selected: _selection.selectedIds.contains(book.id),
                  onTap: () {
                    if (_selection.isSelecting) {
                      _selection.toggle(book.id);
                    } else {
                      _showBookActions(book);
                    }
                  },
                  onLongPress: () {
                    if (_selection.isSelecting) {
                      _selection.toggle(book.id);
                    } else {
                      _selection.enter(book.id);
                    }
                  },
                );
              },
            ),
    );
  }
}

class _ArchiveAction extends StatelessWidget {
  const _ArchiveAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
    this.iconColor,
    this.iconBg,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;
  final Color? iconColor;
  final Color? iconBg;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 24),
      leading: CircleAvatar(
        backgroundColor: iconBg ?? scheme.surfaceContainerHighest,
        child: Icon(icon, color: iconColor ?? scheme.onSurfaceVariant),
      ),
      title: Text(label, style: TextStyle(color: color)),
      onTap: onTap,
    );
  }
}

class _EmptyArchive extends StatelessWidget {
  const _EmptyArchive({required this.isHidden});

  final bool isHidden;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isHidden ? Icons.lock_outline_rounded : Icons.archive_outlined,
            size: 48,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text(
            isHidden ? 'Hidden archive is empty' : 'No archived books',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            'Long-press a book in the library to select and archive it.',
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
