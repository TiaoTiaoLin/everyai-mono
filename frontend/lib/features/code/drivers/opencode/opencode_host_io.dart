// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';
import 'dart:io';

import '../../harness/everyai/shell_io.dart' show ShellEnv;
import 'opencode_host.dart';

Future<CliRun> runOpenCodeCli(String executable, List<String> args, {String? cwd}) async {
  final shell = await ShellEnv.load();
  final res = await Process.run(
    executable,
    args,
    workingDirectory: cwd,
    environment: {...shell.env, 'OPENCODE_DISABLE_AUTOUPDATE': '1'},
    stdoutEncoding: const Utf8Codec(allowMalformed: true),
  ).timeout(const Duration(seconds: 10));
  return (exitCode: res.exitCode, stdout: '${res.stdout}');
}

Future<String?> readTextFile(String path) async {
  final f = File(path);
  return await f.exists() ? f.readAsString() : null;
}

Future<void> writeTextFile(String path, String text) async {
  final f = File(path);
  await f.parent.create(recursive: true);
  final tmp = File('$path.tmp');
  await tmp.writeAsString(text, flush: true);
  await tmp.rename(path);
}
