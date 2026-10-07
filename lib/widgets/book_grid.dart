import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../theme/burrow_tokens.dart';

const double kBookGridMaxTileExtent = 170.0;
const double kBookGridCrossSpacing = 12.0;
const double kBookGridMainSpacing = 14.0;
const double kBookGridCardPadding = 6.0;
const double kBookGridTextBlock = 58.0;
const double kBookGridPadding = 20.0;

/// Computes [SliverGridDelegate] for a book cover grid that fits [width] pixels,
/// with columns sized so each tile is at most [kBookGridMaxTileExtent] wide.
SliverGridDelegate bookGridDelegate(double width) {
  final columns = math.max(1, (width / kBookGridMaxTileExtent).ceil());
  final tileWidth = (width - kBookGridCrossSpacing * (columns - 1)) / columns;
  final coverWidth = tileWidth - kBookGridCardPadding * 2;
  final mainAxisExtent =
      kBookGridCardPadding +
      coverWidth / Burrow.coverAspectRatio +
      kBookGridTextBlock;

  return SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: columns,
    crossAxisSpacing: kBookGridCrossSpacing,
    mainAxisSpacing: kBookGridMainSpacing,
    mainAxisExtent: mainAxisExtent,
  );
}
