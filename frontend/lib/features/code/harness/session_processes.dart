import 'package:flutter/foundation.dart';

import 'session_processes_stub.dart' if (dart.library.io) 'session_processes_io.dart' as impl;

/// Set in the environment of each session's shell commands, so the processes
/// they start can be told apart from other sessions'.
const sessionEnvVar = 'EVERYAI_SESSION';

/// Ends every process a Code session's terminal left running: background
/// jobs, servers, and commands still going after a soft timeout. The
/// terminal's own shell stays, so the agent can keep working.
///
/// A process belongs to the session when its environment shows
/// [sessionEnvVar] = [tag]. macOS hides the environment of system binaries
/// (`/bin/sleep`, `/bin/bash`); an orphaned one counts when its working
/// directory is inside [workingDir] and [ownsDir] says no other session
/// works there (a per-session worktree). Returns the pids signalled.
Future<List<int>> killSessionProcesses({required String tag, required String workingDir, required bool ownsDir}) =>
    impl.killSessionProcesses(tag: tag, workingDir: workingDir, ownsDir: ownsDir, roots: driverRootsOf(tag));

/// The process table and the pids [killSessionProcesses] would signal, for
/// the Processes pane; null where processes can't be listed.
Future<(ProcessTable, List<int>)?> findSessionProcesses({
  required String tag,
  required String workingDir,
  required bool ownsDir,
}) => impl.findSessionProcesses(tag: tag, workingDir: workingDir, ownsDir: ownsDir, roots: driverRootsOf(tag));

final _driverRoots = <String, Set<int>>{};

/// Marks [pid], a coding CLI the app started for session [tag], as the root
/// of the session's processes: what it runs is the session's (Stop ends it,
/// the Processes pane lists it), while the CLI itself is spared, like the
/// terminal's shell. Its own environment alone wouldn't do: the table
/// follows terminal shells and orphans only.
void registerDriverRoot(String tag, int pid) => (_driverRoots[tag] ??= {}).add(pid);

void unregisterDriverRoot(String tag, int pid) {
  final roots = _driverRoots[tag];
  if (roots == null) return;
  roots.remove(pid);
  if (roots.isEmpty) _driverRoots.remove(tag);
}

/// The driver processes registered for [tag].
Set<int> driverRootsOf(String tag) => {...?_driverRoots[tag]};

/// One row of the process table.
@immutable
final class ProcessRow {
  const ProcessRow({required this.pid, required this.ppid, required this.command, this.envVisible = true, this.tag});

  final int pid;
  final int ppid;

  /// The command line (without the environment).
  final String command;

  /// Whether the environment could be read at all.
  final bool envVisible;

  /// The value of [sessionEnvVar], when set and visible.
  final String? tag;

  String get _exe {
    final first = command.trimLeft().split(RegExp(r'\s')).first;
    return first.substring(first.lastIndexOf('/') + 1);
  }

  /// A tmux server: its children may be shells running the agent's
  /// commands. Never signalled.
  bool get isTerminalHost => _exe == 'tmux';
}

/// The process table, and which processes belong to a session.
final class ProcessTable {
  ProcessTable(Iterable<ProcessRow> rows) : rows = {for (final r in rows) r.pid: r} {
    for (final r in this.rows.values) {
      (_children[r.ppid] ??= []).add(r.pid);
    }
  }

  final Map<int, ProcessRow> rows;
  final _children = <int, List<int>>{};

  static final _envTag = RegExp('(?:^|\\s)$sessionEnvVar=(\\S*)');

  /// Parses `ps -E -ww -x -o pid=,ppid=,command=` (macOS): the environment
  /// follows the arguments when it is readable. [plain] is the same listing
  /// without `-E`; a row whose line is unchanged had no readable environment.
  factory ProcessTable.parsePs(String withEnv, String plain) {
    final commands = <int, String>{};
    for (final (pid, _, rest) in _lines(plain)) {
      commands[pid] = rest;
    }
    return ProcessTable([
      for (final (pid, ppid, rest) in _lines(withEnv))
        if (commands[pid] case final cmd?)
          ProcessRow(
            pid: pid,
            ppid: ppid,
            command: cmd,
            envVisible: rest.length > cmd.length,
            tag: rest.length > cmd.length ? _envTag.firstMatch(rest.substring(cmd.length))?.group(1) : null,
          ),
    ]);
  }

  static Iterable<(int, int, String)> _lines(String out) sync* {
    final line = RegExp(r'^\s*(\d+)\s+(\d+)\s(.*)$');
    for (final l in out.split('\n')) {
      final m = line.firstMatch(l);
      if (m == null) continue;
      yield (int.parse(m.group(1)!), int.parse(m.group(2)!), m.group(3)!);
    }
  }

  /// The tag in an environment block (`/proc/<pid>/environ`, NUL-separated).
  static String? tagInEnviron(String environ) {
    for (final e in environ.split('\x00')) {
      if (e.startsWith('$sessionEnvVar=')) return e.substring(sessionEnvVar.length + 1);
    }
    return null;
  }

  /// Shells under a tmux server.
  List<int> get shells => [
    for (final r in rows.values)
      if (!r.isTerminalHost && (rows[r.ppid]?.isTerminalHost ?? false)) r.pid,
  ];

  /// Processes whose parent has exited (adopted by init/launchd).
  List<int> get orphans => [
    for (final r in rows.values)
      if (r.ppid == 1 && !r.isTerminalHost) r.pid,
  ];

  List<int> descendants(int pid) {
    final out = <int>[];
    final stack = [...?_children[pid]];
    while (stack.isNotEmpty) {
      final p = stack.removeLast();
      if (out.contains(p)) continue;
      out.add(p);
      stack.addAll(_children[p] ?? const []);
    }
    return out;
  }

  /// The processes whose working directory decides ownership: orphans
  /// without a visible tag.
  List<int> needsCwd() => [
    for (final p in orphans)
      if (rows[p]!.tag == null) p,
  ];

  /// What to signal for session [tag]: everything under shells whose tree
  /// carries its tag (not the shells), under its driver [roots] (not the
  /// roots), and orphaned processes it started (with their children).
  /// [cwds] maps pids from [needsCwd] to working directories.
  List<int> sessionProcesses({
    required String tag,
    required String workingDir,
    required bool ownsDir,
    Map<int, String> cwds = const {},
    Set<int> roots = const {},
  }) {
    bool inDir(int pid) => switch (cwds[pid]) {
      final String c => c == workingDir || c.startsWith(workingDir.endsWith('/') ? workingDir : '$workingDir/'),
      null => false,
    };
    // A visible tag anywhere in a tree settles whose it is.
    String? treeTag(int root) {
      for (final p in [root, ...descendants(root)]) {
        if (rows[p]?.tag case final t?) return t;
      }
      return null;
    }

    final out = <int>{};
    for (final shell in shells) {
      if (treeTag(shell) == tag) out.addAll(descendants(shell));
    }
    for (final root in roots) {
      if (rows.containsKey(root)) out.addAll(descendants(root));
    }
    for (final o in orphans) {
      final r = rows[o]!;
      final ours = r.tag == tag || (r.tag == null && !r.envVisible && ownsDir && inDir(o));
      if (ours) out.addAll([o, ...descendants(o)]);
    }
    out.removeWhere((p) => roots.contains(p) || (rows[p]?.isTerminalHost ?? true));
    return out.toList()..sort();
  }
}
