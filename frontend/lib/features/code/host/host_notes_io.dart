// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:io';

import '../harness/everyai/project_notes_io.dart';
import 'host.dart' show HostResult;

HostResult hostMemory(String root, Map<String, Object?> args) {
  try {
    final out = runMemory(root, args);
    return (text: out.text, isError: out.isError);
  } on FileSystemException catch (e) {
    return (text: "Error: the memory couldn't be saved: ${e.message}", isError: true);
  }
}

HostResult hostSavedPlans(String root, Map<String, Object?> args) {
  final dir = Directory(plansDir(root));
  if (notesLinkProblem(root, dir.path) case final why?) return (text: 'Error: $why', isError: true);
  final name = (args['name'] as String? ?? '').trim();
  if (name.isEmpty) {
    final plans = dir.existsSync()
        ? (dir.listSync(followLinks: false).whereType<File>().where((f) => f.path.endsWith('.md')).toList()
            ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync())))
        : const <File>[];
    if (plans.isEmpty) return (text: 'No saved plans yet.', isError: false);
    return (text: [for (final f in plans) '- ${f.uri.pathSegments.last}${_title(f)}'].join('\n'), isError: false);
  }
  // A name from the list only: nothing outside the plans folder.
  if (name.contains('/') || name.contains(r'\') || name.contains('..') || !name.endsWith('.md')) {
    return (text: 'Error: give a .md file name from the list, without a folder.', isError: true);
  }
  final file = File('${dir.path}/$name');
  if (notesLinkProblem(root, file.path) case final why?) return (text: 'Error: $why', isError: true);
  if (!file.existsSync()) return (text: 'Error: there is no saved plan called $name.', isError: true);
  return (text: file.readAsStringSync(), isError: false);
}

/// The plan's first heading after a colon, or nothing.
String _title(File f) {
  try {
    final t = RegExp(r'^#+\s*(.+)$', multiLine: true).firstMatch(f.readAsStringSync())?.group(1)?.trim() ?? '';
    return t.isEmpty ? '' : ': $t';
  } on FileSystemException {
    return '';
  }
}

bool hostSavePlan(String root, String markdown) {
  try {
    savePlan(root, markdown);
    return true;
  } on FileSystemException {
    return false;
  }
}

Future<String> hostProjectNotes(String root) async {
  try {
    return await projectNotesBlock(root);
  } on FileSystemException {
    return '';
  }
}
