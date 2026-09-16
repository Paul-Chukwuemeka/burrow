import 'package:flutter/material.dart';

import '../db/database.dart';
import '../models/book_stats.dart';
import '../services/library_service.dart';
import '../utils/book_title.dart';
import '../widgets/book_cover.dart';

class StatsScreen extends StatefulWidget {
  const StatsScreen({super.key, required this.library});

  final LibraryService library;

  static void show(BuildContext context, {required LibraryService library}) {
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => StatsScreen(library: library),
      ),
    );
  }

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  int _streak = 0;
  int _totalTimeMs = 0;
  int _totalPages = 0;
  int _totalSessions = 0;
  int _booksStarted = 0;
  int _booksFinished = 0;
  int _todayTimeMs = 0;
  int _avgSessionMs = 0;
  int _longestSessionMs = 0;
  Map<int, int> _dailyTime = {};
  Map<int, int> _hourlyTime = {};
  Map<String, int> _monthlyTime = {};
  List<BookStats> _perBookStats = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    final books = widget.library.books;
    final dailyTime = await widget.library.getDailyReadingTime();
    final streak = await widget.library.getReadingStreak();
    final todayTime = await widget.library.getTodayReadingTimeMs();
    final avgSession = await widget.library.getAverageSessionMs();
    final longestSession = await widget.library.getLongestSessionMs();
    final hourlyTime = await widget.library.getHourlyReadingTime();
    final monthlyTime = await widget.library.getMonthlyReadingTime();
    final perBookStats = await widget.library.getPerBookStats();

    var totalTime = 0;
    var totalPages = 0;
    var totalSessions = 0;
    for (final s in perBookStats) {
      totalTime += s.totalTimeMs;
      totalPages += s.totalPages;
      totalSessions += s.sessionCount;
    }

    final started = books.where((b) => b.isStarted).length;
    final finished = books.where((b) => b.isFinished).length;

    if (!mounted) return;
    setState(() {
      _streak = streak;
      _totalTimeMs = totalTime;
      _totalPages = totalPages;
      _totalSessions = totalSessions;
      _booksStarted = started;
      _booksFinished = finished;
      _todayTimeMs = todayTime;
      _avgSessionMs = avgSession;
      _longestSessionMs = longestSession;
      _dailyTime = dailyTime;
      _hourlyTime = hourlyTime;
      _monthlyTime = monthlyTime;
      _perBookStats = perBookStats;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Reading Stats')),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: scheme.primary))
          : _buildContent(theme, scheme),
    );
  }

  Widget _buildContent(ThemeData theme, ColorScheme scheme) {
    if (_totalSessions == 0) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.bar_chart_rounded, size: 56, color: scheme.primary),
              const SizedBox(height: 16),
              Text(
                'No reading data yet',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Start reading to track your progress.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Streak card.
        _StreakCard(streak: _streak, scheme: scheme),
        const SizedBox(height: 16),

        // Overview stats — 2×3 grid.
        _SectionHeader('Overview'),
        const SizedBox(height: 8),
        _buildOverviewGrid(scheme),

        // Weekly chart.
        if (_dailyTime.isNotEmpty) ...[
          const SizedBox(height: 24),
          _SectionHeader('This week'),
          const SizedBox(height: 12),
          _WeeklyChart(dailyTime: _dailyTime, scheme: scheme),
        ],

        // Monthly chart.
        if (_monthlyTime.isNotEmpty) ...[
          const SizedBox(height: 24),
          _SectionHeader('By month'),
          const SizedBox(height: 12),
          _MonthlyChart(monthlyTime: _monthlyTime, scheme: scheme),
        ],

        // Hourly heatmap.
        if (_hourlyTime.isNotEmpty) ...[
          const SizedBox(height: 24),
          _SectionHeader('Reading hours'),
          const SizedBox(height: 12),
          _HourlyHeatmap(hourlyTime: _hourlyTime, scheme: scheme),
        ],

        // Per-book stats.
        if (_perBookStats.isNotEmpty) ...[
          const SizedBox(height: 24),
          _SectionHeader('Per-book stats'),
          const SizedBox(height: 12),
          ..._perBookStats.map(
            (s) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _PerBookStatsTile(stats: s, scheme: scheme),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildOverviewGrid(ColorScheme scheme) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _StatTile(
                label: 'Today',
                value: _formatDuration(_todayTimeMs),
                icon: Icons.today_rounded,
                scheme: scheme,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _StatTile(
                label: 'Avg session',
                value: _formatDuration(_avgSessionMs),
                icon: Icons.timer_outlined,
                scheme: scheme,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _StatTile(
                label: 'Total time',
                value: _formatDuration(_totalTimeMs),
                icon: Icons.hourglass_bottom_rounded,
                scheme: scheme,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _StatTile(
                label: 'Pages read',
                value: '$_totalPages',
                icon: Icons.auto_stories_outlined,
                scheme: scheme,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _StatTile(
                label: 'Sessions',
                value: '$_totalSessions',
                icon: Icons.history,
                scheme: scheme,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _StatTile(
                label: 'Longest',
                value: _formatDuration(_longestSessionMs),
                icon: Icons.emoji_events_outlined,
                scheme: scheme,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _StatTile(
                label: 'Books',
                value: '$_booksStarted started',
                secondary: '$_booksFinished finished',
                icon: Icons.library_books_outlined,
                scheme: scheme,
              ),
            ),
            const SizedBox(width: 8),
            const Expanded(child: SizedBox.shrink()),
          ],
        ),
      ],
    );
  }

  String _formatDuration(int ms) {
    if (ms < 60000) return '${(ms / 1000).round()}s';
    if (ms < 3600000) return '${(ms / 60000).round()}m';
    var h = (ms / 3600000).floor();
    var m = ((ms % 3600000) / 60000).round();
    if (m == 60) {
      h += 1;
      m = 0;
    }
    return '${h}h ${m}m';
  }
}

// ---------------------------------------------------------------------------
// Section header
// ---------------------------------------------------------------------------

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Text(
      label,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
        color: scheme.onSurfaceVariant,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Streak card
// ---------------------------------------------------------------------------

class _StreakCard extends StatelessWidget {
  const _StreakCard({required this.streak, required this.scheme});

  final int streak;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(
            Icons.local_fire_department_outlined,
            size: 40,
            color: scheme.onPrimaryContainer,
          ),
          const SizedBox(width: 16),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$streak',
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w800,
                  color: scheme.onPrimaryContainer,
                ),
              ),
              Text(
                'day streak',
                style: TextStyle(
                  fontSize: 14,
                  color: scheme.onPrimaryContainer.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Stat tile
// ---------------------------------------------------------------------------

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.label,
    required this.value,
    required this.icon,
    required this.scheme,
    this.secondary,
  });

  final String label;
  final String value;
  final IconData icon;
  final ColorScheme scheme;
  final String? secondary;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: scheme.onSurfaceVariant),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: scheme.onSurface,
            ),
          ),
          if (secondary != null)
            Text(
              secondary!,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Weekly chart — with value labels
// ---------------------------------------------------------------------------

class _WeeklyChart extends StatelessWidget {
  const _WeeklyChart({required this.dailyTime, required this.scheme});

  final Map<int, int> dailyTime;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    // Calendar-day stepping (DST-safe): recompute midnight per day instead
    // of subtracting fixed 86400000ms, which lands off-midnight on 23/25h days.
    final days = <MapEntry<int, String>>[];

    for (var i = 6; i >= 0; i--) {
      final date = DateTime(now.year, now.month, now.day - i);
      final day = AppDatabase.localDayKey(date.millisecondsSinceEpoch);
      final label = _dayLabel(date);
      days.add(MapEntry(day, label));
    }

    final maxTime = days
        .map((e) => dailyTime[e.key] ?? 0)
        .fold<int>(0, (a, b) => a > b ? a : b);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: days.map((entry) {
              final time = dailyTime[entry.key] ?? 0;
              final fraction = maxTime > 0 ? time / maxTime : 0.0;
              return Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (time > 0)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            _shortDuration(time),
                            style: TextStyle(
                              fontSize: 8,
                              fontWeight: FontWeight.w600,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        )
                      else
                        const SizedBox(height: 16),
                      Container(
                        height: (80 * fraction).clamp(4.0, 80.0),
                        decoration: BoxDecoration(
                          color: time > 0
                              ? scheme.primary
                              : scheme.onSurfaceVariant.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        entry.value,
                        style: TextStyle(
                          fontSize: 10,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  String _dayLabel(DateTime date) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return days[date.weekday - 1];
  }

  String _shortDuration(int ms) {
    if (ms < 3600000) return '${(ms / 60000).round()}m';
    var h = (ms / 3600000).floor();
    var m = ((ms % 3600000) / 60000).round();
    if (m == 60) {
      h += 1;
      m = 0;
    }
    return m > 0 ? '${h}h${m}m' : '${h}h';
  }
}

// ---------------------------------------------------------------------------
// Monthly chart — horizontal bars
// ---------------------------------------------------------------------------

class _MonthlyChart extends StatelessWidget {
  const _MonthlyChart({required this.monthlyTime, required this.scheme});

  final Map<String, int> monthlyTime;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final sorted = monthlyTime.entries.toList()
      ..sort((a, b) => b.key.compareTo(a.key));
    final recent = sorted.take(6).toList();
    if (recent.isEmpty) return const SizedBox.shrink();

    final maxTime = recent
        .map((e) => e.value)
        .fold<int>(0, (a, b) => a > b ? a : b);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: recent.map((entry) {
          final fraction = maxTime > 0 ? entry.value / maxTime : 0.0;
          final parts = entry.key.split('-');
          final monthName = _monthLabel(int.parse(parts[1]));
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                SizedBox(
                  width: 40,
                  child: Text(
                    monthName,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Stack(
                    children: [
                      Container(
                        height: 16,
                        decoration: BoxDecoration(
                          color: scheme.onSurfaceVariant.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      FractionallySizedBox(
                        widthFactor: fraction.clamp(0.0, 1.0),
                        child: Container(
                          height: 16,
                          decoration: BoxDecoration(
                            color: scheme.primary,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 48,
                  child: Text(
                    _formatDuration(entry.value),
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  String _monthLabel(int month) {
    const names = [
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
    return names[month - 1];
  }

  String _formatDuration(int ms) {
    if (ms < 3600000) return '${(ms / 60000).round()}m';
    var h = (ms / 3600000).floor();
    var m = ((ms % 3600000) / 60000).round();
    if (m == 60) {
      h += 1;
      m = 0;
    }
    return '${h}h ${m}m';
  }
}

// ---------------------------------------------------------------------------
// Hourly heatmap — 24-column intensity grid
// ---------------------------------------------------------------------------

class _HourlyHeatmap extends StatelessWidget {
  const _HourlyHeatmap({required this.hourlyTime, required this.scheme});

  final Map<int, int> hourlyTime;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final maxTime = hourlyTime.values.fold<int>(0, (a, b) => a > b ? a : b);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          // Hour labels (every 6 hours).
          Row(
            children: List.generate(24, (i) {
              final showLabel = i % 6 == 0;
              return Expanded(
                child: Text(
                  showLabel ? '$i' : '',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 8, color: scheme.onSurfaceVariant),
                ),
              );
            }),
          ),
          const SizedBox(height: 4),
          // Heatmap row.
          Row(
            children: List.generate(24, (i) {
              final time = hourlyTime[i] ?? 0;
              final intensity = maxTime > 0 ? time / maxTime : 0.0;
              return Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 1),
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: Container(
                      decoration: BoxDecoration(
                        color: _heatColor(intensity, scheme),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),
        ],
      ),
    );
  }

  Color _heatColor(double intensity, ColorScheme scheme) {
    if (intensity <= 0) return scheme.onSurfaceVariant.withValues(alpha: 0.08);
    if (intensity < 0.25) return scheme.primary.withValues(alpha: 0.2);
    if (intensity < 0.5) return scheme.primary.withValues(alpha: 0.4);
    if (intensity < 0.75) return scheme.primary.withValues(alpha: 0.65);
    return scheme.primary;
  }
}

// ---------------------------------------------------------------------------
// Per-book stats tile
// ---------------------------------------------------------------------------

class _PerBookStatsTile extends StatelessWidget {
  const _PerBookStatsTile({required this.stats, required this.scheme});

  final BookStats stats;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final progress = stats.book.progress.clamp(0.0, 1.0);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 44,
            height: 66,
            child: BookCover(book: stats.book, borderRadius: 6, spine: false),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  stats.book.displayTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${_formatDuration(stats.totalTimeMs)} · ${stats.sessionCount} session${stats.sessionCount == 1 ? '' : 's'}',
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 4,
                    backgroundColor: scheme.onSurfaceVariant.withValues(
                      alpha: 0.15,
                    ),
                    color: scheme.primary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${(progress * 100).round()}%',
                  style: TextStyle(
                    fontSize: 10,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatDuration(int ms) {
    if (ms < 3600000) return '${(ms / 60000).round()}m';
    var h = (ms / 3600000).floor();
    var m = ((ms % 3600000) / 60000).round();
    if (m == 60) {
      h += 1;
      m = 0;
    }
    return '${h}h ${m}m';
  }
}
