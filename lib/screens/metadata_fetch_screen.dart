import 'dart:io';

import 'package:flutter/material.dart';

import '../models/book.dart';
import '../services/metadata_api_service.dart';
import '../utils/book_title.dart';

/// Screen for fetching book metadata from online APIs.
///
/// Shows auto-fetch results based on the book's existing data and allows
/// the user to search manually and pick the correct match.
class MetadataFetchScreen extends StatefulWidget {
  const MetadataFetchScreen({
    super.key,
    required this.book,
    required this.onSelected,
  });

  final Book book;

  /// Called when the user picks a metadata result.
  final ValueChanged<ApiBookMetadata> onSelected;

  @override
  State<MetadataFetchScreen> createState() => _MetadataFetchScreenState();
}

class _MetadataFetchScreenState extends State<MetadataFetchScreen> {
  final _searchCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  bool _loading = false;
  bool _autoFetched = false;
  List<ApiBookMetadata> _results = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _searchCtrl.text = widget.book.title;
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _autoFetch() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
      _results = [];
      _autoFetched = true;
    });

    final query = _buildAutoQuery();
    if (query == null) {
      setState(() {
        _loading = false;
        _error = 'No title or ISBN available to search with';
      });
      return;
    }

    try {
      final results = await MetadataApiService.search(query: query);
      if (!mounted) return;
      setState(() {
        _results = results;
        _loading = false;
        if (results.isEmpty) _error = 'No results found';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Search failed: $e';
      });
    }
  }

  Future<void> _manualSearch() async {
    final query = _searchCtrl.text.trim();
    if (query.isEmpty) return;
    if (_loading) return;

    setState(() {
      _loading = true;
      _error = null;
      _results = [];
    });

    try {
      final results = await MetadataApiService.search(query: query);
      if (!mounted) return;
      setState(() {
        _results = results;
        _loading = false;
        if (results.isEmpty) _error = 'No results found';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Search failed: $e';
      });
    }
  }

  String? _buildAutoQuery() {
    if (widget.book.isbn != null && widget.book.isbn!.isNotEmpty) {
      return widget.book.isbn;
    }
    if (widget.book.title.isNotEmpty) {
      return widget.book.title;
    }
    return null;
  }

  void _selectResult(ApiBookMetadata meta) {
    widget.onSelected(meta);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Fetch metadata'),
      ),
      body: Column(
        children: [
          // Book context header
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.3),
            child: Row(
              children: [
                SizedBox(
                  width: 36,
                  height: 54,
                  child: widget.book.coverPath != null
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: Image.file(
                            File(widget.book.coverPath!),
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => _MiniPlaceholder(
                              book: widget.book,
                            ),
                          ),
                        )
                      : _MiniPlaceholder(book: widget.book),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.book.displayTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (widget.book.author.isNotEmpty)
                        Text(
                          widget.book.author,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Search bar
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchCtrl,
                    decoration: InputDecoration(
                      hintText: 'Search by title or ISBN...',
                      prefixIcon: const Icon(Icons.search, size: 20),
                      border: const OutlineInputBorder(),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _manualSearch(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: _loading ? null : _manualSearch,
                  icon: _loading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.search, size: 20),
                ),
              ],
            ),
          ),

          // Auto-fetch button
          if (!_autoFetched)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _loading ? null : _autoFetch,
                  icon: const Icon(Icons.auto_fix_high, size: 18),
                  label: const Text('Auto-fetch from book data'),
                ),
              ),
            ),

          const SizedBox(height: 4),

          // Error
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.info_outline, size: 16, color: scheme.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _error!,
                      style: TextStyle(fontSize: 13, color: scheme.error),
                    ),
                  ),
                ],
              ),
            ),

          // Results count
          if (_results.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '${_results.length} result${_results.length == 1 ? '' : 's'}',
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),

          // Results list
          Expanded(
            child: _results.isEmpty
                ? Center(
                    child: _loading
                        ? const CircularProgressIndicator()
                        : Text(
                            _autoFetched
                                ? 'No results. Try a different search.'
                                : 'Search or auto-fetch to find metadata',
                            style: TextStyle(
                              color: scheme.onSurfaceVariant,
                              fontSize: 14,
                            ),
                          ),
                  )
                : ListView.separated(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    itemCount: _results.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final meta = _results[index];
                      return _ResultCard(
                        metadata: meta,
                        bookTitle: widget.book.title,
                        onTap: () => _selectResult(meta),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Result card
// ---------------------------------------------------------------------------

class _ResultCard extends StatelessWidget {
  const _ResultCard({
    required this.metadata,
    required this.bookTitle,
    required this.onTap,
  });

  final ApiBookMetadata metadata;
  final String bookTitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Row(
          children: [
            // Cover thumbnail
            SizedBox(
              width: 60,
              height: 90,
              child: metadata.coverUrl != null
                  ? Image.network(
                      metadata.coverUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => _CoverPlaceholder(
                        title: metadata.title ?? '',
                      ),
                    )
                  : _CoverPlaceholder(title: metadata.title ?? ''),
            ),
            const SizedBox(width: 12),
            // Info
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      metadata.title ?? 'Unknown title',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (metadata.author != null &&
                        metadata.author!.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        metadata.author!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        if (metadata.isbn != null && metadata.isbn!.isNotEmpty)
                          _MetaChip(
                            icon: Icons.qr_code,
                            label: metadata.isbn!,
                          ),
                        if (metadata.publisher != null &&
                            metadata.publisher!.isNotEmpty)
                          _MetaChip(
                            icon: Icons.business_outlined,
                            label: metadata.publisher!,
                          ),
                        if (metadata.publicationDate != null &&
                            metadata.publicationDate!.isNotEmpty)
                          _MetaChip(
                            icon: Icons.date_range_outlined,
                            label: metadata.publicationDate!,
                          ),
                        if (metadata.genre != null &&
                            metadata.genre!.isNotEmpty)
                          _MetaChip(
                            icon: Icons.category_outlined,
                            label: metadata.genre!.split(',').first.trim(),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: scheme.onSurfaceVariant),
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Placeholders
// ---------------------------------------------------------------------------

class _MiniPlaceholder extends StatelessWidget {
  const _MiniPlaceholder({required this.book});

  final Book book;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Center(
        child: Icon(
          Icons.menu_book_outlined,
          size: 16,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _CoverPlaceholder extends StatelessWidget {
  const _CoverPlaceholder({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final hue = (title.hashCode.abs() % 60) + 200;
    final bg = HSLColor.fromAHSL(1, hue.toDouble(), 0.3, 0.35).toColor();

    return Container(
      color: bg,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Text(
            title.isNotEmpty ? title[0].toUpperCase() : '?',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.9),
              fontSize: 22,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}
