import 'package:flutter/material.dart';

import '../services/library_service.dart';

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
  Map<int, int> _dailyTime = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    final sessions = await widget.library.getAllSessions();
    final books = widget.library.books;
    final dailyTime = await widget.library.getDailyReadingTime();
    final streak = await widget.library.getReadingStreak();

    var totalTime = 0;
    var totalPages = 0;
    for (final s in sessions) {
      if (s.endedAt > 0) totalTime += s.endedAt - s.startedAt;
      totalPages += s.pages;
    }

    final started = books.where((b) => b.isStarted).length;
    final finished = books.where((b) => b.isFinished).length;

    if (!mounted) return;
    setState(() {
      _streak = streak;
      _totalTimeMs = totalTime;
      _totalPages = totalPages;
      _totalSessions = sessions.length;
      _booksStarted = started;
      _booksFinished = finished;
      _dailyTime = dailyTime;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Reading Stats'),
      ),
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
              Icon(Icons.bar_chart_rounded,
                  size: 56, color: scheme.primary),
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

        // Overview stats.
        Text(
          'Overview',
          style: theme.textTheme.titleSmall?.copyWith(
            color: scheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _StatTile(
                label: 'Total time',
                value: _formatDuration(_totalTimeMs),
                icon: Icons.timer_outlined,
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
                label: 'Books',
                value: '$_booksStarted started',
                secondary: '$_booksFinished finished',
                icon: Icons.library_books_outlined,
                scheme: scheme,
              ),
            ),
          ],
        ),

        // Weekly chart.
        if (_dailyTime.isNotEmpty) ...[
          const SizedBox(height: 24),
          Text(
            'This week',
            style: theme.textTheme.titleSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          _WeeklyChart(dailyTime: _dailyTime, scheme: scheme),
        ],
      ],
    );
  }

  String _formatDuration(int ms) {
    if (ms < 60000) return '${(ms / 1000).round()}s';
    if (ms < 3600000) return '${(ms / 60000).round()}m';
    final h = (ms / 3600000).floor();
    final m = ((ms % 3600000) / 60000).round();
    return '${h}h ${m}m';
  }
}

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
          Icon(Icons.local_fire_department_outlined,
              size: 40, color: scheme.onPrimaryContainer),
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
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurfaceVariant,
              ),
            ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _WeeklyChart extends StatelessWidget {
  const _WeeklyChart({required this.dailyTime, required this.scheme});

  final Map<int, int> dailyTime;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = (now.millisecondsSinceEpoch / 86400000).floor();
    final days = <MapEntry<int, String>>[];

    for (var i = 6; i >= 0; i--) {
      final day = today - i;
      final label = _dayLabel(now.subtract(Duration(days: i)));
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
      child: Row(
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
    );
  }

  String _dayLabel(DateTime date) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return days[date.weekday - 1];
  }
}
