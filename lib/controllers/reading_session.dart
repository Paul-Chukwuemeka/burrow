import 'dart:async';

import 'package:flutter/material.dart';

import '../models/book.dart';
import '../services/library_service.dart';

class ReadingSessionManager extends ChangeNotifier {
  ReadingSessionManager({required this.library, required this.book});

  final LibraryService library;
  final Book book;

  int _sessionId = -1;
  int _pagesFlipped = 0;
  int _startGeneration = 0;
  bool _disposed = false;
  Future<int>? _pendingStart;

  int get sessionId => _sessionId;

  set pagesFlipped(int value) => _pagesFlipped = value;

  void onPageFlipped() => _pagesFlipped++;

  void onLifecycleChanged(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      endSession();
    } else if (state == AppLifecycleState.resumed) {
      startSession();
    }
  }

  void startSession() {
    if (_disposed) return;
    if (_sessionId >= 0 || _sessionId == -2) return;
    _sessionId = -2; // sentinel: session pending
    final gen = ++_startGeneration;
    final fut = library.startSession(book.id);
    _pendingStart = fut;
    fut.then(
      (id) {
        if (_disposed || gen != _startGeneration) return; // superseded
        _sessionId = id;
        _pendingStart = null;
        notifyListeners();
      },
      onError: (_) {
        if (_disposed || gen != _startGeneration) return;
        _sessionId = -1;
        _pendingStart = null;
        notifyListeners();
      },
    );
  }

  Future<void> endSession() async {
    // Pending insert: cancel the stale callback, then await the insert and
    // end the resulting session so no orphan row leaks. If the insert fails,
    // just reset to idle.
    if (_sessionId == -2) {
      _startGeneration++; // invalidate the pending .then callback
      final pages = _pagesFlipped;
      int? sid;
      try {
        sid = await _pendingStart;
      } catch (e) {
        debugPrint('Failed to start session for ${book.id}: $e');
      }
      _pendingStart = null;
      _sessionId = -1;
      _pagesFlipped = 0;
      if (!_disposed) notifyListeners();
      if (sid != null) {
        try {
          await library.endSession(sid, pages: pages);
        } catch (e) {
          debugPrint('Failed to end session $sid: $e');
        }
      }
      return;
    }
    if (_sessionId < 0) return;
    // Invalidate any in-flight start (defensive; startSession guards -2, but
    // a rapid toggle could interleave).
    _startGeneration++;
    // Capture values before zeroing so the async write uses the correct data.
    final sid = _sessionId;
    final pages = _pagesFlipped;
    _sessionId = -1;
    _pagesFlipped = 0;
    if (!_disposed) notifyListeners();
    try {
      await library.endSession(sid, pages: pages);
    } catch (e) {
      debugPrint('Failed to end session $sid: $e');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _startGeneration++; // cancel any pending startSession callback so it
    // never calls notifyListeners() on this disposed object.
    // Fire-and-forget: the DB write completes in the background even after
    // dispose. endSession captures session ID and pages as locals before
    // the await, and skips notifyListeners when _disposed.
    unawaited(endSession());
    super.dispose();
  }
}
