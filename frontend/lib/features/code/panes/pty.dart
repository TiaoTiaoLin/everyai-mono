import 'dart:typed_data';

import '../harness/session_processes.dart' show sessionEnvVar;
import 'pty_stub.dart' if (dart.library.io) 'pty_io.dart' as impl;

/// A login shell in a pseudo-terminal.
abstract interface class ShellPty {
  int get pid;
  Stream<Uint8List> get output;
  Future<int> get exitCode;
  void write(Uint8List data);
  void resize(int rows, int columns);
  void kill();
}

/// Whether this platform can run [startShell].
bool get shellSupported => impl.shellSupported;

/// Starts the user's shell in [workingDir], or null where there is none.
/// [env] is added to the app's own environment.
ShellPty? startShell({
  required String workingDir,
  int rows = 24,
  int columns = 80,
  Map<String, String> env = const {},
}) => impl.startShell(workingDir: workingDir, rows: rows, columns: columns, env: env);

/// Starts [executable] (an absolute path) in a pseudo-terminal in [workingDir], for a coding CLI the session owns:
/// the login shell's PATH, a colour terminal, and `EVERYAI_SESSION` = [sessionTag] so Stop and the Processes pane
/// own what it runs. Null where there are no ptys.
Future<ShellPty?> startProgram({
  required String executable,
  required List<String> args,
  required String workingDir,
  required String sessionTag,
  int rows = 24,
  int columns = 80,
  Map<String, String> env = const {},
}) => impl.startProgram(
  executable: executable,
  args: args,
  workingDir: workingDir,
  sessionTag: sessionTag,
  rows: rows,
  columns: columns,
  env: env,
);

/// The environment for a CLI in a pty: [base] (the login shell's) made fit for a terminal UI (the shell capture
/// forces `TERM=dumb`, no colour and `cat` as pager), plus [extra] and the session tag.
Map<String, String> programEnv(Map<String, String> base, Map<String, String> extra, String sessionTag) => {
  for (final e in base.entries)
    if (!const {'NO_COLOR', 'PAGER', 'GIT_PAGER'}.contains(e.key)) e.key: e.value,
  ...extra,
  'TERM': 'xterm-256color',
  sessionEnvVar: sessionTag,
};
