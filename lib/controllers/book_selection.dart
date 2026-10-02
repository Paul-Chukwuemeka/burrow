import 'package:flutter/foundation.dart';

class BookSelection extends ChangeNotifier {
  final Set<String> _ids = {};

  Set<String> get selectedIds => Set.unmodifiable(_ids);
  bool get isSelecting => _ids.isNotEmpty;
  int get count => _ids.length;

  void enter(String id) {
    _ids.add(id);
    notifyListeners();
  }

  void toggle(String id) {
    if (!_ids.remove(id)) _ids.add(id);
    notifyListeners();
  }

  void selectAll(Iterable<String> ids) {
    _ids.addAll(ids);
    notifyListeners();
  }

  void clear() {
    if (_ids.isEmpty) return;
    _ids.clear();
    notifyListeners();
  }
}
