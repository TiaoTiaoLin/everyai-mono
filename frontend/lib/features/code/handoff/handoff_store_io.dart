// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';
import 'dart:io';

import 'handoff.dart';

Future<String> saveHandoff(String sessionDir, Handoff h) async {
  final dir = Directory('$sessionDir/handoffs');
  await dir.create(recursive: true);
  final stamp = h.createdAt.toUtc().toIso8601String().replaceAll(RegExp('[^0-9]'), '');
  final to = h.toHarness.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  final path = '${dir.path}/$stamp-$to.json';
  final tmp = File('$path.$pid.tmp');
  await tmp.writeAsString('${const JsonEncoder.withIndent('  ').convert(h.toJson())}\n', flush: true);
  await tmp.rename(path);
  return path;
}

Future<List<Handoff>> loadHandoffs(String sessionDir) async {
  final dir = Directory('$sessionDir/handoffs');
  if (!dir.existsSync()) return const [];
  final out = <Handoff>[];
  await for (final f in dir.list()) {
    if (f is! File || !f.path.endsWith('.json')) continue;
    try {
      if (jsonDecode(await f.readAsString()) case final Map<String, Object?> j) out.add(Handoff.fromJson(j));
    } on FormatException {
      continue;
    } on FileSystemException {
      continue;
    }
  }
  return out..sort((a, b) => b.createdAt.compareTo(a.createdAt));
}
