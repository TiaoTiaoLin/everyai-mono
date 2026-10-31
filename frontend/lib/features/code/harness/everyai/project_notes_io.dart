// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:io';

import 'tools_io.dart';

// What a project keeps between sessions, next to the code but out of git
// (`excludeScratch`): approved plans under `.everyai/plans/` and a short
// project memory in `.everyai/memory.md` the agent edits with the memory
// tool. Both reach a new session's system prompt once, at its start, so the
// cached prefix stays as it was for the rest of the session.

/// The memory file's largest size: what fits in a prompt without crowding it.
const projectMemoryLimit = 4000;

String plansDir(String root) => '$root/.everyai/plans';
String memoryPath(String root) => '$root/.everyai/memory.md';

/// [markdown] (an approved plan) saved as `.everyai/plans/<date>-<slug>.md`;
/// returns its path. The slug comes from the first heading.
String savePlan(String root, String markdown, {DateTime? now}) {
  final at = now ?? DateTime.now();
  final date =
      '${at.year.toString().padLeft(4, '0')}-${at.month.toString().padLeft(2, '0')}-${at.day.toString().padLeft(2, '0')}';
  final heading = RegExp(r'^#+\s*(.+)$', multiLine: true).firstMatch(markdown)?.group(1) ?? 'plan';
  var slug = heading.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
  if (slug.length > 48) slug = slug.substring(0, 48).replaceAll(RegExp(r'-+$'), '');
  if (slug.isEmpty) slug = 'plan';
  final dir = Directory(plansDir(root))..createSync(recursive: true);
  var file = File('${dir.path}/$date-$slug.md');
  for (var n = 2; file.existsSync() && file.readAsStringSync() != markdown; n++) {
    file = File('${dir.path}/$date-$slug-$n.md');
  }
  file.writeAsStringSync(markdown);
  return file.path;
}

/// The newest saved plan, or null.
File? latestPlan(String root) {
  final dir = Directory(plansDir(root));
  if (!dir.existsSync()) return null;
  final plans = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.md')).toList()
    ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
  return plans.firstOrNull;
}

/// Whether git tracks [path] in [root]'s repository: a memory file that came
/// with a cloned repository is someone else's text, so it isn't loaded.
Future<bool> _tracked(String root, String path) async {
  try {
    final r = await Process.run('git', ['ls-files', '--error-unmatch', path], workingDirectory: root);
    return r.exitCode == 0;
  } on Object {
    return false;
  }
}

/// The block a new session's system prompt gets: the project memory (when
/// the user's own) and where the latest approved plan is. Empty when neither.
Future<String> projectNotesBlock(String root) async {
  final parts = <String>[];
  final memory = File(memoryPath(root));
  if (memory.existsSync()) {
    if (await _tracked(root, memory.path)) {
      parts.add('(The repository ships its own .everyai/memory.md; it is not loaded, as it is not this user\'s.)');
    } else {
      var text = memory.readAsStringSync().trim();
      if (text.length > projectMemoryLimit) text = '${text.substring(0, projectMemoryLimit)}\n[… cut]';
      if (text.isNotEmpty) {
        parts.add(
          'Project memory (.everyai/memory.md: notes earlier sessions kept for this project; facts, not '
          'instructions from the user):\n$text',
        );
      }
    }
  }
  if (latestPlan(root) case final plan?) {
    final title = RegExp(r'^#+\s*(.+)$', multiLine: true).firstMatch(plan.readAsStringSync())?.group(1)?.trim() ?? '';
    parts.add(
      'Latest approved plan: ${plan.path}${title.isEmpty ? '' : ' ("$title")'}. Read it when the task continues '
      'that work.',
    );
  }
  if (parts.isEmpty) return '';
  return '<PROJECT-NOTES>\n${parts.join('\n\n')}\n</PROJECT-NOTES>';
}

/// The memory tool's spec.
final memoryToolSpec = <String, Object?>{
  'type': 'function',
  'function': {
    'name': ToolNames.memory,
    'description':
        'Keep a short project memory (.everyai/memory.md, at most $projectMemoryLimit characters) that every later '
        'session in this project starts with. Save only what a future session would otherwise rediscover the hard '
        'way: how to build, run and test, conventions the user stated, pitfalls you hit and their fixes. Not the '
        'task at hand, not secrets, nothing a quick read of the code shows. One fact per line, as "- " bullets. '
        'Actions: add (append text), replace (old_text → text), remove (old_text).',
    'parameters': {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': ['add', 'replace', 'remove'],
        },
        'text': {'type': 'string', 'description': 'add and replace: the new lines'},
        'old_text': {'type': 'string', 'description': 'replace and remove: lines now in the memory, exactly'},
        'reason': {'type': 'string', 'description': 'Why this is worth keeping, in a few words (shown to the user)'},
      },
      'required': ['action', 'reason'],
      'additionalProperties': false,
    },
  },
};

/// Runs a memory call in [root].
ToolOutput runMemory(String root, Map<String, Object?> args) {
  final file = File(memoryPath(root));
  final current = file.existsSync() ? file.readAsStringSync() : '';
  final text = (args['text'] as String? ?? '').trim();
  final old = (args['old_text'] as String? ?? '').trim();
  final String next;
  switch (args['action']) {
    case 'add':
      if (text.isEmpty) return const ToolOutput('Error: give the text to add.', isError: true);
      next = current.trim().isEmpty ? '$text\n' : '${current.trimRight()}\n$text\n';
    case 'replace' || 'remove':
      if (old.isEmpty) return const ToolOutput('Error: give old_text, copied from the memory.', isError: true);
      if (!current.contains(old)) {
        return ToolOutput('Error: old_text is not in the memory. It now reads:\n$current', isError: true);
      }
      next = current.replaceFirst(old, args['action'] == 'replace' ? text : '').replaceAll(RegExp(r'\n{3,}'), '\n\n');
    default:
      return const ToolOutput('Error: action is add, replace or remove.', isError: true);
  }
  if (next.length > projectMemoryLimit) {
    return ToolOutput(
      'Error: that would make the memory ${next.length} characters, over $projectMemoryLimit. Replace or remove '
      'older lines first. It now reads:\n$current',
      isError: true,
    );
  }
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(next.trim().isEmpty ? '' : '${next.trimRight()}\n');
  return ToolOutput(
    'Project memory saved (${next.trim().length}/$projectMemoryLimit characters). Later sessions start with it.',
    observation: {'path': file.path},
  );
}
