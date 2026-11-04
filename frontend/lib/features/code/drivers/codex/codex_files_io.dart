// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:io';

Future<String?> readText(String path) async {
  final f = File(path);
  return await f.exists() ? f.readAsString() : null;
}

Future<void> writeText(String path, String text) async {
  final f = File(path);
  await f.parent.create(recursive: true);
  await f.writeAsString(text, flush: true);
}
