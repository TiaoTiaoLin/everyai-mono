// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../domain/permissions.dart' show commandPaths;
import '../harness/everyai/shell_io.dart';
import 'host.dart';
import 'host_checks.dart';

/// The longest a check's command may run.
const _runLimit = Duration(minutes: 10);

Future<({int exit, String out})> _run(HostCheckContext c, String command, Future<void> cancel) async {
  if (c.run case final run?) return run(command, cancel);
  final shell = SessionShell(root: c.workingDir, sessionTag: c.sessionId, scratchDir: '${c.stateDir}/shell');
  final r = await shell.run(command, timeout: _runLimit, cancel: cancel);
  final note = r.timedOut ? '\n[Stopped after ${_runLimit.inMinutes} minutes.]' : '';
  return (exit: r.exitCode, out: '${r.output}$note');
}

Future<HostResult> hostCheck(HostCheckContext c, List<String> files, Future<void> cancel) async {
  final found = detectChecks(
    files,
    exists: (p) => FileSystemEntity.typeSync('${c.workingDir}/$p') != FileSystemEntityType.notFound,
    read: (p) {
      try {
        return File('${c.workingDir}/$p').readAsStringSync();
      } on Object {
        return null;
      }
    },
  );
  final missed = found.unmatched.isEmpty ? '' : 'No test found for: ${found.unmatched.join(', ')}.';
  if (found.runs.isEmpty) {
    return (
      text:
          '$missed The app knows Dart/Flutter, jest, vitest, Go, Cargo and pytest projects; run the right tests '
          'yourself.',
      isError: true,
    );
  }
  final out = <String>[];
  var failed = false;
  for (final run in found.runs) {
    final command = checkCommand(run);
    if (c.refusal(command) case final why?) return (text: '$why\n(command: $command)', isError: true);
    final r = await _run(c, command, cancel);
    failed |= r.exit != 0;
    out.add('\$ $command\n[exit ${r.exit}]\n${r.out.trimRight()}');
  }
  return (
    text: [failed ? 'Some tests failed.' : 'The tests passed.', if (missed.isNotEmpty) missed, ...out].join('\n\n'),
    isError: failed,
  );
}

String _tail(String out) => out.length > 3000 ? '…${out.substring(out.length - 3000)}' : out;

/// The files [command] names that exist under [dir], with their digests.
Map<String, String> _digests(String dir, String command) => {
  for (final p in commandPaths(command))
    if (!p.startsWith('/') && File('$dir/$p').existsSync()) p: '${sha256.convert(File('$dir/$p').readAsBytesSync())}',
};

Future<HostResult> hostBugCheck(HostCheckContext c, Map<String, Object?> args, Future<void> cancel) async {
  final file = File('${c.stateDir}/bug_check.json');
  Map<String, Object?> state;
  try {
    state = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
  } on Object {
    state = {};
  }
  void save() {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(jsonEncode(state));
  }

  final recorded = state['command'] as String? ?? '';
  final marker = state['expect'] as String? ?? '';
  switch (args['action']) {
    case 'reproduced':
      final command = (args['command'] as String? ?? '').trim();
      final expect = (args['expect'] as String? ?? '').trim();
      if (command.isEmpty) return (text: 'Error: give the command that shows the bug.', isError: true);
      if (c.refusal(command) case final why?) return (text: why, isError: true);
      final r = await _run(c, command, cancel);
      final shown = expect.isNotEmpty ? r.out.contains(expect) : r.exit != 0;
      if (!shown) {
        return (
          text:
              'Not reproduced: the app ran it and ${expect.isNotEmpty ? 'the output lacks "$expect"' : 'it exited 0'}. '
              'Find a command that really shows the bug, or ask the user how to reproduce it.\n${_tail(r.out)}',
          isError: true,
        );
      }
      state = {'command': command, 'expect': expect, 'files': _digests(c.workingDir, command), 'verified': false};
      save();
      return (
        text:
            'Reproduced: the app ran it and saw the bug${expect.isEmpty ? ' (it failed; make sure it fails on this '
                      'bug, not on a build or setup error)' : ''}. Fix it, then call bug_check verify.\n'
            '${_tail(r.out)}',
        isError: false,
      );
    case 'verify':
      if (recorded.isEmpty) {
        return (text: 'Error: call bug_check reproduced first, with the command that shows the bug.', isError: true);
      }
      final before = (state['files'] as Map<String, Object?>? ?? const {}).cast<String, Object?>();
      final now = _digests(c.workingDir, recorded);
      final changed = [
        for (final p in before.keys)
          if (now[p] != before[p]) p,
      ];
      if (changed.isNotEmpty) {
        return (
          text:
              'Not verified: the fix changed what reproduces the bug (${changed.take(8).join(', ')}). The original '
              'repro has to pass unchanged. Restore those files; if the test itself was wrong, ask the user, then '
              'call bug_check reproduced again with the corrected command.',
          isError: true,
        );
      }
      if (c.refusal(recorded) case final why?) return (text: why, isError: true);
      final r = await _run(c, recorded, cancel);
      final gone = marker.isNotEmpty ? !r.out.contains(marker) : r.exit == 0;
      if (!gone) {
        return (
          text:
              'Not verified: ${marker.isNotEmpty ? 'the output still shows "$marker"' : 'the command still fails '
                        '(exit ${r.exit})'}. If it now fails on something else, say what and why.\n${_tail(r.out)}',
          isError: true,
        );
      }
      state['verified'] = true;
      save();
      return (text: 'Verified: the app ran the repro again and the bug is gone.\n${_tail(r.out)}', isError: false);
    case 'status':
      if (recorded.isEmpty) return (text: 'Nothing recorded yet: start with bug_check reproduced.', isError: false);
      return (
        text: [
          'Repro command: $recorded',
          if (marker.isNotEmpty) 'Shows the bug when the output has: $marker',
          state['verified'] == true ? 'Verified: the fix passed.' : 'Not verified yet.',
        ].join('\n'),
        isError: false,
      );
    default:
      return (text: 'Error: action must be reproduced, verify or status.', isError: true);
  }
}
