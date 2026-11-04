// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_pty/flutter_pty.dart';

import '../harness/everyai/shell_io.dart' show ShellEnv, killTree;
import '../harness/harness.dart' show HarnessError;
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

final _live = <DriverProcess>{};

Future<void> closeAllDriverProcesses() => Future.wait([for (final p in _live.toList()) p.close()]);

/// A program started under a terminal: its pid, exit code and what it
/// wrote to the terminal.
typedef TtyProgram = ({int pid, Future<int> exitCode, Stream<List<int>> output});

/// Starts [executable] [args] in [cwd] with [env] (exactly) under a pty;
/// tests start it with plain pipes.
typedef TtyStart = Future<TtyProgram> Function(
  String executable,
  List<String> args,
  String cwd,
  Map<String, String> env,
);

Future<TtyProgram> _ptyStart(String executable, List<String> args, String cwd, Map<String, String> env) async {
  final pty = Pty.start(executable, arguments: args, workingDirectory: cwd, environment: env);
  return (pid: pty.pid, exitCode: pty.exitCode, output: pty.output);
}

/// The shell line that runs the CLI ("$0" "$@") on the pipes named in the
/// environment, its stderr appended to the log. `exec` keeps the pty's
/// session and terminal for the CLI itself.
const _onPipes = r'exec "$0" "$@" <"$EVERYAI_ACP_IN" >"$EVERYAI_ACP_OUT" 2>>"$EVERYAI_ACP_LOG"';

Future<DriverProcess> spawnDriverTty({
  required String executable,
  required List<String> args,
  required String cwd,
  required String sessionTag,
  required String logPath,
  Map<String, String> env = const {},
  TtyStart start = _ptyStart,
}) async {
  if (Platform.isWindows) {
    throw const HarnessError("This agent needs a terminal, which the app can't give it on Windows.");
  }
  final dir = File(logPath).parent..createSync(recursive: true);
  final input = '${dir.path}/acp.in';
  final output = '${dir.path}/acp.out';
  // Left behind by a crash: made again.
  for (final f in [input, output]) {
    if (FileSystemEntity.typeSync(f, followLinks: false) != FileSystemEntityType.notFound) File(f).deleteSync();
  }
  final made = await Process.run('mkfifo', [input, output]);
  if (made.exitCode != 0) throw HarnessError("Couldn't make the pipes for the agent: ${'${made.stderr}'.trim()}");
  final shell = await ShellEnv.load();
  // Only what this run writes counts as its last words.
  final logStart = _length(logPath);
  final TtyProgram program;
  try {
    program = await start(
      '/bin/sh',
      ['-c', _onPipes, executable, ...args],
      cwd,
      {
        ...shell.env,
        ...env,
        sessionEnvVar: sessionTag,
        'EVERYAI_ACP_IN': input,
        'EVERYAI_ACP_OUT': output,
        'EVERYAI_ACP_LOG': logPath,
      },
    );
  } on Object {
    _removePipes(input, output);
    rethrow;
  }
  registerDriverRoot(sessionTag, program.pid);
  return _TtyProcess(program, sessionTag, logPath, logStart, input, output);
}

int _length(String path) {
  try {
    return File(path).lengthSync();
  } on FileSystemException {
    return 0;
  }
}

void _removePipes(String input, String output) {
  for (final f in [input, output]) {
    try {
      File(f).deleteSync();
    } on FileSystemException {
      // Already gone.
    }
  }
}

/// A CLI under a pty with its JSON on named pipes ([spawnDriverTty]).
/// Both ends are opened at once; an open waits for the other side on Dart's
/// IO threads, so the UI never blocks. When the CLI is gone, each pipe is
/// held open read-write (which never waits) until our own open is through,
/// so nothing waits on a CLI that never opened its side.
final class _TtyProcess implements DriverProcess {
  _TtyProcess(this._program, this._tag, this._logPath, this._logStart, this._input, this._output) {
    // Whatever it writes to the terminal, so a full pty buffer can't stall it.
    // Its own file: sh appends the CLI's stderr to the log, which a second
    // writer without O_APPEND would overwrite.
    _tty = File('${File(_logPath).parent.path}/tty.log').openWrite();
    _ttyOutput = _program.output.listen((d) {
      if (!_released) _tty.add(d);
    }, onError: (Object _) {});
    _reader = File(_output).open();
    // Write-only, so a write after the CLI is gone fails instead of filling the pipe.
    _writer = File(_input).open(mode: FileMode.writeOnly);
    for (final f in [_reader, _writer]) {
      unawaited(f.then((_) {}, onError: (Object _) {}));
    }
    _live.add(this);
    unawaited(
      _program.exitCode.then((_) async {
        _exited = true;
        _live.remove(this);
        unregisterDriverRoot(_tag, pid);
        await _unblock();
        await _release();
      }),
    );
  }

  final TtyProgram _program;
  final String _tag;
  final String _logPath;
  final String _input;
  final String _output;
  final int _logStart;
  late final IOSink _tty;
  late final StreamSubscription<List<int>> _ttyOutput;
  late final Future<RandomAccessFile> _reader;
  late final Future<RandomAccessFile> _writer;
  Future<void> _writes = Future.value();
  Future<void>? _unblocking;
  Future<void>? _releasing;
  var _released = false;
  var _closed = false;
  var _exited = false;

  @override
  late final Stream<String> lines = _read()
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter())
      .asBroadcastStream();

  Stream<List<int>> _read() async* {
    final f = await _reader;
    try {
      while (true) {
        final block = await f.read(65536);
        if (block.isEmpty) break;
        yield block;
      }
    } finally {
      await f.close();
    }
  }

  @override
  int get pid => _program.pid;

  @override
  Future<int> get exitCode => _program.exitCode;

  /// The end of what the CLI wrote to stderr in this run (the log holds
  /// earlier runs too).
  @override
  String get lastError {
    try {
      final f = File(_logPath).openSync();
      try {
        final end = f.lengthSync();
        final from = end - 2000 > _logStart ? end - 2000 : _logStart;
        if (end <= from) return '';
        f.setPositionSync(from);
        return utf8.decode(f.readSync(end - from), allowMalformed: true);
      } finally {
        f.closeSync();
      }
    } on FileSystemException {
      return '';
    }
  }

  @override
  void send(String line) {
    if (_closed || _exited) return;
    _writes = _writes.then((_) async {
      try {
        await (await _writer).writeString('$line\n');
      } on Object {
        // The CLI is gone; nothing reads the pipe.
      }
    });
  }

  /// Holds each pipe open read-write until our own open of it is through;
  /// once, as an open after [_release] removed the pipes would make files.
  Future<void> _unblock() => _unblocking ??= () async {
    for (final (path, ours) in [(_output, _reader), (_input, _writer)]) {
      try {
        final hold = await File(path).open(mode: FileMode.write);
        await ours.then((_) {}, onError: (Object _) {});
        await hold.close();
      } on FileSystemException {
        // Removed already.
      }
    }
  }();

  /// Lets go of the pipes and the terminal's log, once: when the CLI exits
  /// or the session closes, whichever is first.
  Future<void> _release() => _releasing ??= () async {
    await _writes;
    try {
      await (await _writer).close();
    } on Object {
      // Never opened, or closed already.
    }
    _released = true;
    await _ttyOutput.cancel();
    await _tty.flush();
    await _tty.close();
    _removePipes(_input, _output);
  }();

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _live.remove(this);
    unregisterDriverRoot(_tag, pid);
    await killTree(pid);
    await _unblock();
    await _release();
  }
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
