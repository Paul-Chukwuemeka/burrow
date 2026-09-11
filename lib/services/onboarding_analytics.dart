import 'package:flutter/foundation.dart';

/// Lightweight analytics dispatcher. In production this would route to
/// Firebase Analytics, PostHog, or similar. For now it logs to debug console.
///
/// Every event is a named string with optional key-value properties.
/// Call [OnboardingAnalytics.instance] to access the singleton.
class OnboardingAnalytics extends ChangeNotifier {
  OnboardingAnalytics._();

  static final OnboardingAnalytics instance = OnboardingAnalytics._();

  final List<AnalyticsEvent> _events = [];

  /// All events recorded during this session (for testing / debugging).
  List<AnalyticsEvent> get events => List.unmodifiable(_events);

  void _record(String name, [Map<String, Object?>? properties]) {
    final event = AnalyticsEvent(name: name, properties: properties);
    _events.add(event);
    debugPrint('[analytics] $name${properties != null ? ' $properties' : ''}');
    notifyListeners();
  }

  // ---- Onboarding events -------------------------------------------------

  void onboardingStarted() => _record('onboarding_started');

  void pageViewed(int pageIndex, String pageName) =>
      _record('onboarding_page_viewed', {
        'page_index': pageIndex,
        'page_name': pageName,
      });

  void skippedFrom(int pageIndex) =>
      _record('onboarding_skipped', {'from_page': pageIndex});

  void permissionGranted() => _record('permission_granted');

  void permissionDenied() => _record('permission_denied');

  void formatSelected(String format, bool selected) =>
      _record('format_selected', {
        'format': format,
        'selected': selected,
      });

  void themeSelected(String theme) =>
      _record('theme_selected', {'theme': theme});

  void scanStarted(String scanType) =>
      _record('onboarding_scan_started', {'scan_type': scanType});

  void scanCompleted({
    required int booksFound,
    required int booksImported,
    required int durationMs,
  }) =>
      _record('onboarding_scan_completed', {
        'books_found': booksFound,
        'books_imported': booksImported,
        'duration_ms': durationMs,
      });

  void onboardingCompleted({required int totalDurationMs}) =>
      _record('onboarding_completed', {
        'total_duration_ms': totalDurationMs,
      });
}

class AnalyticsEvent {
  const AnalyticsEvent({required this.name, this.properties});

  final String name;
  final Map<String, Object?>? properties;

  @override
  String toString() => 'AnalyticsEvent($name, $properties)';
}
