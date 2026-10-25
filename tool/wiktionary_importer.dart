// tool/wiktionary_importer.dart
//
// Converts a kaikki.org English Wiktionary JSONL dump into the vendored
// lexicor SQLite layout, then packages it as the downloadable artifact.
//
// Usage:
//   dart run tool/wiktionary_importer.dart <input.jsonl> <out.sqlite> [--no-related]
//
// Import recipe (locked 2026-10-25):
//   - skips POS: character, punctuation, circumfix, infix, interfix,
//     article, symbol — and 'name' (proper names stay out of the core build)
//   - max 3 senses/entry, glosses cleaned ({{…}}/<…> stripped, [[…]] unwrapped),
//     capped at 250 chars, deduped per entry (case-insensitive)
//   - glosses starting with "Synonym of X" are dereferenced against the dump
//     (same-pos target preferred); unresolved targets keep the original text
//   - forms capped at 12/entry; synonyms/antonyms capped at 8/entry each
//
// BUILD-MACHINE REQUIREMENT: the `xz` CLI (xz-utils) must be on PATH — the
// importer shells out to it to produce the `<out>.xz` artifact.
//
// Outputs: `out`, `<out>.xz` (kept) and `<out>.sha256` (hex of the .xz bytes).
// A final stats line reports: entries= senses= forms= synonyms=
// deferred_unresolved= bad_lines= raw_bytes= xz_bytes=

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:lexicor/lexicor.dart';
import 'package:sqlite3/sqlite3.dart';

/// Part-of-speech ids excluded from the core dictionary build.
const Set<String> _skipPos = {
  'character',
  'punctuation',
  'circumfix',
  'infix',
  'interfix',
  'article',
  'symbol',
  'name', // proper names excluded from the core build (2026-10-25 decision)
};

const int _maxSensesPerEntry = 3;
const int _maxTags = 6;
const int _maxGlossChars = 250;
const int _maxFormsPerEntry = 12;
const int _maxRelatedPerKind = 8;
const int _batchSize = 20000;

Future<void> main(List<String> args) async {
  final files = args.where((a) => !a.startsWith('--')).toList();
  if (files.length != 2) {
    stderr.writeln(
      'usage: dart run tool/wiktionary_importer.dart '
      '<input.jsonl> <out.sqlite> [--no-related]',
    );
    exitCode = 2;
    return;
  }
  await importWiktionary(
    source: files[0],
    out: files[1],
    withRelated: !args.contains('--no-related'),
  );
}

/// Streams [source] (kaikki.org JSONL) into a SQLite database at [out],
/// then packages `out.xz` + `out.sha256`. See the file header for the recipe.
Future<void> importWiktionary({
  required String source,
  required String out,
  bool withRelated = true,
}) async {
  final outFile = File(out);
  final xzFile = File('$out.xz');
  final shaFile = File('$out.sha256');
  // Fresh import: stale artifacts from a previous run must not linger.
  for (final f in [outFile, xzFile, shaFile]) {
    if (f.existsSync()) f.deleteSync();
  }

  final db = sqlite3.open(out);
  final importer = _Importer(db, source, withRelated: withRelated);
  try {
    db.execute('PRAGMA journal_mode = OFF');
    db.execute('PRAGMA synchronous = OFF');
    db.execute(Schema.createSql);
    db.execute('BEGIN');
    await importer.run();
    db.execute('COMMIT');
    db.execute('ANALYZE');
  } finally {
    db.close();
  }

  await _packageArtifact(xzFile, out, shaFile);

  // A CLI tool's mandated report of the numbers the 65 MB gate checks.
  // ignore: avoid_print
  print(
    'entries=${importer.entries} senses=${importer.senses} '
    'forms=${importer.forms} synonyms=${importer.related} '
    'deferred_unresolved=${importer.deferredUnresolved} '
    'bad_lines=${importer.badLines} '
    'raw_bytes=${outFile.existsSync() ? outFile.lengthSync() : 0} '
    'xz_bytes=${xzFile.existsSync() ? xzFile.lengthSync() : 0}',
  );
}

Future<void> _packageArtifact(File xzFile, String out, File shaFile) async {
  ProcessResult result;
  try {
    result = await Process.run('xz', ['-9', '-T0', '-k', out]);
  } on ProcessException {
    throw const ProcessException(
      'xz',
      ['-9', '-T0', '-k'],
      'packaging the dictionary needs the xz CLI on PATH '
      '(xz-utils); install it and rerun the importer.',
      -1,
    );
  }
  if (result.exitCode != 0 || !xzFile.existsSync()) {
    final stderrText = result.stderr is String
        ? result.stderr as String
        : result.stderr.toString();
    throw ProcessException(
      'xz',
      ['-9', '-T0', '-k', out],
      'xz exited ${result.exitCode} packaging $out: $stderrText',
      result.exitCode,
    );
  }
  final digest = sha256.convert(xzFile.readAsBytesSync());
  shaFile.writeAsStringSync(digest.toString());
}

