import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart' show PdfOutlineNode;

import '../db/database.dart' as db;
import '../models/highlight_palette.dart';
import '../models/reader_settings.dart';
import '../models/document.dart';
import '../services/paginator.dart';

/// The Notes tab's data and callbacks.
class HighlightTab {
  const HighlightTab({
    required this.highlights,
    required this.onJump,
    required this.onNoteChanged,
    required this.onColorChanged,
    required this.onDelete,
    required this.onRestore,
    required this.locatorLabel,
    required this.canJump,
    required this.onExport,
  });

  final List<db.HighlightRow> highlights;
  final void Function(db.HighlightRow) onJump;
  final void Function(db.HighlightRow, String note) onNoteChanged;
  final void Function(db.HighlightRow, int color) onColorChanged;
  final void Function(db.HighlightRow) onDelete;
  final Future<db.HighlightRow?> Function(db.HighlightRow) onRestore;
  final String Function(db.HighlightRow) locatorLabel;
  final bool Function(db.HighlightRow) canJump;
  final VoidCallback onExport;
}

/// Bottom sheet with tabbed Contents | Bookmarks view.
/// Tapping a chapter jumps to it; tapping a bookmark jumps to its position.
abstract final class TocSheet {
  static Future<void> show(
    BuildContext context, {
    required ReaderSettings settings,
    required List<Chapter> chapters,
    required List<Paginator> paginators,
    List<bool>? readiness,
    required int currentIndex,
    required ValueChanged<int> onJump,
    required List<db.Bookmark> bookmarks,
    required ValueChanged<db.Bookmark> onDeleteBookmark,
    required HighlightTab highlightTab,
  }) {
    return showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _TocSheetContent(
        settings: settings,
        chapters: chapters,
        paginators: paginators,
        readiness: readiness,
        currentIndex: currentIndex,
        onJump: onJump,
        bookmarks: bookmarks,
        onDeleteBookmark: onDeleteBookmark,
        highlightTab: highlightTab,
      ),
    );
  }

  static Future<void> showPdf(
    BuildContext context, {
    required ReaderSettings settings,
    required List<PdfOutlineNode> outline,
    required int currentPage,
    required ValueChanged<int> onJump,
    required List<db.Bookmark> bookmarks,
    required ValueChanged<db.Bookmark> onDeleteBookmark,
    required HighlightTab highlightTab,
  }) {
    return showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _TocSheetContent.pdf(
        settings: settings,
        outline: outline,
        currentPage: currentPage,
        onJump: onJump,
        bookmarks: bookmarks,
        onDeleteBookmark: onDeleteBookmark,
        highlightTab: highlightTab,
      ),
    );
  }
}

class _TocSheetContent extends StatefulWidget {
  const _TocSheetContent({
    required this.settings,
    required this.chapters,
    required this.paginators,
    this.readiness,
    required this.currentIndex,
    required this.onJump,
    required this.bookmarks,
    required this.onDeleteBookmark,
    required this.highlightTab,
  }) : outline = const [],
       currentPage = 0,
       onJumpPdf = null,
       isPdf = false;

  const _TocSheetContent.pdf({
    required this.settings,
    required this.outline,
    required this.currentPage,
    required ValueChanged<int> onJump,
    required this.bookmarks,
    required this.onDeleteBookmark,
    required this.highlightTab,
  }) : chapters = const [],
       paginators = const [],
       readiness = null,
       currentIndex = 0,
       onJumpPdf = onJump,
       onJump = null,
       isPdf = true;

  final ReaderSettings settings;
  final List<Chapter> chapters;
  final List<Paginator> paginators;

  /// `true` for chapters whose paginator is a real layout; `null` means all
  /// entries are real. Chapters still being laid out show a `…` count.
  final List<bool>? readiness;
  final int currentIndex;
  final ValueChanged<int>? onJumpPdf;
  final bool isPdf;
  final List<PdfOutlineNode> outline;
  final int currentPage;
  final ValueChanged<int>? onJump;
  final List<db.Bookmark> bookmarks;
  final ValueChanged<db.Bookmark> onDeleteBookmark;
  final HighlightTab highlightTab;

  @override
  State<_TocSheetContent> createState() => _TocSheetContentState();
}

