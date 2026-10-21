import 'package:burrow/models/book.dart';
import 'package:burrow/utils/comic_issues.dart';
import 'package:flutter_test/flutter_test.dart';

Book _issue(String id, String title, {double? index}) {
  return Book(
    id: id,
    title: title,
    author: '',
    path: '/tmp/$id.cbz',
    format: BookFormat.cbz,
    addedAt: 1,
    seriesIndex: index,
  );
}

void main() {
  test('orderedComicIssues sorts ascending by seriesIndex', () {
    final issues = orderedComicIssues([
      _issue('c3', 'Batman 003', index: 3),
      _issue('c1', 'Batman 001', index: 1),
      _issue('c2', 'Batman 002', index: 2),
    ]);
    expect(issues.map((b) => b.id), ['c1', 'c2', 'c3']);
  });

  test('orderedComicIssues puts books without an index last', () {
    final issues = orderedComicIssues([
      _issue('cX', 'Batman Annual'),
      _issue('c1', 'Batman 001', index: 1),
    ]);
    expect(issues.map((b) => b.id), ['c1', 'cX']);
  });

  test('orderedComicIssues breaks index ties by title, case-insensitive', () {
    final issues = orderedComicIssues([
      _issue('b', 'batman beta', index: 1),
      _issue('a', 'Batman Alpha', index: 1),
    ]);
    expect(issues.map((b) => b.id), ['a', 'b']);
  });

  test('nextComicIssue returns the following issue and null at the end', () {
    final series = [
      _issue('c1', 'Batman 001', index: 1),
      _issue('c2', 'Batman 002', index: 2),
      _issue('c3', 'Batman 003', index: 3),
    ];
    expect(nextComicIssue(series, series[0])!.id, 'c2');
    expect(nextComicIssue(series, series[1])!.id, 'c3');
    expect(nextComicIssue(series, series[2]), isNull);
  });

  test('nextComicIssue works on an unordered library list', () {
    final series = [
      _issue('c3', 'Batman 003', index: 3),
      _issue('c1', 'Batman 001', index: 1),
      _issue('c2', 'Batman 002', index: 2),
    ];
    expect(nextComicIssue(series, series[1])!.id, 'c2');
    expect(previousComicIssue(series, series[2])!.id, 'c1');
  });

  test('previousComicIssue returns the preceding issue and null at the start',
      () {
    final series = [
      _issue('c1', 'Batman 001', index: 1),
      _issue('c2', 'Batman 002', index: 2),
    ];
    expect(previousComicIssue(series, series[1])!.id, 'c1');
    expect(previousComicIssue(series, series[0]), isNull);
  });

  test('an unindexed issue still resolves neighbours', () {
    final series = [
      _issue('c1', 'Batman 001', index: 1),
      _issue('cX', 'Batman Annual'),
      _issue('c2', 'Batman 002', index: 2),
    ];
    // The unindexed annual sorts last, like the Series screen's Order sort.
    expect(previousComicIssue(series, series[1])!.id, 'c2');
    expect(nextComicIssue(series, series[1]), isNull);
  });

  test('a book from another series resolves nothing', () {
    final series = [
      _issue('c1', 'Batman 001', index: 1),
      _issue('c2', 'Batman 002', index: 2),
    ];
    expect(nextComicIssue(series, _issue('d1', 'Saga 1', index: 1)), isNull);
    expect(
      previousComicIssue(series, _issue('d1', 'Saga 1', index: 1)),
      isNull,
    );
  });
}