/// A "Synonym of X" sense dereferenced in pass 2.
class _DeferredSense {
  final int wordId;
  final int ordinal;
  final String tags;
  final String pos;
  final String target; // lowercased dereference target, X
  final String originalGloss; // full cleaned gloss (fallback when unresolved)

  _DeferredSense(
      this.wordId, this.ordinal, this.tags, this.pos, this.target,
      this.originalGloss);
}

/// Buffers rows and flushes them to a prepared statement in batches.
class _Batch {
  final PreparedStatement stmt;
  final List<List<Object?>> rows = [];

  _Batch(this.stmt);

  void add(List<Object?> row) {
    rows.add(row);
    // Bound memory: flush every _batchSize rows (see also _flushAllBatches at
    // pass boundaries).
    if (rows.length >= _batchSize) {
      flush();
    }
  }

  void flush() {
    if (rows.isEmpty) return;
    for (final row in rows) {
      stmt.execute(row);
    }
    rows.clear();
  }
}

class _Importer {
  final Database _db;
  final String _source;
  final bool _withRelated;

  int entries = 0;
  int senses = 0;
  int forms = 0;
  int related = 0;
  int badLines = 0;
  int deferredUnresolved = 0;

  final List<_DeferredSense> _deferred = [];
  int _wordId = 0;

  _Importer(this._db, this._source, {required bool withRelated})
      : _withRelated = withRelated;

  late final _Batch _wordStmt =
      _Batch(_db.prepare('INSERT INTO words VALUES (?, ?, ?, ?)'));
  late final _Batch _senseStmt =
      _Batch(_db.prepare('INSERT INTO senses VALUES (?, ?, ?, ?)'));
  late final _Batch _formStmt =
      _Batch(_db.prepare('INSERT OR IGNORE INTO forms VALUES (?, ?, ?)'));
  late final _Batch _relatedStmt =
      _Batch(_db.prepare('INSERT OR IGNORE INTO related VALUES (?, ?, ?)'));

  Future<void> run() async {
    await _sensesPass();
    _flushAllBatches();
    await _deferredPass();
    _flushAllBatches();
  }

  void _flushAllBatches() {
    for (final batch in [_wordStmt, _senseStmt, _formStmt, _relatedStmt]) {
      batch.flush();
    }
  }

  // ---- pass 1: words, inline senses, forms, related ------------------------

