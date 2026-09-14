import 'package:flutter/material.dart';

import '../models/book.dart';
import '../theme/burrow_tokens.dart';
import '../utils/book_title.dart';
import 'book_card.dart';
import 'book_cover.dart';
import 'progress_bar.dart';

enum StatusType { scanning, importing, extracting, completed }

class BusyState extends StatelessWidget {
  const BusyState();

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
            style: Theme.of(
              context,
            ).textTheme.bodyLarge?.copyWith(color: Theme.of(context).hintColor),
          ),
        ],
      ),
    );
  }
}

class NoResults extends StatelessWidget {
  const NoResults();

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
            child: Icon(
              Icons.search_off_rounded,
              size: 38,
              color: scheme.outline,
            ),
          ),
          const SizedBox(height: 18),
          Text(
            'Nothing matches',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            'Try another word or clear the filters.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).hintColor,
            ),
          ),
        ],
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({required this.onPickFile, required this.onScan});

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
              child: Icon(
                Icons.auto_stories_outlined,
                size: 46,
                color: scheme.onSecondaryContainer,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Your burrow is empty',
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            Text(
              'Import a file or scan your device\nfor EPUB, TXT and PDF books.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).hintColor,
              ),
            ),
            const SizedBox(height: 30),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                minimumSize: const Size(210, 54),
                shape: RoundedRectangleBorder(
                  borderRadius: Burrow.r(Burrow.shapeLg),
                ),
                textStyle: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
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

class EmptyTabState extends StatelessWidget {
  const EmptyTabState({
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
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
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

class StatusBanner extends StatelessWidget {
  const StatusBanner({
    required this.status,
    required this.completed,
    required this.total,
    this.bookTitle,
    this.result,
  });

  final StatusType status;
  final int completed;
  final int total;
  final String? bookTitle;
  final String? result;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = switch (status) {
      StatusType.scanning => 'Scanning for books…',
      StatusType.importing =>
        total > 0 ? 'Importing books… $completed / $total' : 'Importing books…',
      StatusType.extracting =>
        total > 0
            ? 'Extracting metadata… $completed / $total'
            : 'Extracting metadata…',
      StatusType.completed => result ?? 'Done',
    };

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(
          top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.3)),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 18,
                  height: 18,
                  child: status == StatusType.completed
                      ? Icon(
                          Icons.check_circle_rounded,
                          size: 18,
                          color: scheme.primary,
                        )
                      : CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: scheme.primary,
                          value: (status != StatusType.scanning && total > 0)
                              ? completed / total
                              : null,
                        ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        text,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurface,
                        ),
                      ),
                      if (bookTitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          bookTitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            if (total > 0 && status != StatusType.scanning) ...[
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: Burrow.r(Burrow.shapeXs),
                child: LinearProgressIndicator(
                  value: completed / total,
                  minHeight: 4,
                  backgroundColor: scheme.primaryContainer,
                  color: scheme.primary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class ContinueCard extends StatelessWidget {
  const ContinueCard({required this.book, required this.onTap});

  final Book book;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final onCard = scheme.onPrimaryContainer;
    return Semantics(
      button: true,
      label: 'Continue reading ${book.displayTitle}. ${book.progressSemantics}',
      excludeSemantics: true,
      child: PressableScale(
        child: DecoratedBox(
          decoration: BoxDecoration(borderRadius: Burrow.r(Burrow.shapeSm)),
          child: Material(
            color: scheme.primaryContainer,
            shape: RoundedSuperellipseBorder(
              borderRadius: Burrow.r(Burrow.shapeSm),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: SizedBox(
                  height: 150,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      AspectRatio(
                        aspectRatio: Burrow.coverAspectRatio,
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
                                Icon(
                                  Icons.auto_stories_rounded,
                                  size: 15,
                                  color: onCard.withValues(alpha: 0.8),
                                ),
                                const SizedBox(width: 6),
                                Flexible(
                                  child: Text(
                                    'CONTINUE READING',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.labelSmall
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
                              style: Theme.of(context).textTheme.titleLarge
                                  ?.copyWith(
                                    fontWeight: FontWeight.w800,
                                    color: onCard,
                                  ),
                            ),
                            if (book.author.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(
                                  book.author,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: onCard.withValues(alpha: 0.75),
                                      ),
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
                                child: Icon(
                                  Icons.play_arrow_rounded,
                                  size: 24,
                                  color: onCard,
                                ),
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
      ),
    );
  }
}
