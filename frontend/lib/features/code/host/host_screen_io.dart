// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:io';

import '../drivers/driver_process.dart';
import '../harness/everyai/browser_io.dart';
import '../harness/everyai/screen_tools_io.dart';
import '../harness/everyai/tools_io.dart' show ToolOutput;
import '../harness/everyai/window_capture_io.dart' as capture;
import '../harness/session_processes.dart';
import '../panes/processes.dart' show listeningPorts;
import 'host_screen.dart';

ScreenAccess screenAccess() => ScreenAccess(
  os: Platform.operatingSystem,
  listWindows: capture.listWindows,
  executableOf: capture.executableOf,
  capture: (w, root, others) async => _result(await captureFor(w, root: root, vision: true, others: others)),
  sessionPids: ({required tag, required workingDir, required ownsDir}) async => {
    ...?(await findSessionProcesses(tag: tag, workingDir: workingDir, ownsDir: ownsDir))?.$2,
  },
  processTree: (pid) async {
    final res = await Process.run('ps', ['-A', '-o', 'pid=,ppid=,comm=']);
    if (res.exitCode != 0) return {pid};
    final table = ProcessTable.parsePs('${res.stdout}', '${res.stdout}');
    return {pid, ...table.descendants(pid)};
  },
  spawn: ({required command, required cwd, required sessionTag, required logPath}) => spawnDriver(
    executable: '/bin/sh',
    args: ['-c', '$command 2>&1'],
    cwd: cwd,
    sessionTag: sessionTag,
    logPath: logPath,
  ),
  browser: (profileDir) => _Browser(HeadlessBrowser(profileDir: profileDir)),
  listening: listeningPorts,
);

ScreenResult _result(ToolOutput o) =>
    (text: o.text, isError: o.isError, images: [for (final i in o.images) ?hostImageOf(i.dataUrl)]);

/// Closed with the session, or when the app quits.
final class _Browser implements ScreenBrowser {
  _Browser(this._b) {
    trackDriverClose(close);
  }
  final HeadlessBrowser _b;

  @override
  Future<ScreenResult> run(Map<String, Object?> args, String root) async =>
      _result(await runBrowser(_b, args, root: root, vision: true, fit: (text, _) => _cut(text)));

  @override
  Future<void> close() {
    untrackDriverClose(close);
    return _b.close();
  }
}

/// An eval result as long as a host result should be.
String _cut(String text) => text.length <= 30000 ? text : '${text.substring(0, 30000)}\n[… cut]';

/// Folders a project keeps its build output and packages in: never a project of its own.
const _skipped = {'node_modules', 'build', 'target', 'dist', 'vendor', 'Pods'};

Future<List<String>> detectRunCommandsIn(String dir, String os) async {
  final subdirs = <String>[];
  try {
    for (final e in Directory(dir).listSync()) {
      final name = e.path.substring(e.path.lastIndexOf('/') + 1);
      if (e is Directory && !name.startsWith('.') && !_skipped.contains(name)) subdirs.add(name);
    }
  } on FileSystemException {
    // Unreadable: the session folder alone.
  }
  subdirs.sort();
  String? read(String path) {
    try {
      return File('$dir/$path').readAsStringSync();
    } on FileSystemException {
      return null;
    }
  }

  return detectRunCommands(
    exists: (path) => FileSystemEntity.typeSync('$dir/$path') != FileSystemEntityType.notFound,
    read: read,
    os: os,
    dirs: ['', ...subdirs],
  );
}
