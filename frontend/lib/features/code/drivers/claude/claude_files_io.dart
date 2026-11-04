// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../harness/everyai/shell_io.dart' show ShellEnv;

Future<String?> readTextFile(String path) async {
  try {
    final f = File(path);
    return await f.exists() ? await f.readAsString() : null;
  } on FileSystemException {
    return null;
  }
}

Future<void> writeTextFile(String path, String text) async {
  final f = File(path);
  await f.parent.create(recursive: true);
  final tmp = File('$path.tmp');
  await tmp.writeAsString(text, flush: true);
  await tmp.rename(path);
}

Future<void> makeDir(String path) => Directory(path).create(recursive: true);

Future<String?> runQuiet(String executable, List<String> args) async {
  try {
    final shell = await ShellEnv.load();
    final res = await Process.run(
      executable,
      args,
      environment: shell.env,
      stdoutEncoding: const Utf8Codec(allowMalformed: true),
    ).timeout(const Duration(seconds: 10));
    return '${res.stdout}';
  } on Object {
    return null;
  }
}
