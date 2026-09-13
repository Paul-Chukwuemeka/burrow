import 'dart:io';

import 'package:flutter/material.dart';

import '../models/book.dart';
import '../utils/book_title.dart';

/// Cover image for a book: extracted artwork if available, otherwise a
/// designed placeholder — wrapped title, per-format textured gradient and a
/// small format icon — that reads as a book, not an error state.
///
/// All covers render at a strict 2:3 portrait ratio so grids stay aligned;
/// real artwork is center-cropped ([BoxFit.cover]) into that frame.
class BookCover extends StatelessWidget {
  const BookCover({
    super.key,
    required this.book,
    this.borderRadius = 12,
    this.spine = true,
    this.enforceAspect = true,
  });

  final Book book;
  final double borderRadius;

  /// Soft "spine" shade on the leading edge so covers read as objects.
  final bool spine;

  /// Force the 2:3 book frame regardless of parent constraints.
  final bool enforceAspect;

  @override
  Widget build(BuildContext context) {
    Widget content = Stack(
      fit: StackFit.expand,
      children: [
        if (book.coverPath != null)
          Image.file(
            File(book.coverPath!),
            fit: BoxFit.cover,
            gaplessPlayback: true,
            cacheWidth: 300,
            cacheHeight: 450,
            errorBuilder: (_, _, _) => _PlaceholderCover(book: book),
          )
        else
          _PlaceholderCover(book: book),
        if (spine)
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [Color(0x59000000), Color(0x00000000)],
                stops: [0, 0.14],
              ),
            ),
          ),
        DecoratedBox(
          decoration: ShapeDecoration(
            shape: RoundedSuperellipseBorder(
              side: BorderSide(color: Colors.black.withValues(alpha: 0.08)),
              borderRadius: BorderRadius.circular(borderRadius),
            ),
          ),
        ),
      ],
    );

    if (enforceAspect) {
      content = AspectRatio(aspectRatio: 2 / 3, child: content);
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: content,
    );
  }
}

// ---------------------------------------------------------------------------
// Placeholder design
// ---------------------------------------------------------------------------

/// Warm, earthy hue bands keyed to the file format so shelves read coherently:
/// EPUBs sit in forest green, TXT notes in ochre, PDFs in clay red.
const _formatPalettes = <BookFormat, List<double>>{
  BookFormat.epub: [96, 152], // greens
  BookFormat.txt: [26, 46], // ambers / ochres
  BookFormat.pdf: [4, 22], // clays / rusts
  BookFormat.cbz: [270, 300], // purples / violets
  BookFormat.cbr: [270, 300], // purples / violets
};

const _formatIcons = <BookFormat, IconData>{
  BookFormat.epub: Icons.menu_book_outlined,
  BookFormat.txt: Icons.article_outlined,
  BookFormat.pdf: Icons.picture_as_pdf_outlined,
  BookFormat.cbz: Icons.image_outlined,
  BookFormat.cbr: Icons.image_outlined,
};

class _PlaceholderCover extends StatelessWidget {
  const _PlaceholderCover({required this.book});

  final Book book;

  @override
  Widget build(BuildContext context) {
    final band = _formatPalettes[book.format]!;
    // Deterministic variation inside the format's band, stable per title.
    final t = (book.title.hashCode.abs() % 1000) / 1000;
    final hue = band[0] + (band[1] - band[0]) * t;

    // Deep enough that white ink clears WCAG AA (4.5:1) at all sizes.
    final base = HSLColor.fromAHSL(1, hue, 0.44, 0.34).toColor();
    final deep = HSLColor.fromAHSL(1, hue, 0.50, 0.20).toColor();
    final lift = HSLColor.fromAHSL(1, hue, 0.38, 0.44).toColor();

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          stops: const [0, 0.55, 1],
          colors: [lift, base, deep],
        ),
      ),
      child: CustomPaint(
        foregroundPainter: _PlaceholderTexture(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  width: 17,
                  height: 17,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.16),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    _formatIcons[book.format],
                    size: 11,
                    color: Colors.white.withValues(alpha: 0.92),
                  ),
                ),
              ),
              Expanded(
                child: Center(
                  child: _FittedTitle(
                    title: book.displayTitle,
                    author: book.author,
                  ),
                ),
              ),
              Text(
                book.format.name.toUpperCase(),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.72),
                  fontSize: 7,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 2,
                  height: 1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Title wrapped across up to three lines, shrinking to fit the cover width;
/// author line underneath when metadata exists.
class _FittedTitle extends StatelessWidget {
  const _FittedTitle({required this.title, required this.author});

  final String title;
  final String author;

  static const _maxFontSize = 15.0;
  static const _minFontSize = 8.5;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        var size = _maxFontSize;
        // Shrink until the wrapped title fits three lines within the box.
        while (size > _minFontSize && !_fits(size, constraints)) {
          size -= 0.5;
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white,
                fontSize: size,
                fontWeight: FontWeight.w700,
                height: 1.22,
                letterSpacing: 0.1,
              ),
            ),
            if (author.isNotEmpty && constraints.maxHeight > 40)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  author,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.78),
                    fontSize: size * 0.58,
                    fontWeight: FontWeight.w500,
                    height: 1,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  bool _fits(double fontSize, BoxConstraints constraints) {
    final painter = TextPainter(
      text: TextSpan(
        text: title,
        style: TextStyle(
          color: Colors.white,
          fontSize: fontSize,
          fontWeight: FontWeight.w700,
          height: 1.22,
        ),
      ),
      maxLines: 3,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: constraints.maxWidth);
    return painter.height <= constraints.maxHeight &&
        !painter.didExceedMaxLines;
  }
}

/// Subtle paper texture: fine diagonal hatching plus a soft highlight and
/// vignette so placeholders feel printed rather than flat.
class _PlaceholderTexture extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final hatch = Paint()
      ..color = Colors.white.withValues(alpha: 0.05)
      ..strokeWidth = 1;
    const step = 6.0;
    for (var x = -size.height; x < size.width + size.height; x += step) {
      canvas.drawLine(
        Offset(x, size.height),
        Offset(x + size.height, 0),
        hatch,
      );
    }

    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = RadialGradient(
          center: Alignment.topLeft,
          radius: 1.4,
          colors: [Colors.white.withValues(alpha: 0.10), Colors.transparent],
        ).createShader(Offset.zero & size),
    );

    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          stops: const [0.55, 1],
          colors: [Colors.transparent, Colors.black.withValues(alpha: 0.22)],
        ).createShader(Offset.zero & size),
    );

    // Gilt rule above the title block, like a classic cloth binding.
    final rule = Paint()
      ..color = Colors.white.withValues(alpha: 0.28)
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(size.width * 0.30, size.height * 0.16),
      Offset(size.width * 0.70, size.height * 0.16),
      rule,
    );
  }

  @override
  bool shouldRepaint(_PlaceholderTexture oldDelegate) => false;
}
