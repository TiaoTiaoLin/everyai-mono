// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:io';

import '../../harness/everyai/shell_io.dart' show ShellEnv;

bool get canImport => true;

Future<String> realPath(String path) async {
  try {
    return await Directory(path).resolveSymbolicLinks();
  } on FileSystemException {
    return path;
  }
}

Future<String?> envVar(String name) async {
  try {
    return (await ShellEnv.load()).env[name] ?? Platform.environment[name];
  } on Object {
    return Platform.environment[name];
  }
}
