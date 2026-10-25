import 'dart:math';

import 'package:flutter/foundation.dart';

/// One in-progress text selection in an open book.
///
/// Offsets are flat document offsets: long-press starts on a whole word, while
/// drags follow exact characters. The model keeps the range ordered ([start] is
/// always strictly less than [end]).
///
/// The anchor is the word the press started on. Dragging past it extends the
/// selection forward from that word; dragging before it extends backward.
class ReaderSelection extends ChangeNotifier {
  int? _start;
  int? _end;
  int? _anchorStart;
  int? _anchorEnd;

  int? get start => _start;
  int? get end => _end;

  bool get isEmpty => _start == null || _end == null;
  bool get isActive => !isEmpty;

  /// Starts a fresh selection on the word `[start, end)`.
  void beginWord(int start, int end) {
    _start = start;
    _end = end;
    _anchorStart = start;
    _anchorEnd = end;
    notifyListeners();
  }

  /// Extends the selection to the exact character offset [offset].
  ///
  /// Forward drags keep the anchor word as the start and move the end; backward
  /// drags keep it as the end and move the start. A drag inside the anchor word
  /// leaves the whole word selected: the finger extends, handle drags shrink.
  void dragToOffset(int offset) {
    final anchorStart = _anchorStart;
    final anchorEnd = _anchorEnd;
    if (anchorStart == null || anchorEnd == null) return;
    if (offset <= anchorStart) {
      _start = min(anchorStart, offset);
      _end = anchorEnd;
    } else if (offset >= anchorEnd) {
      _start = anchorStart;
      _end = max(anchorEnd, offset);
    } else {
      return;
    }
    notifyListeners();
  }

  /// Moves the start boundary, clamped so it stays below [end].
  void setStart(int offset) {
    final end = _end;
    if (end == null) return;
    _start = min(offset, end - 1);
    notifyListeners();
  }

  /// Moves the end boundary, clamped so it stays above [start].
  void setEnd(int offset) {
    final start = _start;
    if (start == null) return;
    _end = max(offset, start + 1);
    notifyListeners();
  }

  void clear() {
    _start = null;
    _end = null;
    _anchorStart = null;
    _anchorEnd = null;
    notifyListeners();
  }
}
