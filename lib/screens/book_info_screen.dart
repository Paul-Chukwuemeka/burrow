import 'dart:io';

import 'package:flutter/material.dart';

import '../db/database.dart' as db;
import '../models/book.dart';
import '../services/library_service.dart';
import '../services/metadata_api_service.dart';
import '../theme/burrow_tokens.dart';
import '../utils/book_title.dart';
import '../utils/date_format.dart';
import '../widgets/book_cover.dart';
import '../widgets/progress_bar.dart';
import 'edit_book_screen.dart';
import 'genre_screen.dart';
import 'metadata_fetch_screen.dart';
import 'reader_screen.dart';
import 'series_screen.dart';

/// Full-screen document info shown when the user taps a book in the library.
class BookInfoScreen extends StatefulWidget {
  const BookInfoScreen({
    super.key,
    required this.book,
    required this.library,
    this.heroTag,
  });

  final Book book;
  final LibraryService library;
  final String? heroTag;

  @override
  State<BookInfoScreen> createState() => _BookInfoScreenState();
}

class _BookInfoScreenState extends State<BookInfoScreen> {
  List<db.Collection> _collections = [];

  @override
  void initState() {
    super.initState();
    _loadCollections();
  }

  Future<void> _loadCollections() async {
    final collections = await widget.library.getCollectionsForBook(
      widget.book.id,
    );
    if (!mounted) return;
    setState(() => _collections = collections);
  }