  Future<void> _sensesPass() async {
    final lines = File(_source)
        .openRead()
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final line in lines) {
      if (line.isEmpty) continue;
      final Object? decoded;
      try {
        decoded = jsonDecode(line);
      } on FormatException {
        badLines++;
        continue;
      }
      if (decoded is! Map<String, dynamic>) continue;
      final String word = (decoded['word'] as String?) ?? '';
      final String posRaw = (decoded['pos'] as String?) ?? '';
      if (word.isEmpty || posRaw.isEmpty || _skipPos.contains(posRaw)) {
        continue;
      }
      // Store the canonical kaikki POS id ('adj', not 'adjective' and other
      // dump spellings); unknown ids degrade to SpeechPart.other.id.
      final String pos = Schema.posFromWiki(posRaw).id;

      final rawSenses = decoded['senses'] as List<dynamic>? ?? const [];
      final kept =
          <({int ordinal, String tags, String gloss})>[];
      final seenGlosses = <String>{};
      for (final raw in rawSenses) {
        if (kept.length >= _maxSensesPerEntry) break;
        final sense = raw as Map<String, dynamic>;
        final glossList = sense['glosses'] as List<dynamic>? ?? const [];
        String? gloss = _cleanGloss(
            glossList.isEmpty ? null : glossList.first.toString());
        if (gloss != null && gloss.length > _maxGlossChars) {
          gloss = gloss.substring(0, _maxGlossChars);
        }
        if (gloss == null || gloss.toLowerCase() == word.toLowerCase()) {
          continue;
        }
        if (!seenGlosses.add(gloss.toLowerCase())) continue;
        final tagList = sense['tags'] as List<dynamic>? ?? const [];
        final tags = tagList
            .take(_maxTags)
            .map((t) => t.toString())
            .join(',');
        kept.add((ordinal: kept.length, tags: tags, gloss: gloss));
      }
      if (kept.isEmpty) continue;

      final wordId = ++_wordId;
      _wordStmt.add([wordId, word, pos, 0]);
      entries++;

      for (final sense in kept) {
        final gloss = sense.gloss;
        if (gloss.startsWith('Synonym of ')) {
          _deferred.add(
            _DeferredSense(
              wordId,
              sense.ordinal,
              sense.tags,
              pos,
              _synonymTarget(gloss).toLowerCase(),
              gloss,
            ),
          );
        } else {
          _senseStmt.add([wordId, sense.ordinal, sense.tags, gloss]);
        }
        senses++;
      }

      final rawForms = decoded['forms'] as List<dynamic>? ?? const [];
      final lowerWord = word.toLowerCase();
      for (final rawForm in rawForms.take(_maxFormsPerEntry)) {
        final form = ((rawForm as Map<String, dynamic>)['form'] as String?) ??
            '';
        if (form.isEmpty || form.toLowerCase() == lowerWord) continue;
        _formStmt
            .add([form, wordId, 0]);
        forms++;
      }

      if (!_withRelated) continue;
      _addRelated(wordId, lowerWord,
          decoded['synonyms'] as List<dynamic>? ?? const [], 'synonym');
      _addRelated(wordId, lowerWord,
          decoded['antonyms'] as List<dynamic>? ?? const [], 'antonym');
    }
  }

  void _addRelated(
    int wordId,
    String lowerWord,
    List<dynamic> rawRelated,
    String kind,
  ) {
    for (final rawEntry in rawRelated.take(_maxRelatedPerKind)) {
      final relatedWord =
          ((rawEntry as Map<String, dynamic>)['word'] as String?) ?? '';
      if (relatedWord.isEmpty ||
          relatedWord.toLowerCase() == lowerWord) {
        continue;
      }
      _relatedStmt.add([wordId, kind, relatedWord]);
      related++;
    }
  }

  // ---- pass 2: dereference "Synonym of X" senses ---------------------------

  Future<void> _deferredPass() async {
    if (_deferred.isEmpty) return;

    // target (lowercase) → deferred senses pointing at it.
    final byTarget = <String, List<_DeferredSense>>{};
    for (final d in _deferred) {
      byTarget.putIfAbsent(d.target, () => []).add(d);
    }

    // For each target: first same-pos gloss, then first any-pos gloss.
    final samePos = <String, String>{};
    final anyPos = <String, String>{};
    final lines = File(_source)
        .openRead()
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final line in lines) {
      if (byTarget.isEmpty) break;
      if (line.isEmpty) continue;
      final Object? decoded;
      try {
        decoded = jsonDecode(line);
      } on FormatException {
        continue;
      }
      if (decoded is! Map<String, dynamic>) continue;
      final String wordLower =
          ((decoded['word'] as String?) ?? '').toLowerCase();
      final List<_DeferredSense>? waiting = byTarget[wordLower];
      if (waiting == null) continue;
      final String pos = ((decoded['pos'] as String?) ?? '').toLowerCase();

      final rawSenses = decoded['senses'] as List<dynamic>? ?? const [];
      String? gloss;
      for (final raw in rawSenses) {
        final glossList = (raw as Map<String, dynamic>)['glosses']
            as List<dynamic>? ?? const [];
        gloss = _cleanGloss(
            glossList.isEmpty ? null : glossList.first.toString());
        if (gloss != null && gloss.length > _maxGlossChars) {
          gloss = gloss.substring(0, _maxGlossChars);
        }
        if (gloss != null) break;
      }
      if (gloss == null) continue;

      if (!anyPos.containsKey(wordLower)) {
        anyPos[wordLower] = gloss;
      }
      if (!samePos.containsKey(wordLower) &&
          waiting.any(
            (d) => d.pos == Schema.posFromWiki(pos).id,
          )) {
        samePos[wordLower] = gloss;
      }
      // Stop caring about a target once same-pos lookup is resolved.
      if (samePos.containsKey(wordLower)) {
        byTarget.remove(wordLower);
      }
    }

    for (final d in _deferred) {
      final resolved = samePos[d.target] ?? anyPos[d.target];
      if (resolved == null) {
        deferredUnresolved++;
        _senseStmt.add([d.wordId, d.ordinal, d.tags, d.originalGloss]);
      } else {
        _senseStmt.add([d.wordId, d.ordinal, d.tags, resolved]);
      }
      // Deferred senses were already counted in pass 1.
    }
  }
}

/// Strips wiki template/tag markup and whitespace noise from a raw gloss.
String? _cleanGloss(String? raw) {
  if (raw == null) return null;
  var g = raw.replaceAll(RegExp(r'\{\{[^{}]*\}\}|<[^>]+>'), '');
  g = g.replaceAll('[[', '').replaceAll(']]', '');
  g = g.replaceAll(RegExp(r'\s+'), ' ').trim();
  return g.isEmpty ? null : g;
}

/// Extracts the dereference target X from a "Synonym of X"-style cleaned
/// gloss: remainder after the prefix, minus a trailing parenthetical.
String _synonymTarget(String gloss) {
  final remainder = gloss.substring('Synonym of '.length).trim();
  var x = remainder;
  if (x.endsWith(')')) {
    final open = x.lastIndexOf('(');
    if (open > 0) x = x.substring(0, open).trim();
  }
  return x.isEmpty ? remainder : x;
}
