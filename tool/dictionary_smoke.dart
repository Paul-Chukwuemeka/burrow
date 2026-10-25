// tool/dictionary_smoke.dart
//
// Sanity pass over the REAL production artifact (Task 6 Step 4):
//   dart run tool/dictionary_smoke.dart build/dictionary/dictionary.sqlite
//
// Expectations pinning the build recipe:
//   sus          → primary must be a "suspicious"-family sense (NOT a
//                  place-name entry: `pos == 'name'` rows are excluded).
//   ran          → primary must be a base-verb "run" sense (forms-table
//                  resolution puts the base word's senses first).
//   run / goated / Kubernetes → non-empty results.

import 'dart:io';

import 'package:lexicor/lexicor.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln(
      'usage: dart run tool/dictionary_smoke.dart <dictionary.sqlite>',
    );
    return;
  }

  final engine = await Lexicor.init(customPath: args[0], withDefinitions: true);

  const queries = ['sus', 'run', 'ran', 'goated', 'Kubernetes'];
  for (final query in queries) {
    final result = engine.lookup(query);
    final primary = result.primary;
    // A verification script's mandated report of what the reader will see.
    // ignore: avoid_print
    print(
      '$query -> ${result.isEmpty ? "(EMPTY)" : primary!.definition ?? "(no definition)"}',
    );
  }

  engine.close();
}
