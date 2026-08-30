import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart' show PdfOutlineNode;

import '../db/database.dart' as db;
import '../models/reader_settings.dart';
import '../services/document_parser.dart';
import '../services/paginator.dart';

/// Bottom sheet with tabbed Contents | Bookmarks view.
/// Tapping a chapter jumps to it; tapping a bookmark jumps to its position.
abstract final class TocSheet {
  static Future<void> show(
    BuildContext context, {
    required ReaderSettings settings,
    required List<Chapter> chapters,
    required List<Paginator> paginators,
    required int currentIndex,
    required ValueChanged<int> onJump,
    required List<db.Bookmark> bookmarks,
    required ValueChanged<db.Bookmark> onDeleteBookmark,
  }) {
    return showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _TocSheetContent(
        settings: settings,
        chapters: chapters,
        paginators: paginators,
        currentIndex: currentIndex,
        onJump: onJump,
        bookmarks: bookmarks,
        onDeleteBookmark: onDeleteBookmark,
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
      ),
    );
  }
}

class _TocSheetContent extends StatefulWidget {
  const _TocSheetContent({
    required this.settings,
    required this.chapters,
    required this.paginators,
    required this.currentIndex,
    required this.onJump,
    required this.bookmarks,
    required this.onDeleteBookmark,
  })  : outline = const [],
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
  })  : chapters = const [],
        paginators = const [],
        currentIndex = 0,
        onJumpPdf = onJump,
        onJump = null,
        isPdf = true;

  final ReaderSettings settings;
  final List<Chapter> chapters;
  final List<Paginator> paginators;
  final int currentIndex;
  final ValueChanged<int>? onJumpPdf;
  final bool isPdf;
  final List<PdfOutlineNode> outline;
  final int currentPage;
  final ValueChanged<int>? onJump;
  final List<db.Bookmark> bookmarks;
  final ValueChanged<db.Bookmark> onDeleteBookmark;

  @override
  State<_TocSheetContent> createState() => _TocSheetContentState();
}

class _TocSheetContentState extends State<_TocSheetContent>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

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
                  tabs: const [
                    Tab(text: 'Outline'),
                    Tab(text: 'Bookmarks'),
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
                        onJump: (_) {},
                        onDelete: widget.onDeleteBookmark,
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
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(20),
            ),
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
                tabs: const [
                  Tab(text: 'Contents'),
                  Tab(text: 'Bookmarks'),
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
                      fontWeight:
                          isCurrent ? FontWeight.w600 : FontWeight.w400,
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
    required this.currentIndex,
    required this.theme,
    required this.scrollController,
    required this.onJump,
  });

  final List<(int index, Chapter chapter)> titled;
  final List<Paginator> paginators;
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
        final pageCount = chapterIndex < paginators.length
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
                      fontWeight:
                          isCurrent ? FontWeight.w600 : FontWeight.w400,
                      color: isCurrent ? theme.accent : theme.text,
                    ),
                  ),
                ),
                if (pageCount > 0)
                  Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: Text(
                      '$pageCount pages',
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
            onTap: () {
              Navigator.of(context).pop();
              onJump(bm.chapter);
            },
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
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
