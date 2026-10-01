import 'package:burrow/models/book.dart';
import 'package:burrow/services/missing_matcher.dart';
import 'package:flutter_test/flutter_test.dart';

Book _m(String id, {int? size, int? mtime, BookFormat f = BookFormat.epub}) =>
    Book(id: id, title: id, author: '', path: '/gone/$id.epub', format: f, addedAt: 1, fileSize: size, mtimeMs: mtime);

void main() {
  test('exact single match returns id', () {
    final missing = [_m('a', size: 10, mtime: 100)];
    expect(findRelinkCandidate(size: 10, mtimeMs: 100, format: BookFormat.epub, missing: missing), 'a');
  });
  test('duplicate fingerprint returns null', () {
    final missing = [_m('a', size: 10, mtime: 100), _m('b', size: 10, mtime: 100)];
    expect(findRelinkCandidate(size: 10, mtimeMs: 100, format: BookFormat.epub, missing: missing), isNull);
  });
  test('format mismatch returns null', () {
    final missing = [_m('a', size: 10, mtime: 100, f: BookFormat.pdf)];
    expect(findRelinkCandidate(size: 10, mtimeMs: 100, format: BookFormat.epub, missing: missing), isNull);
  });
  test('null fingerprint never matches', () {
    final missing = [_m('a')];
    expect(findRelinkCandidate(size: 10, mtimeMs: 100, format: BookFormat.epub, missing: missing), isNull);
  });
}
