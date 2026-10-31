import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_pty/flutter_pty.dart';

import '../harness/session_processes.dart' show sessionEnvVar;
import 'pty.dart';

bool get shellSupported => Platform.isMacOS || Platform.isLinux || Platform.isWindows;

ShellPty? startShell({
  required String workingDir,
  int rows = 24,
  int columns = 80,
  Map<String, String> env = const {},
}) {
  if (!shellSupported) return null;
  final (exe, args) = _shell();
  final environment = {...Platform.environment, ...env}
    // Not one of the agent's terminals: Stop must leave these processes alone.
    ..remove(sessionEnvVar);
  if (!Platform.isWindows) environment['TERM'] = 'xterm-256color';
  return _Pty(
    Pty.start(
      exe,
      arguments: args,
      workingDirectory: Directory(workingDir).existsSync() ? workingDir : null,
      environment: environment,
      rows: rows,
      columns: columns,
    ),
  );
}

/// The user's shell as a login shell, so their profile sets PATH (an app
/// started from the Dock has a minimal one).
(String, List<String>) _shell() {
  if (Platform.isWindows) return (Platform.environment['COMSPEC'] ?? 'cmd.exe', const []);
  final shell = Platform.environment['SHELL'];
  if (shell != null && shell.isNotEmpty && File(shell).existsSync()) return (shell, const ['-l']);
  return (Platform.isMacOS ? '/bin/zsh' : '/bin/bash', const ['-l']);
}

final class _Pty implements ShellPty {
  _Pty(this._pty);
  final Pty _pty;

  @override
  int get pid => _pty.pid;
  @override
  Stream<Uint8List> get output => _pty.output;
  @override
  Future<int> get exitCode => _pty.exitCode;
  @override
  void write(Uint8List data) => _pty.write(data);
  @override
  void resize(int rows, int columns) => _pty.resize(rows, columns);
  @override
  void kill() => _pty.kill(ProcessSignal.sighup);
}
