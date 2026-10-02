import 'package:flutter/material.dart';

import '../models/book.dart';
import '../theme/burrow_tokens.dart';
import '../utils/book_title.dart';
import 'book_cover.dart';
import 'progress_bar.dart';

/// Grid card for a single book. Mirrors the library screen's `_BookTile`.
class BookCard extends StatelessWidget {
  const BookCard({
    super.key,
    required this.book,
    required this.onTap,
    this.onLongPress,
    this.subtitle,
    this.selected = false,
  });

  final Book book;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// Whether the card shows the multi-select checkbox overlay.
  final bool selected;

  /// Optional override for the text below the title (e.g. "#3" for series).
  final String? subtitle;

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
        child: PressableScale(
          child: DecoratedBox(
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(6)),
            child: Material(
              color: scheme.surfaceContainerLow,
              shape: RoundedSuperellipseBorder(
                borderRadius: BorderRadius.circular(6),
                side: BorderSide(
                  color: scheme.outlineVariant.withValues(alpha: 0.5),
                ),
              ),
              clipBehavior: Clip.hardEdge,
              child: InkWell(
                onTap: onTap,
                onLongPress: onLongPress,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: _CoverArea(book: book, selected: selected)),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(6, 6, 6, 4),
                      child: MediaQuery(
                        data: MediaQuery.of(
                          context,
                        ).copyWith(textScaler: TextScaler.noScaling),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
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
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: scheme.onSurfaceVariant,
                                        fontSize: 11,
                                      ),
                                ),
                              ),
                            const SizedBox(height: 2),
                            SizedBox(
                              height: 13,
                              child: subtitle != null
                                  ? _SubtitleLine(text: subtitle!)
                                  : _StatusLine(book: book),
                            ),
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
    );
  }
}

/// Horizontal list row for a single book. Used in list layout mode.
class BookListCard extends StatelessWidget {
  const BookListCard({
    super.key,
    required this.book,
    required this.onTap,
    this.onLongPress,
    this.selected = false,
  });

  final Book book;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// Whether the card shows the multi-select checkbox overlay.
  final bool selected;

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

    final formatLabel = book.format.name.toUpperCase();

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        button: true,
        label:
            '${book.displayTitle}${book.author.isEmpty ? '' : ' by ${book.author}'}. ${book.progressSemantics}',
        hint: 'Double tap to read; long press for options',
        excludeSemantics: true,
        child: PressableScale(
          child: DecoratedBox(
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(6)),
            child: Material(
              color: scheme.surfaceContainerLow,
              shape: RoundedSuperellipseBorder(
                borderRadius: BorderRadius.circular(6),
                side: BorderSide(
                  color: scheme.outlineVariant.withValues(alpha: 0.5),
                ),
              ),
              clipBehavior: Clip.hardEdge,
              child: InkWell(
                onTap: onTap,
                onLongPress: onLongPress,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 88,
                        height: 132,
                        child: _CoverArea(
                          book: book,
                          showProgress: false,
                          selected: selected,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: SizedBox(
                          height: 132,
                          child: MediaQuery(
                            data: MediaQuery.of(
                              context,
                            ).copyWith(textScaler: TextScaler.noScaling),
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
                                    Text(formatLabel, style: metaStyle),
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

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

class _CoverArea extends StatelessWidget {
  const _CoverArea({
    required this.book,
    this.showProgress = true,
    this.selected = false,
  });

  final Book book;
  final bool showProgress;
  final bool selected;

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
          child: BookCover(book: book, borderRadius: 4),
        ),
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
        if (selected)
          Positioned(
            top: 8,
            left: 8,
            child: Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: scheme.onPrimaryContainer.withValues(alpha: 0.35),
                ),
              ),
              child: Icon(
                Icons.check_box_rounded,
                size: 18,
                color: scheme.onPrimaryContainer,
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 3,
                  ),
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
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
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

    if (!book.isStarted) return const SizedBox.shrink();
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

class _SubtitleLine extends StatelessWidget {
  const _SubtitleLine({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: scheme.primary,
      fontWeight: FontWeight.w700,
      height: 1,
    );
    return Row(
      children: [
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
      ],
    );
  }
}

/// Press-to-scale animation wrapper. Shrinks to 96 % on pointer-down and
/// springs back on release.
class PressableScale extends StatefulWidget {
  const PressableScale({super.key, required this.child});

  final Widget child;

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> {
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
