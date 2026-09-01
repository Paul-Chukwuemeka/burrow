const _monthNames = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
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
