import 'dart:convert';

import '../db/database.dart' as db;
import '../models/book.dart';

/// Exports a book's highlights as a Markdown document.
///
/// Consecutive highlights sharing a locator label are grouped under one
/// heading. Blank selections are skipped.
String highlightsToMarkdown({
  required Book book,
  required List<db.HighlightRow> highlights,
  required String Function(db.HighlightRow) locatorLabel,
  DateTime? exportedAt,
}) {
  final date = _date(exportedAt ?? DateTime.now());
  final buffer = StringBuffer()
    ..writeln('# ${book.title} — ${book.author}')
    ..writeln('_Exported ${date}_')
    ..writeln();

  String? currentLabel;
  for (final highlight in highlights) {
    final quote = highlight.quote.trim();
    if (quote.isEmpty) continue;

    final label = locatorLabel(highlight);
    if (label != currentLabel) {
      currentLabel = label;
      buffer.writeln('## $label');
    }
    buffer.writeln('> $quote');
    final note = highlight.note.trim();
    if (note.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('**Note:** $note');
    }
    buffer.writeln();
  }

  return buffer.toString();
}

/// Exports a book's highlights as JSON, including every locator field so a
/// future import can reconstruct the records.
String highlightsToJson({
  required Book book,
  required List<db.HighlightRow> highlights,
  DateTime? exportedAt,
}) {
  return jsonEncode({
    'version': 1,
    'book': {'id': book.id, 'title': book.title, 'author': book.author},
    'exportedAt': _date(exportedAt ?? DateTime.now()),
    'highlights': [
      for (final highlight in highlights)
        {
          'id': highlight.id,
          'text': highlight.quote,
          'note': highlight.note,
          'color': highlight.color,
          'chapter': highlight.chapter,
          'startOffset': highlight.startOffset,
          'endChapter': highlight.endChapter,
          'endOffset': highlight.endOffset,
          'page': highlight.page,
          'segments': highlight.segments,
          'createdAt': highlight.createdAt,
          'updatedAt': highlight.updatedAt,
        },
    ],
  });
}

String _date(DateTime value) => value.toIso8601String().split('T').first;
