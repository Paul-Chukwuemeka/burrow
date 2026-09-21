const _monthNames = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// Formats milliseconds-since-epoch as `"Sep 1, 2026"`.
///
/// Returns an empty string when [ms] is `0` or negative (i.e. the event
/// has never happened).
String formatDate(int ms) {
  if (ms <= 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${_monthNames[d.month - 1]} ${d.day}, ${d.year}';
}

/// Formats a [DateTime] as `"Sep 1, 2026"`.
String formatDateTime(DateTime d) =>
    '${_monthNames[d.month - 1]} ${d.day}, ${d.year}';

/// Attempts to format a raw publication-date string from EPUB metadata.
///
/// Handles ISO 8601 dates (`2024-03-15T00:00:00Z`), plain years (`2024`),
/// and year-month strings (`2024-03`).  Returns a human-readable string
/// like `"Mar 15, 2024"` or `"2024"`.  Returns an empty string for bogus
/// default dates (year ≤ 1) or unparseable input.
String formatPublicationDate(String raw) {
  if (raw.isEmpty) return '';

  // Try full DateTime parse first.
  final d = DateTime.tryParse(raw);
  if (d != null && d.year > 1) {
    // If the date is just midnight (no real time info), show date only.
    if (d.hour == 0 && d.minute == 0 && d.second == 0) {
      return '${_monthNames[d.month - 1]} ${d.day}, ${d.year}';
    }
    return '${_monthNames[d.month - 1]} ${d.day}, ${d.year} at ${d.hour}:${d.minute.toString().padLeft(2, '0')}';
  }

  // Try extracting just a 4-digit year.
  final yearMatch = RegExp(r'\b(\d{4})\b').firstMatch(raw);
  if (yearMatch != null) {
    final year = int.parse(yearMatch.group(1)!);
    if (year > 1) return '$year';
  }

  return '';
}
