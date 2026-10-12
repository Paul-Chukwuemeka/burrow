import 'package:flutter/foundation.dart';

/// Debug-only accumulator for open-path timings.
///
/// Off unless the app is run with `--dart-define=BURROW_OPEN_TRACE=true`.
/// [span] is then a no-op, so production pays nothing.
class OpenTrace {
  OpenTrace._();

  static bool enabled = const bool.fromEnvironment('BURROW_OPEN_TRACE');

  static final Map<String, int> _totals = {};

  static Map<String, int> get spansMicros => Map.unmodifiable(_totals);

  static void span(String name, Duration d) {
    if (!enabled) return;
    _totals[name] = (_totals[name] ?? 0) + d.inMicroseconds;
  }

  static void reset() => _totals.clear();

  static void dump() {
    if (!enabled || _totals.isEmpty) return;
    final entries = _totals.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    for (final e in entries) {
      debugPrint(
        'OpenTrace ${e.key}: ${(e.value / 1000).toStringAsFixed(1)} ms',
      );
    }
  }
}
