import 'dart:io';

import '../models/book.dart';
import 'book_title.dart';

/// Series name and issue index inferred from a comic's filename.
class ComicSeries {
  final String? name;
  final double? index;
  const ComicSeries(this.name, this.index);
}

/// Matches a trailing bracketed/parenthesised tag such as `(2016)`,
/// `[Digital]` or `(Zone-Empire)`.
final RegExp _trailingTagRe = RegExp(r'\s*[\(\[]\s*[^\)\]]*\s*[\)\]]\s*$');

/// Leading scanner group tags, e.g. `[Group] Batman 001`.
final RegExp _leadingTagRe = RegExp(r'^\s*[\[\(][^\]\)]*[\]\)]\s*');

/// Explicit issue markers: `#12`, `Issue 12`, `Chapter 12`, `No. 12`, etc.
final RegExp _issueKeywordRe = RegExp(
  r'^(.*?)[\s\-–—:]*(?:#|issue|iss|chapter|ch|no|number|nr|part|pt)\s*\.?\s*(\d+(?:\.\d+)?)\b',
  caseSensitive: false,
);

/// A standalone number separated from the series by whitespace or a dash.
final RegExp _trailingNumberRe = RegExp(r'^(.*?)[\s\-–—:]+(\d{1,4}(?:\.\d+)?)\s*$');

/// A number glued directly to the end of a name, e.g. `Batman001`.
final RegExp _gluedNumberRe = RegExp(r'^(.*?[A-Za-z])(\d{1,4})\s*$');

String _stripTrailingTags(String s) {
  var result = s;
  while (true) {
    final next = result.replaceFirst(_trailingTagRe, '').trim();
    if (next == result) break;
    result = next;
  }
  return result;
}

String? _cleanSeriesName(String raw) {
  final name = cleanBookTitle(
    raw.replaceAll(RegExp(r'[\s\-–—:]+$'), '').trim(),
  );
  return name.isEmpty ? null : name;
}

/// Infers a comic series name and issue index from [path].
///
/// Handles common release naming such as:
///   `Batman 001 (2016).cbz`   -> ("Batman", 1)
///   `Saga #054.cbz`           -> ("Saga", 54)
///   `The Walking Dead - 100.cbz` -> ("The Walking Dead", 100)
///   `[Group] Invincible 012.cbz` -> ("Invincible", 12)
ComicSeries parseComicSeries(String path) {
  var base = path.split(Platform.pathSeparator).last;
  final dot = base.lastIndexOf('.');
  if (dot > 0) base = base.substring(0, dot);
  if (base.isEmpty) return const ComicSeries(null, null);

  base = base.replaceFirst(_leadingTagRe, '');
  base = base.replaceAll('_', ' ').trim();
  base = _stripTrailingTags(base);
  if (base.isEmpty) return const ComicSeries(null, null);

  final keyword = _issueKeywordRe.firstMatch(base);
  if (keyword != null) {
    final name = _cleanSeriesName(keyword.group(1)!);
    if (name != null) {
      return ComicSeries(name, double.tryParse(keyword.group(2)!));
    }
  }

  final trailing = _trailingNumberRe.firstMatch(base);
  if (trailing != null) {
    final name = _cleanSeriesName(trailing.group(1)!);
    if (name != null) {
      return ComicSeries(name, double.tryParse(trailing.group(2)!));
    }
  }

  final glued = _gluedNumberRe.firstMatch(base);
  if (glued != null) {
    final name = _cleanSeriesName(glued.group(1)!);
    if (name != null) {
      return ComicSeries(name, double.tryParse(glued.group(2)!));
    }
  }

  return const ComicSeries(null, null);
}

extension ComicSeriesInfo on Book {
  /// Series name from metadata, falling back to one inferred from the filename
  /// for comics that ship without embedded series data.
  String? get effectiveSeriesName {
    final stored = seriesName;
    if (stored != null && stored.isNotEmpty) return stored;
    if (format != BookFormat.cbz && format != BookFormat.cbr) return null;
    return parseComicSeries(path).name;
  }

  /// Issue index from metadata, falling back to the filename-derived one.
  double? get effectiveSeriesIndex {
    if (seriesIndex != null) return seriesIndex;
    if (format != BookFormat.cbz && format != BookFormat.cbr) return null;
    return parseComicSeries(path).index;
  }
}
