// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';
import 'dart:io';

import '../settings/settings.dart' show excludeFromGit;
import 'handoff.dart';

Future<String> saveHandoff(String sessionDir, Handoff h) async {
  final dir = Directory('$sessionDir/handoffs');
  await dir.create(recursive: true);
  final path = '${dir.path}/${handoffStem(h.createdAt, h.toHarness)}.json';
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
    } on TypeError {
      // Valid JSON in another shape (an older version, a hand edit).
      continue;
    }
  }
  return out..sort((a, b) => b.createdAt.compareTo(a.createdAt));
}

Future<bool> writeHandoffTranscript(String workingDir, String relativePath, String markdown) async {
  try {
    final file = File('$workingDir/$relativePath');
    await file.parent.create(recursive: true);
    await excludeFromGit(workingDir, const ['/$handoffTranscriptDir/']);
    final tmp = File('${file.path}.$pid.tmp');
    await tmp.writeAsString(markdown, flush: true);
    await tmp.rename(file.path);
    return true;
  } on FileSystemException {
    return false;
  }
}

Future<void> removeTimeline(String dir) async {
  final d = Directory(dir);
  if (d.existsSync()) await d.delete(recursive: true);
}
