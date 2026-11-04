// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../harness/everyai/shell_io.dart' show ShellEnv, killTree;
import '../harness/session_processes.dart' show registerDriverRoot, sessionEnvVar, unregisterDriverRoot;
import 'driver.dart';
import 'driver_process.dart';

Future<DriverProcess> spawnDriver({
  required String executable,
  required List<String> args,
  required String cwd,
  required String sessionTag,
  required String logPath,
  Map<String, String> env = const {},
}) async {
  final shell = await ShellEnv.load();
  final process = await Process.start(
    executable,
    args,
    workingDirectory: cwd,
    environment: {...shell.env, ...env, sessionEnvVar: sessionTag},
  );
  File(logPath).parent.createSync(recursive: true);
  registerDriverRoot(sessionTag, process.pid);
  return _Process(process, sessionTag, File(logPath).openWrite(mode: FileMode.append));
}

final class _Process implements DriverProcess {
  _Process(this._process, this._tag, this._log) {
    _process.stderr.transform(const Utf8Decoder(allowMalformed: true)).listen((s) {
      _log.write(s);
      _tail.write(s);
      if (_tail.length > 4000) {
        final keep = _tail.toString().substring(_tail.length - 2000);
        _tail
          ..clear()
          ..write(keep);
      }
    }, onDone: () => unawaited(_log.close()));
    // A write after the CLI died fails on the pipe; nobody else listens.
    unawaited(_process.stdin.done.catchError((Object _) {}));
    unawaited(
      _process.exitCode.then((_) {
        _exited = true;
        unregisterDriverRoot(_tag, pid);
      }),
    );
  }

  final Process _process;
  final String _tag;
  final IOSink _log;
  final _tail = StringBuffer();
  var _closed = false;
  var _exited = false;

  @override
  late final Stream<String> lines = _process.stdout
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter())
      .asBroadcastStream();

  @override
  int get pid => _process.pid;

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  String get lastError => _tail.toString();

  @override
  void send(String line) {
    if (!_closed && !_exited) _process.stdin.writeln(line);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    unregisterDriverRoot(_tag, pid);
    await killTree(pid);
  }
}

Future<DriverStatus> detectCli(
  String command, {
  List<String> versionArgs = const ['--version'],
  Future<String?> Function(String command)? which,
}) async {
  final path = await (which ?? _which)(command);
  if (path == null) return const DriverStatus();
  try {
    final shell = await ShellEnv.load();
    final res = await Process.run(
      path,
      versionArgs,
      environment: shell.env,
      stdoutEncoding: const Utf8Codec(allowMalformed: true),
    ).timeout(const Duration(seconds: 10));
    final first = '${res.stdout}'.trim().split('\n').first.trim();
    return DriverStatus(installed: true, path: path, version: first.isEmpty ? null : first);
  } on Object catch (e) {
    return DriverStatus(installed: true, path: path, problem: "Couldn't run $command: $e");
  }
}

Future<String?> _which(String command) async {
  if (command.startsWith('/')) return File(command).existsSync() ? command : null;
  try {
    final shell = await ShellEnv.load();
    final res = await Process.run('/usr/bin/which', [command], environment: shell.env);
    final path = '${res.stdout}'.trim().split('\n').first.trim();
    return res.exitCode == 0 && path.isNotEmpty ? path : null;
  } on Object {
    return null;
  }
}