class _TocSheetContentState extends State<_TocSheetContent>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  late final ValueNotifier<int> _notesCount;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _notesCount = ValueNotifier(widget.highlightTab.highlights.length);
  }

  @override
  void dispose() {
    _notesCount.dispose();
    _tabController.dispose();
    super.dispose();
  }

  Widget _notesTab() => ValueListenableBuilder<int>(
    valueListenable: _notesCount,
    builder: (context, count, _) => Tab(text: 'Notes $count'),
  );

  @override
  Widget build(BuildContext context) {
    final theme = widget.settings.colors;

    // PDF mode: show outline + bookmarks.
    if (widget.isPdf) {
      return DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        builder: (context, scrollController) {
          return Container(
            decoration: BoxDecoration(
              color: theme.background,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(20),
              ),
            ),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 12, bottom: 8),
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: theme.muted.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                TabBar(
                  controller: _tabController,
                  labelColor: theme.accent,
                  unselectedLabelColor: theme.muted,
                  indicatorColor: theme.accent,
                  tabs: [
                    const Tab(text: 'Outline'),
                    const Tab(text: 'Bookmarks'),
                    _notesTab(),
                  ],
                ),
                const Divider(height: 1),
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      _PdfOutlineList(
                        outline: widget.outline,
                        currentPage: widget.currentPage,
                        theme: theme,
                        scrollController: scrollController,
                        onJump: (pageNumber) {
                          Navigator.of(context).pop();
                          widget.onJumpPdf?.call(pageNumber);
                        },
                      ),
                      _BookmarksList(
                        bookmarks: widget.bookmarks,
                        chapters: const [],
                        theme: theme,
                        scrollController: scrollController,
                        onJump: (pageNumber) {
                          Navigator.of(context).pop();
                          widget.onJumpPdf?.call(pageNumber);
                        },
                        onDelete: widget.onDeleteBookmark,
                      ),
                      _HighlightsList(
                        tab: widget.highlightTab,
                        count: _notesCount,
                        theme: theme,
                        scrollController: scrollController,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      );
    }

    // Reflowable mode: chapters + bookmarks.
    final titled = <(int index, Chapter chapter)>[];
    for (var i = 0; i < widget.chapters.length; i++) {
      if (widget.chapters[i].title.isNotEmpty) {
        titled.add((i, widget.chapters[i]));
      }
    }

    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: theme.background,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              // Drag handle.
              Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 8),
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: theme.muted.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              // Tab bar.
              TabBar(
                controller: _tabController,
                labelColor: theme.accent,
                unselectedLabelColor: theme.muted,
                indicatorColor: theme.accent,
                tabs: [
                  const Tab(text: 'Contents'),
                  const Tab(text: 'Bookmarks'),
                  _notesTab(),
                ],
              ),
              const Divider(height: 1),
              // Tab content.
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    // Contents tab.
                    _ContentsList(
                      titled: titled,
                      paginators: widget.paginators,
                      readiness: widget.readiness,
                      currentIndex: widget.currentIndex,
                      theme: theme,
                      scrollController: scrollController,
                      onJump: (chapterIndex) {
                        Navigator.of(context).pop();
                        widget.onJump?.call(chapterIndex);
                      },
                    ),
                    // Bookmarks tab.
                    _BookmarksList(
                      bookmarks: widget.bookmarks,
                      chapters: widget.chapters,
                      theme: theme,
                      scrollController: scrollController,
                      onJump: (chapterIndex) {
                        Navigator.of(context).pop();
                        widget.onJump?.call(chapterIndex);
                      },
                      onDelete: widget.onDeleteBookmark,
                    ),
                    _HighlightsList(
                      tab: widget.highlightTab,
                      count: _notesCount,
                      theme: theme,
                      scrollController: scrollController,
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _PdfOutlineList extends StatelessWidget {
  const _PdfOutlineList({
    required this.outline,
    required this.currentPage,
    required this.theme,
    required this.scrollController,
    required this.onJump,
  });

  final List<PdfOutlineNode> outline;
  final int currentPage;
  final ReaderTheme theme;
  final ScrollController scrollController;
  final ValueChanged<int> onJump;

  @override
  Widget build(BuildContext context) {
    if (outline.isEmpty) {
      return Center(
        child: Text(
          'No outline available',
          style: TextStyle(color: theme.muted, fontSize: 14),
        ),
      );
    }

    // Flatten the outline tree into a list of (title, pageNumber, depth).
    final items = <(String title, int pageNumber, int depth)>[];
    void flatten(List<PdfOutlineNode> nodes, int depth) {
      for (final node in nodes) {
        final pageNumber = node.dest?.pageNumber ?? 0;
        if (pageNumber > 0) {
          items.add((node.title, pageNumber, depth));
        }
        flatten(node.children, depth + 1);
      }
    }

    flatten(outline, 0);

    return ListView.builder(
      controller: scrollController,
      itemCount: items.length,
      itemBuilder: (context, i) {
        final (title, pageNumber, depth) = items[i];
        final isCurrent = pageNumber == currentPage;
        return InkWell(
          onTap: () => onJump(pageNumber),
          child: Container(
            padding: EdgeInsets.only(
              left: 20.0 + depth * 20,
              right: 20,
              top: 12,
              bottom: 12,
            ),
            color: isCurrent ? theme.accent.withValues(alpha: 0.12) : null,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w400,
                      color: isCurrent ? theme.accent : theme.text,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: Text(
                    'p. $pageNumber',
                    style: TextStyle(fontSize: 12, color: theme.muted),
                  ),
                ),
                if (isCurrent)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Icon(
                      Icons.arrow_forward_ios,
                      size: 14,
                      color: theme.accent,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ContentsList extends StatelessWidget {
  const _ContentsList({
    required this.titled,
    required this.paginators,
    this.readiness,
    required this.currentIndex,
    required this.theme,
    required this.scrollController,
    required this.onJump,
  });

  final List<(int index, Chapter chapter)> titled;
  final List<Paginator> paginators;
  final List<bool>? readiness;
  final int currentIndex;
  final ReaderTheme theme;
  final ScrollController scrollController;
  final ValueChanged<int> onJump;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: scrollController,
      itemCount: titled.length,
      itemBuilder: (context, i) {
        final (chapterIndex, chapter) = titled[i];
        final isCurrent = chapterIndex == currentIndex;
        final title = chapter.title;
        final ready =
            readiness == null ||
            (chapterIndex < readiness!.length && readiness![chapterIndex]);
        final pageCount = ready && chapterIndex < paginators.length
            ? paginators[chapterIndex].pages.length
            : 0;
        return InkWell(
          onTap: () => onJump(chapterIndex),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            color: isCurrent ? theme.accent.withValues(alpha: 0.12) : null,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w400,
                      color: isCurrent ? theme.accent : theme.text,
                    ),
                  ),
                ),
                if (ready && pageCount > 0)
                  Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: Text(
                      '$pageCount pages',
                      style: TextStyle(fontSize: 12, color: theme.muted),
                    ),
                  )
                else if (!ready)
                  Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: Text(
                      '…',
                      style: TextStyle(fontSize: 12, color: theme.muted),
                    ),
                  ),
                if (isCurrent)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Icon(
                      Icons.arrow_forward_ios,
                      size: 14,
                      color: theme.accent,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _BookmarksList extends StatelessWidget {
  const _BookmarksList({
    required this.bookmarks,
    required this.chapters,
    required this.theme,
    required this.scrollController,
    required this.onJump,
    required this.onDelete,
  });

  final List<db.Bookmark> bookmarks;
  final List<Chapter> chapters;
  final ReaderTheme theme;
  final ScrollController scrollController;
  final ValueChanged<int> onJump;
  final ValueChanged<db.Bookmark> onDelete;

  @override
  Widget build(BuildContext context) {
    if (bookmarks.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'No bookmarks yet.\nTap the bookmark icon in the reader to add one.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: theme.muted),
          ),
        ),
      );
    }

    return ListView.builder(
      controller: scrollController,
      itemCount: bookmarks.length,
      itemBuilder: (context, i) {
        final bm = bookmarks[i];
        final chapterTitle = bm.chapter < chapters.length
            ? chapters[bm.chapter].title
            : '';
        return Dismissible(
          key: ValueKey(bm.id),
          direction: DismissDirection.endToStart,
          background: Container(
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 20),
            color: Colors.red,
            child: const Icon(Icons.delete, color: Colors.white),
          ),
          onDismissed: (_) => onDelete(bm),
          child: InkWell(
            // No pop here: the onJump callbacks own the single pop (the same
            // contract as the contents and outline lists). Popping here as
            // well double-pops past the sheet onto the reader itself.
            onTap: () => onJump(bm.chapter),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (chapterTitle.isNotEmpty)
                    Text(
                      chapterTitle,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: theme.accent,
                      ),
                    ),
                  const SizedBox(height: 4),
                  Text(
                    bm.snippet,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14, color: theme.text),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _HighlightsList extends StatefulWidget {
  const _HighlightsList({
    required this.tab,
    required this.count,
    required this.theme,
    required this.scrollController,
  });

  final HighlightTab tab;
  final ValueNotifier<int> count;
  final ReaderTheme theme;
  final ScrollController scrollController;

  @override
  State<_HighlightsList> createState() => _HighlightsListState();
}

class _HighlightsListState extends State<_HighlightsList>
    with AutomaticKeepAliveClientMixin<_HighlightsList> {
  late List<db.HighlightRow> _items;
  db.HighlightRow? _lastDeleted;
  Timer? _undoTimer;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _items = _sorted(widget.tab.highlights);
    widget.count.value = _items.length;
  }

  @override
  void dispose() {
    _undoTimer?.cancel();
    super.dispose();
  }

  List<db.HighlightRow> _sorted(Iterable<db.HighlightRow> rows) {
    final list = List<db.HighlightRow>.of(rows);
    list.sort((a, b) {
      final page = (a.page ?? 0).compareTo(b.page ?? 0);
      if (page != 0) return page;
      final chapter = (a.chapter ?? 0).compareTo(b.chapter ?? 0);
      if (chapter != 0) return chapter;
      return (a.startOffset ?? 0).compareTo(b.startOffset ?? 0);
    });
    return list;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = widget.theme;
    if (_items.isEmpty) {
      return _frame(
        theme,
        Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'No highlights yet.',
                  style: TextStyle(
                    color: theme.text,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Select text while reading to keep a quote.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: theme.muted, fontSize: 13),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return _frame(
      theme,
      ListView.separated(
        controller: widget.scrollController,
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: _items.length,
        separatorBuilder: (_, _) =>
            Divider(height: 1, color: theme.muted.withValues(alpha: 0.15)),
        itemBuilder: (context, index) {
          final row = _items[index];
          final canJump = widget.tab.canJump(row);
          final locator = canJump
              ? widget.tab.locatorLabel(row)
              : 'Location unavailable';
          final color =
              kHighlightColors[row.color.clamp(0, kHighlightColorCount - 1)];

          return Material(
            color: Colors.transparent,
            child: ListTile(
              onTap: canJump ? () => widget.tab.onJump(row) : null,
              leading: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              title: Text(
                row.quote,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: theme.text, fontSize: 14),
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (row.note.trim().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        row.note,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: theme.muted, fontSize: 12),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '$locator · ${_date(row.createdAt)}',
                      style: TextStyle(color: theme.muted, fontSize: 11),
                    ),
                  ),
                ],
              ),
              trailing: PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert),
                onSelected: (value) {
                  switch (value) {
                    case 'edit':
                      _editNote(row);
                    case 'color':
                      _pickColor(row);
                    case 'delete':
                      _delete(row);
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('Edit note')),
                  PopupMenuItem(value: 'color', child: Text('Change colour')),
                  PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _editNote(db.HighlightRow row) async {
    final controller = TextEditingController(text: row.note);
    final note = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Edit note'),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 2,
          maxLines: 5,
          decoration: const InputDecoration(hintText: 'Your note'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (note == null || !mounted) return;

    widget.tab.onNoteChanged(row, note);
    setState(() {
      final index = _items.indexWhere((item) => item.id == row.id);
      if (index >= 0) _items[index] = _items[index].copyWith(note: note);
    });
  }

  Future<void> _pickColor(db.HighlightRow row) async {
    final selected = await showDialog<int>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Highlight colour'),
        children: [
          for (var i = 0; i < kHighlightColorCount; i++)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, i),
              child: Row(
                children: [
                  Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: kHighlightColors[i],
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Text(kHighlightColorNames[i])),
                  if (row.color == i) const Icon(Icons.check, size: 18),
                ],
              ),
            ),
        ],
      ),
    );
    if (selected == null || !mounted) return;

    widget.tab.onColorChanged(row, selected);
    setState(() {
      final index = _items.indexWhere((item) => item.id == row.id);
      if (index >= 0) _items[index] = _items[index].copyWith(color: selected);
    });
  }

  void _delete(db.HighlightRow row) {
    setState(() {
      _items.removeWhere((item) => item.id == row.id);
      _lastDeleted = row;
    });
    widget.count.value = _items.length;
    widget.tab.onDelete(row);

    _undoTimer?.cancel();
    _undoTimer = Timer(const Duration(seconds: 6), () {
      if (mounted && _lastDeleted?.id == row.id) {
        setState(() => _lastDeleted = null);
      }
    });
  }

  Widget _frame(ReaderTheme theme, Widget child) => Column(
    children: [
      Row(
        children: [
          const Spacer(),
          PopupMenuButton<String>(
            tooltip: 'Export highlights',
            icon: const Icon(Icons.ios_share),
            enabled: _items.isNotEmpty,
            onSelected: (_) => widget.tab.onExport(),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'export', child: Text('Export highlights')),
            ],
          ),
        ],
      ),
      if (_lastDeleted != null) _undoBanner(theme),
      Expanded(child: child),
    ],
  );

  Widget _undoBanner(ReaderTheme theme) => Material(
    color: theme.accent.withValues(alpha: 0.12),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Highlight deleted',
              style: TextStyle(color: theme.text, fontSize: 13),
            ),
          ),
          TextButton(onPressed: _undo, child: const Text('Undo')),
        ],
      ),
    ),
  );

  Future<void> _undo() async {
    final row = _lastDeleted;
    if (row == null) return;
    final restored = await widget.tab.onRestore(row);
    if (!mounted || restored == null) return;

    _undoTimer?.cancel();
    setState(() {
      _lastDeleted = null;
      _items = _sorted([..._items, restored]);
    });
    widget.count.value = _items.length;
  }

  String _date(int ms) => DateTime.fromMillisecondsSinceEpoch(
    ms,
  ).toIso8601String().split('T').first;
}