  Future<void> _fetchOnlineMetadata() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MetadataFetchScreen(
          book: widget.book,
          onSelected: (meta) => _applyMetadata(meta),
        ),
      ),
    );
  }

  Future<void> _applyMetadata(ApiBookMetadata result) async {
    try {
      final book = widget.book;

      await widget.library.updateBook(
        book.id,
        title: result.title,
        author: result.author,
        description: result.description,
        genre: result.genre,
        seriesName: result.seriesName,
        seriesIndex: result.seriesIndex,
        publisher: result.publisher,
        isbn: result.isbn,
        language: result.language,
        publicationDate: result.publicationDate,
      );

      if (result.coverUrl != null) {
        final bytes = await MetadataApiService.downloadCover(result.coverUrl!);
        if (bytes != null && bytes.isNotEmpty && mounted) {
          await widget.library.setCoverIfMissing(book, bytes);
        }
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Metadata applied')),
      );
      setState(() {}      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to apply metadata: $e')),
      );
    }
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final book = widget.book;
    final library = widget.library;
    final file = File(book.path);
    final fileSize = file.existsSync()
        ? _formatFileSize(file.lengthSync())
        : 'Unknown';
    final added = formatDate(book.addedAt);
    final lastRead = book.lastReadAt > 0 ? formatDate(book.lastReadAt) : null;
    final pubDate =
        book.publicationDate != null && book.publicationDate!.isNotEmpty
        ? formatPublicationDate(book.publicationDate!)
        : '';

    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: CustomScrollView(
              slivers: [
                SliverAppBar(
                  expandedHeight: 320,
                  pinned: true,
                  surfaceTintColor: Colors.transparent,
                  leading: IconButton(
                    icon: const Icon(Icons.arrow_back_rounded),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  actions: [
                    IconButton(
                      icon: const Icon(Icons.cloud_download_outlined),
                      onPressed: _fetchOnlineMetadata,
                      tooltip: 'Fetch metadata online',
                    ),
                    IconButton(
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                EditBookScreen(book: book, library: library),
                          ),
                        );
                        if (context.mounted) setState(() {});
                      },
                      tooltip: 'Edit metadata',
                    ),
                  ],
                  flexibleSpace: FlexibleSpaceBar(
                    background: Center(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 40),
                        child: SizedBox(
                          width: 160,
                          child: widget.heroTag != null
                              ? Hero(
                                  tag: widget.heroTag!,
                                  child: BookCover(
                                    book: book,
                                    borderRadius: 12,
                                  ),
                                )
                              : BookCover(book: book, borderRadius: 12),
                        ),
                      ),
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          book.displayTitle,
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            height: 1.2,
                          ),
                        ),
                        if (book.author.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            book.author,
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                        // Series chip.
                        if (book.seriesName != null &&
                            book.seriesName!.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          _SeriesChip(
                            book: book,
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => SeriesScreen(
                                  series: book.seriesName!,
                                  library: widget.library,
                                ),
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: 20),
                        // Format badge + progress chip row.
                        Row(
                          children: [
                            _FormatBadge(format: book.format),
                            const SizedBox(width: 10),
                            _ProgressChip(book: book),
                          ],
                        ),
                        const SizedBox(height: 20),
                        if (book.isStarted && book.progress > 0) ...[
                          ClipRRect(
                            borderRadius: Burrow.r(Burrow.shapeXs),
                            child: SegmentedProgressBar(
                              value: book.progress,
                              track: scheme.primaryContainer,
                              fill: scheme.primary,
                              height: 6,
                            ),
                          ),
                          const SizedBox(height: 20),
                        ],
                        // Description.
                        if (book.description != null &&
                            book.description!.isNotEmpty) ...[
                          _ExpandableText(
                            label: 'Description',
                            text: book.description!,
                          ),
                          const SizedBox(height: 16),
                        ],
                        // Annotation (only if different from description).
                        if (book.annotation != null &&
                            book.annotation!.isNotEmpty &&
                            book.annotation != book.description) ...[
                          _ExpandableText(
                            label: 'Annotation',
                            text: book.annotation!,
                          ),
                          const SizedBox(height: 16),
                        ],
                        // Publication info.
                        if (book.publisher != null &&
                            book.publisher!.isNotEmpty)
                          _InfoRow(
                            icon: Icons.business_outlined,
                            label: 'Publisher',
                            value: book.publisher!,
                          ),
                        if (pubDate.isNotEmpty)
                          _InfoRow(
                            icon: Icons.date_range_outlined,
                            label: 'Published',
                            value: pubDate,
                          ),
                        if (book.language != null && book.language!.isNotEmpty)
                          _InfoRow(
                            icon: Icons.language_outlined,
                            label: 'Language',
                            value: book.language!,
                          ),
                        // Genre chips.
                        if (book.genre != null && book.genre!.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Icon(
                                Icons.category_outlined,
                                size: 18,
                                color: scheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: 12),
                              Text(
                                'Genres',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final g
                                  in book.genre!
                                      .split(',')
                                      .map((s) => s.trim())
                                      .where((s) => s.isNotEmpty))
                                InkWell(
                                  onTap: () => Navigator.of(context).push(
                                    MaterialPageRoute<void>(
                                      builder: (_) => GenreScreen(
                                        genre: g,
                                        library: widget.library,
                                      ),
                                    ),
                                  ),
                                  borderRadius: BorderRadius.circular(8),
                                  child: Chip(
                                    label: Text(g),
                                    backgroundColor: scheme.tertiaryContainer,
                                    labelStyle: TextStyle(
                                      color: scheme.onTertiaryContainer,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                    materialTapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                    visualDensity: VisualDensity.compact,
                                  ),
                                ),
                            ],
                          ),
                        ],
                        // Metadata rows.
                        _InfoRow(
                          icon: Icons.folder_outlined,
                          label: 'File size',
                          value: fileSize,
                        ),
                        _InfoRow(
                          icon: Icons.calendar_today_outlined,
                          label: 'Added',
                          value: added,
                        ),
                        if (lastRead != null)
                          _InfoRow(
                            icon: Icons.schedule_rounded,
                            label: 'Last read',
                            value: lastRead,
                          ),
                        // Details sub-section.
                        if (book.isbn != null && book.isbn!.isNotEmpty ||
                            book.type != null && book.type!.isNotEmpty ||
                            book.rights != null && book.rights!.isNotEmpty ||
                            book.source != null && book.source!.isNotEmpty) ...[
                          const SizedBox(height: 16),
                          Text(
                            'Details',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 4),
                          if (book.isbn != null && book.isbn!.isNotEmpty)
                            _InfoRow(
                              icon: Icons.qr_code_outlined,
                              label: 'ISBN',
                              value: book.isbn!,
                            ),
                          if (book.type != null && book.type!.isNotEmpty)
                            _InfoRow(
                              icon: Icons.label_outlined,
                              label: 'Type',
                              value: book.type!,
                            ),
                          if (book.rights != null && book.rights!.isNotEmpty)
                            _InfoRow(
                              icon: Icons.gavel_outlined,
                              label: 'Rights',
                              value: book.rights!,
                              maxLines: 2,
                            ),
                          if (book.source != null && book.source!.isNotEmpty)
                            _InfoRow(
                              icon: Icons.link_outlined,
                              label: 'Source',
                              value: book.source!,
                              maxLines: 2,
                            ),
                        ],
                        _InfoRow(
                          icon: Icons.insert_drive_file_outlined,
                          label: 'Path',
                          value: book.path,
                          maxLines: 2,
                        ),
                        // Collections section.
                        if (_collections.isNotEmpty) ...[
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              Icon(
                                Icons.collections_bookmark_outlined,
                                size: 18,
                                color: scheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: 12),
                              Text(
                                'Collections',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final c in _collections)
                                Chip(
                                  label: Text(c.name),
                                  backgroundColor: scheme.secondaryContainer,
                                  labelStyle: TextStyle(
                                    color: scheme.onSecondaryContainer,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  materialTapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  visualDensity: VisualDensity.compact,
                                ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 24),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Fixed Read button at bottom.
          Container(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
            decoration: BoxDecoration(
              color: scheme.surface,
              border: Border(
                top: BorderSide(
                  color: scheme.outlineVariant.withValues(alpha: 0.3),
                ),
              ),
            ),
            child: SafeArea(
              top: false,
              child: SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton.icon(
                  onPressed: () async {
                    if (!await File(book.path).exists()) {
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            '"${book.displayTitle}" is no longer on this device',
                          ),
                        ),
                      );
                      return;
                    }
                    if (!context.mounted) return;
                    await Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => ReaderScreen(
                          book: book,
                          library: library,
                          heroTag: widget.heroTag,
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.menu_book_outlined, size: 22),
                  label: Text(book.isStarted ? 'Continue' : 'Read'),
                  style: FilledButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: Burrow.r(Burrow.shapeSm),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FormatBadge extends StatelessWidget {
  const _FormatBadge({required this.format});

  final BookFormat format;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (bg, fg) = Burrow.formatTonal(scheme, format);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: Burrow.r(Burrow.shapeXs),
      ),
      child: Text(
        format.name.toUpperCase(),
        style: TextStyle(
          color: fg,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class _ProgressChip extends StatelessWidget {
  const _ProgressChip({required this.book});

  final Book book;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = book.progressLabel;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: Burrow.r(Burrow.shapeXs),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: scheme.onSurfaceVariant,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
    this.maxLines = 1,
  });

  final IconData icon;
  final String label;
  final String value;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 12),
          SizedBox(
            width: 90,
            child: Text(
              label,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: maxLines,
              overflow: maxLines > 1 ? null : TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: scheme.onSurface),
            ),
          ),
        ],
      ),
    );
  }
}

class _SeriesChip extends StatelessWidget {
  const _SeriesChip({required this.book, required this.onTap});

  final Book book;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = book.seriesIndex != null
        ? '${book.seriesName} #${book.seriesIndex}'
        : book.seriesName!;
    return InkWell(
      onTap: onTap,
      borderRadius: Burrow.r(Burrow.shapeXs),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: scheme.primaryContainer,
          borderRadius: Burrow.r(Burrow.shapeXs),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: scheme.onPrimaryContainer,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _ExpandableText extends StatefulWidget {
  const _ExpandableText({required this.label, required this.text});

  final String label;
  final String text;

  @override
  State<_ExpandableText> createState() => _ExpandableTextState();
}

class _ExpandableTextState extends State<_ExpandableText> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        GestureDetector(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Text(
            widget.text,
            maxLines: _expanded ? null : 4,
            overflow: _expanded ? null : TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              color: scheme.onSurface,
              height: 1.5,
            ),
          ),
        ),
      ],
    );
  }
}
