// Tests for tool/wiktionary_importer.dart — the kaikki JSONL → SQLite importer.
//
// Fixture: test/tool/fixtures/kaikki_subset.jsonl (9 entries + 1 truncated line).
// The DB is built once in setUpAll into a scratch dir; artifact checks (.xz,
// .sha256) run against that same import.

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../tool/wiktionary_importer.dart';

void main() {
  late Directory scratch;
  late Database db;
  late Map<String, String> stats; // parsed stats key=value pairs
  late List<String> printed;

  String statsLine() {
    final matches = printed.where((l) => l.startsWith('entries='));
    return matches.isEmpty ? '' : matches.last;
  }

  setUpAll(() async {
    scratch = await Directory.systemTemp.createTemp('wikt_importer_test');
    final source =
        File('test/tool/fixtures/kaikki_subset.jsonl').absolute.path;
    final out = File('${scratch.path}/fixture.sqlite').absolute.path;

    printed = [];
    await runZonedGuarded(
      () => importWiktionary(source: source, out: out),
      (_, _) {},
      zoneSpecification: ZoneSpecification(
        print: (_, _, _, String line) {
          printed.add(line);
        },
      ),
    );

    stats = {};
    for (final part in statsLine().split(' ')) {
      final kv = part.split('=');
      if (kv.length == 2) stats[kv[0]] = kv[1];
    }

    db = sqlite3.open(out);
  });

  tearDownAll(() {
    db.close();
    scratch.delete(recursive: true);
  });

  test('names skipped', () {
    expect(db.select("SELECT COUNT(*) c FROM words WHERE pos = 'name'")[0]['c'],
        0);
    expect(
      db
          .select(
              "SELECT COUNT(*) c FROM senses s JOIN words w ON w.word_id = s.word_id "
              "WHERE w.word = 'sus' AND s.gloss LIKE '%Iran%'")[0]['c'],
      0,
    );
  });

  test('sus senses present', () {
    final glosses =
        db
            .select(
              "SELECT s.gloss FROM senses s JOIN words w ON w.word_id = s.word_id "
              "WHERE w.word = 'sus'",
            )
            .map((r) => r['gloss'] as String)
            .toSet();
    expect(glosses.contains('Subjective; British slang for suspicious.'), true);
    expect(glosses.contains('Suspicious; untrustworthy.'), true);
  });

  test('dereference falls back to original gloss, counts unresolved', () {
    expect(stats['deferred_unresolved'], '1');
    final biff = db.select(
      "SELECT s.gloss FROM senses s JOIN words w ON w.word_id = s.word_id "
      "WHERE w.word = 'biff'",
    );
    expect(biff, hasLength(1));
    expect(
      biff[0]['gloss'],
      'Synonym of Nowhereville (an entry that never appears)',
      reason:
          'unresolved dereference keeps the original full gloss text (never empty)',
    );
  });

  test('cap 3 senses: run verb contributes exactly 3 glosses', () {
    final count = db.select(
      "SELECT COUNT(*) c FROM senses s JOIN words w ON w.word_id = s.word_id "
      "WHERE w.word = 'run' AND w.pos = 'verb'",
    )[0]['c'];
    expect(count, 3);
    final hasFourth = db
        .select(
          "SELECT COUNT(*) c FROM senses s JOIN words w ON w.word_id = s.word_id "
          "WHERE w.word = 'run' AND s.gloss LIKE '%Fourth sense%'",
        )[0]['c'];
    expect(hasFourth, 0);
  });

  test('forms: ran and geese resolve to their lemmas', () {
    int runId() => db
        .select("SELECT word_id FROM words WHERE word = 'run' AND pos = 'verb'")
        .first['word_id'] as int;
    int gooseId() =>
        db.select("SELECT word_id FROM words WHERE word = 'goose'")
            .first['word_id'] as int;
    expect(
      db.select("SELECT word_id FROM forms WHERE form = 'ran'").map(
            (r) => r['word_id'],
          ),
      contains(runId()),
    );
    expect(
      db.select("SELECT word_id FROM forms WHERE form = 'geese'").map(
            (r) => r['word_id'],
          ),
      contains(gooseId()),
    );
    expect(
      db.select(
          "SELECT COUNT(*) c FROM forms f JOIN words w ON w.word_id = f.word_id "
          "WHERE w.word = 'run' AND w.pos = 'verb'")[0]['c'],
      2,
    );
  });

  test('related: sus adjective has synonym shifty', () {
    int susAdjId() => db
        .select("SELECT word_id FROM words WHERE word = 'sus' AND pos = 'adj'")
        .first['word_id'] as int;
    final rows = db.select(
      "SELECT kind, word FROM related WHERE word_id = ${susAdjId()}",
    );
    expect(rows, hasLength(1));
    expect(rows[0]['kind'], 'synonym');
    expect(rows[0]['word'], 'shifty');
  });

  test('withRelated:false produces zero related rows', () async {
    final out2 = File('${scratch.path}/norelated.sqlite').absolute.path;
    printed = [];
    await runZonedGuarded(
      () => importWiktionary(
        source: 'test/tool/fixtures/kaikki_subset.jsonl',
        out: out2,
        withRelated: false,
      ),
      (_, _) {},
      zoneSpecification: ZoneSpecification(
        print: (_, _, _, String line) {
          printed.add(line);
        },
      ),
    );
    final db2 = sqlite3.open(out2);
    addTearDown(db2.close);
    expect(db2.select('SELECT COUNT(*) c FROM related')[0]['c'], 0);
  });

  test('stats line + artifacts (.xz exists, .sha256 matches)', () async {
    final xz = File('${scratch.path}/fixture.sqlite.xz');
    final shaFile = File('${scratch.path}/fixture.sqlite.sha256');
    expect(xz.existsSync(), true);
    expect(shaFile.existsSync(), true);
    expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(shaFile.readAsStringSync()),
        true, reason: '.sha256 must be 64 hex chars');
    final digest = sha256.convert(xz.readAsBytesSync());
    expect(shaFile.readAsStringSync(), digest.toString());

    expect(stats['bad_lines'], '1', reason: 'fixture ends with 1 broken line');
    expect(stats['deferred_unresolved'], '1');
  });

  test('bad line skipped: no broken word row', () {
    expect(
      db.select("SELECT COUNT(*) c FROM words WHERE word = 'broken'")[0]['c'],
      0,
    );
  });

  test('entry senses are tagged (first 6 tags, comma-joined)', () {
    final tags = db
        .select(
          "SELECT s.tags FROM senses s JOIN words w ON w.word_id = s.word_id "
          "WHERE w.word = 'run' AND s.gloss = 'To move swiftly.'",
        )
        .first['tags'] as String;
    expect(tags, 'intransitive');
  });
}
