import '../models/book.dart';

String? findRelinkCandidate({
  required int size,
  required int mtimeMs,
  required BookFormat format,
  required List<Book> missing,
}) {
  String? hit;
  var count = 0;
  for (final b in missing) {
    if (b.fileSize == null || b.mtimeMs == null) continue;
    if (b.fileSize == size && b.mtimeMs == mtimeMs && b.format == format) {
      count++;
      hit = b.id;
      if (count > 1) return null;
    }
  }
  return count == 1 ? hit : null;
}
