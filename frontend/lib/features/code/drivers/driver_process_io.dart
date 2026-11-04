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

final _live = <_Process>{};

Future<void> closeAllDriverProcesses() => Future.wait([for (final p in _live.toList()) p.close()]);

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
    _live.add(this);
    unawaited(
      _process.exitCode.then((_) {
        _exited = true;
        _live.remove(this);
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
    _live.remove(this);
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
    final process = await Process.start(path, versionArgs, environment: shell.env);
    unawaited(process.stderr.drain<void>());
    final out = process.stdout.transform(const Utf8Decoder(allowMalformed: true)).join();
    try {
      await process.exitCode.timeout(versionTimeout);
    } on TimeoutException {
      // A CLI that waits on a prompt (an update offer) would stay running.
      process.kill(ProcessSignal.sigkill);
      return DriverStatus(installed: true, path: path, problem: "$command didn't say its version.");
    }
    final first = (await out).trim().split('\n').first.trim();
    return DriverStatus(installed: true, path: path, version: first.isEmpty ? null : first);
  } on Object catch (e) {
    return DriverStatus(installed: true, path: path, problem: "Couldn't run $command: $e");
  }
}

/// How long `--version` may take before the check gives up on it.
const versionTimeout = Duration(seconds: 4);

Future<void> reloadShellEnv() => ShellEnv.reload();

Future<void> loadShellEnv() => ShellEnv.load();

Future<String?> _which(String command) async =>
    findOnPath(command, (await ShellEnv.load()).env[Platform.isWindows ? _windowsPathKey : 'PATH'] ?? '');

String get _windowsPathKey =>
    Platform.environment.keys.firstWhere((k) => k.toUpperCase() == 'PATH', orElse: () => 'Path');

/// The first file named [command] in the directories of [path] (or
/// [command] itself when it is a path), without starting a process. On
/// Windows each [pathExt] extension is tried too. [isFile] tells a file
/// that can run from a directory or a missing one (tests).
String? findOnPath(String command, String path, {bool? windows, String? pathExt, bool Function(String path)? isFile}) {
  final win = windows ?? Platform.isWindows;
  final runs = isFile ?? (win ? (p) => File(p).existsSync() : _isExecutable);
  final sep = win ? '\\' : '/';
  final exts = win
      ? [
          '',
          ...(pathExt ?? Platform.environment['PATHEXT'] ?? '.COM;.EXE;.BAT;.CMD')
              .split(';')
              .where((e) => e.isNotEmpty),
        ]
      : const [''];
  final named = command.contains('/') || (win && command.contains('\\'));
  final dirs = named ? const [''] : path.split(win ? ';' : ':').where((d) => d.isNotEmpty);
  for (final dir in dirs) {
    for (final ext in exts) {
      final candidate = named ? '$command$ext' : '${dir.endsWith(sep) ? dir : '$dir$sep'}$command$ext';
      if (runs(candidate)) return candidate;
    }
  }
  return null;
}

bool _isExecutable(String path) {
  final stat = FileStat.statSync(path);
  return stat.type == FileSystemEntityType.file && stat.mode & 0x49 != 0;
}
