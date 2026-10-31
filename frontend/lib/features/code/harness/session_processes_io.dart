import 'dart:io';

import 'session_processes.dart';

Future<List<int>> killSessionProcesses({required String tag, required String workingDir, required bool ownsDir}) async {
  if (tag.isEmpty || !(Platform.isMacOS || Platform.isLinux)) return const [];
  try {
    final dir = Directory(workingDir).absolute.resolveSymbolicLinksSync();
    final pids = await _find(tag, dir, ownsDir);
    if (pids.isEmpty) return const [];
    for (final p in pids) {
      Process.killPid(p);
    }
    // Whatever ignores SIGTERM gets SIGKILL.
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    final left = (await _find(tag, dir, ownsDir)).where(pids.contains);
    for (final p in left) {
      Process.killPid(p, ProcessSignal.sigkill);
    }
    return pids;
  } on Object {
    return const [];
  }
}

Future<List<int>> _find(String tag, String dir, bool ownsDir) async => (await _scan(tag, dir, ownsDir)).$2;

Future<(ProcessTable, List<int>)> _scan(String tag, String dir, bool ownsDir) async {
  final table = Platform.isLinux ? _procTable() : await _psTable();
  final cwds = Platform.isLinux ? _procCwds(table.needsCwd()) : await _lsofCwds(table.needsCwd());
  return (table, table.sessionProcesses(tag: tag, workingDir: dir, ownsDir: ownsDir, cwds: cwds)..remove(pid));
}

Future<(ProcessTable, List<int>)?> findSessionProcesses({
  required String tag,
  required String workingDir,
  required bool ownsDir,
}) async {
  if (!(Platform.isMacOS || Platform.isLinux)) return null;
  try {
    final dir = Directory(workingDir).absolute.resolveSymbolicLinksSync();
    return await _scan(tag, dir, ownsDir);
  } on Object {
    return null;
  }
}

/// The user's own processes (`-x`), with and without their environment.
Future<ProcessTable> _psTable() async {
  const fields = ['-ww', '-x', '-o', 'pid=,ppid=,command='];
  final withEnv = await Process.run('ps', ['-E', ...fields]);
  final plain = await Process.run('ps', fields);
  return ProcessTable.parsePs('${withEnv.stdout}', '${plain.stdout}');
}

Future<Map<int, String>> _lsofCwds(List<int> pids) async {
  if (pids.isEmpty) return const {};
  final res = await Process.run('lsof', ['-a', '-d', 'cwd', '-p', pids.join(','), '-Fn']);
  final out = <int, String>{};
  int? current;
  for (final l in '${res.stdout}'.split('\n')) {
    if (l.startsWith('p')) current = int.tryParse(l.substring(1));
    if (l.startsWith('n') && current != null) out[current] = l.substring(1);
  }
  return out;
}

ProcessTable _procTable() {
  final uid = File('/proc/self/status')
      .readAsLinesSync()
      .firstWhere((l) => l.startsWith('Uid:'))
      .split(RegExp(r'\s+'))[1];
  final rows = <ProcessRow>[];
  for (final e in Directory('/proc').listSync()) {
    final pid = int.tryParse(e.uri.pathSegments.where((s) => s.isNotEmpty).last);
    if (pid == null) continue;
    try {
      final status = File('/proc/$pid/status').readAsLinesSync();
      String field(String name) => status.firstWhere((l) => l.startsWith('$name:')).split(RegExp(r'\s+'))[1];
      if (field('Uid') != uid) continue;
      final cmd = File('/proc/$pid/cmdline').readAsStringSync().replaceAll('\x00', ' ').trim();
      String? environ;
      try {
        environ = File('/proc/$pid/environ').readAsStringSync();
      } on FileSystemException {
        environ = null;
      }
      rows.add(
        ProcessRow(
          pid: pid,
          ppid: int.parse(field('PPid')),
          command: cmd.isEmpty ? field('Name') : cmd,
          envVisible: environ != null,
          tag: environ == null ? null : ProcessTable.tagInEnviron(environ),
        ),
      );
    } on Object {
      continue; // exited while we looked
    }
  }
  return ProcessTable(rows);
}

Map<int, String> _procCwds(List<int> pids) => {for (final p in pids) p: ?_tryLink('/proc/$p/cwd')};

String? _tryLink(String path) {
  try {
    return Link(path).targetSync();
  } on FileSystemException {
    return null;
  }
}
