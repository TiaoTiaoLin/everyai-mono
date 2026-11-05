import 'dart:io';

import '../domain/local_ports.dart';
import '../harness/session_processes.dart';
import 'processes.dart';

Future<List<SessionProcess>> listSessionProcesses({
  required String tag,
  required String workingDir,
  required bool ownsDir,
  Set<int> agentRoots = const {},
  Set<int> terminalShells = const {},
}) async {
  final found = await findSessionProcesses(tag: tag, workingDir: workingDir, ownsDir: ownsDir);
  if (found == null) return const [];
  final (table, agent) = found;
  final origin = <int, ProcessOrigin>{
    for (final p in agent) p: ProcessOrigin.agent,
    for (final root in agentRoots)
      if (table.rows.containsKey(root))
        for (final p in {root, ...table.descendants(root)}) p: ProcessOrigin.agent,
  };
  for (final shell in terminalShells) {
    for (final p in table.descendants(shell)) {
      origin.putIfAbsent(p, () => ProcessOrigin.terminal);
    }
  }
  origin.remove(pid);
  if (origin.isEmpty) return const [];
  final ports = await listeningPorts(origin.keys);
  return [
    for (final MapEntry(key: p, value: o) in origin.entries)
      if (table.rows[p] case final row?)
        SessionProcess(
          pid: p,
          ppid: row.ppid,
          command: row.command,
          origin: o,
          ports: [
            for (final l in ports)
              if (l.pid == p) l,
          ],
        ),
  ]..sort((a, b) => a.pid.compareTo(b.pid));
}

Future<List<ListeningPort>> listeningPorts(Iterable<int> pids) async {
  if (pids.isEmpty) return const [];
  try {
    if (Platform.isLinux) {
      final res = await Process.run('ss', ['-Hltnp']);
      if (res.exitCode == 0) return parseSsListen('${res.stdout}').where((l) => pids.contains(l.pid)).toList();
    }
    final res = await Process.run('lsof', ['-nP', '-a', '-iTCP', '-sTCP:LISTEN', '-p', pids.join(','), '-Fpn']);
    return parseLsofListen('${res.stdout}');
  } on Object {
    return const [];
  }
}

bool killProcess(int pid, {bool force = false}) =>
    Process.killPid(pid, force ? ProcessSignal.sigkill : ProcessSignal.sigterm);
