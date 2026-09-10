import 'package:flutter/material.dart';

import '../models/book.dart';
import '../services/library_service.dart';

class ReadingSessionManager extends ChangeNotifier {
  ReadingSessionManager({
    required this.library,
    required this.book,
  });

  final LibraryService library;
  final Book book;

  int _sessionId = -1;
  int _pagesFlipped = 0;

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
    if (_sessionId >= 0) return;
    _sessionId = -2; // sentinel: session pending
    library.startSession(book.id).then(
      (id) {
        _sessionId = id;
        notifyListeners();
      },
      onError: (_) {
        _sessionId = -1;
        notifyListeners();
      },
    );
  }

  void endSession() {
    if (_sessionId < 0) return;
    library.endSession(_sessionId, pages: _pagesFlipped);
    _sessionId = -1;
    _pagesFlipped = 0;
    notifyListeners();
  }

  @override
  void dispose() {
    endSession();
    super.dispose();
  }
}
