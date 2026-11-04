// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';
import 'dart:io';

import '../../domain/phases.dart' show PhaseFlow;
import 'tools_io.dart' show resolvePath;

/// The tests and repro scripts a bug was reproduced with by [command]
/// (paths relative to [root]): tracked or new test files the repro touches,
/// `.everyai/scratch/` scripts, and the files the command names, absolute
/// ones under [root] included. Bug fix mode and the host's bug_check both
/// snapshot these so the fix can't edit the repro into passing.
Future<Set<String>> reproPaths(String root, String command, {String output = ''}) async {
  final paths = <String>{};
  // Tracked tests count when the repro touches them: changed or new ones
  // (written to reproduce it) and ones its output names. A test elsewhere
  // in the repository isn't part of the repro, so editing it is fine.
  try {
    final r = await Process.run('git', ['ls-files', '-co', '--exclude-standard'], workingDirectory: root);
    final st = await Process.run('git', ['status', '--porcelain', '--untracked-files=all'], workingDirectory: root);
    final dirty = {
      if (st.exitCode == 0)
        for (final line in const LineSplitter().convert('${st.stdout}'))
          if (line.length > 3) line.substring(3).split(' -> ').last.replaceAll('"', ''),
    };
    if (r.exitCode == 0) {
      for (final p in const LineSplitter().convert('${r.stdout}').where(PhaseFlow.isReproPath).take(5000)) {
        if (dirty.contains(p) || (output.isNotEmpty && output.contains(p.split('/').last))) paths.add(p);
      }
    }
  } on Object {
    // Not git: the scratch scripts and named files still count.
  }
  final scratch = Directory('$root/.everyai/scratch');
  if (scratch.existsSync()) {
    for (final e in scratch.listSync(recursive: true).whereType<File>().take(500)) {
      final rel = e.path.substring(root.length + 1);
      if (PhaseFlow.isReproPath(rel)) paths.add(rel);
    }
  }
  for (final word in command.split(RegExp(r'\s+'))) {
    final w = word.replaceAll(RegExp('^[\'"]+|[\'"]+\$'), '');
    if (w.isEmpty || w.startsWith('-')) continue;
    final full = resolvePath(root, w);
    if (full.startsWith('$root/') && File(full).existsSync()) paths.add(full.substring(root.length + 1));
  }
  return paths;
}
