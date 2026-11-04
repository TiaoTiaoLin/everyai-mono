// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../harness/everyai/script_io.dart' show findDeno;
import 'workflow_bridge.dart';
import 'workflow_prelude.dart';

// The Deno process and its line protocol, as ScriptRunner.run runs them
// (same flags, no permissions, an empty environment, the cache in the run's
// folder). TODO: make ScriptRunner use this bridge once run_script's own
// changes have landed, so there is one copy.

/// One printed line's most characters (a log row, not a file).
const _maxLine = 4000;

Future<WorkflowBridge> startWorkflowBridge({
  required String dir,
  required String source,
  required Map<String, Object?> args,
}) async {
  final deno = findDeno() ?? (throw StateError('Workflows need Deno, which this install of the app is missing.'));
  final runDir = Directory(dir)..createSync(recursive: true);
  File('${runDir.path}/main.js').writeAsStringSync(workflowModule(source));
  File('${runDir.path}/prelude.js').writeAsStringSync(workflowPrelude(args));
  final process = await Process.start(
    deno,
    ['run', '--no-prompt', '--no-config', '--no-lock', '--no-remote', '--no-npm', '--quiet', 'prelude.js'],
    workingDirectory: runDir.path,
    includeParentEnvironment: false,
    environment: {'DENO_DIR': '${runDir.path}/cache', 'DENO_NO_UPDATE_CHECK': '1', 'NO_COLOR': '1'},
  );
  return _DenoBridge(process);
}

final class _DenoBridge implements WorkflowBridge {
  _DenoBridge(this._process) {
    // Writes after the script ended fail; nothing waits on them.
    unawaited(_process.stdin.done.catchError((_) {}));
    String clip(String l) => l.length > _maxLine ? '${l.substring(0, _maxLine)}…' : l;
    final out = _process.stdout.transform(utf8.decoder).transform(const LineSplitter()).forEach((line) {
      if (line.startsWith('\x1e')) {
        try {
          if (jsonDecode(line.substring(1)) case final Map<String, Object?> req) return _requests.add(req);
        } on FormatException {
          // Printed output after all.
        }
      }
      _output.add(clip(line));
    });
    final err = _process.stderr.transform(utf8.decoder).transform(const LineSplitter()).forEach((l) {
      _output.add(clip(l));
    });
    exit = _process.exitCode.then((code) async {
      _closed = true;
      await Future.wait([out, err]);
      unawaited(_process.stdin.close().catchError((_) {}));
      await _requests.close();
      await _output.close();
      return code;
    });
  }

  final Process _process;
  final _requests = StreamController<Map<String, Object?>>();
  final _output = StreamController<String>();
  var _closed = false;

  @override
  Stream<Map<String, Object?>> get requests => _requests.stream;
  @override
  Stream<String> get output => _output.stream;
  @override
  late final Future<int> exit;

  @override
  void reply(Object? id, {Object? result, String? error}) {
    if (_closed) return;
    try {
      _process.stdin.writeln(jsonEncode({'id': id, if (error != null) 'error': error else 'result': result}));
    } on Object {
      // The script already ended.
    }
  }

  @override
  void kill() => _process.kill(ProcessSignal.sigkill);
}

Future<String> readJournalFile(String path) async {
  final f = File(path);
  return await f.exists() ? f.readAsString() : '';
}

Future<void> appendJournalFile(String path, String line) async {
  final f = File(path);
  await f.parent.create(recursive: true);
  await f.writeAsString('$line\n', mode: FileMode.append, flush: true);
}

Future<List<String>> listJournalFiles(String dir) async {
  final d = Directory(dir);
  if (!await d.exists()) return const [];
  final files = await d.list().where((e) => e is File && e.path.endsWith('.jsonl')).map((e) => e.path).toList();
  return files..sort();
}
