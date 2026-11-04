// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../drivers/claude/claude_driver.dart';
import '../../drivers/claude/claude_files.dart' show writeTextFile;
import '../native_import.dart';
import 'import_steps.dart';
import 'native_files.dart';

// Claude Code keeps each conversation as JSONL under
// `<CLAUDE_CONFIG_DIR or ~/.claude>/projects/<slug of the folder>/<id>.jsonl`
// and `claude -p --resume <id>` continues one we wrote (checked on 2.1.318,
// docs/research/batches/multi-harness/run5/i1.md). The format is Claude's
// own and undocumented, so only the fields the check proved are written.

/// The CLI version the written records carry (the one the format was checked on).
const claudeImportVersion = '2.1.318';

/// A slug longer than this is shortened by Claude in a way not checked: no import then.
const claudeSlugMax = 200;

/// The folder name Claude keeps [realCwd]'s conversations under.
String claudeProjectSlug(String realCwd) => realCwd.replaceAll(RegExp('[^A-Za-z0-9]'), '-');

final class ClaudeImporter implements NativeImporter {
  ClaudeImporter({ClaudeDriver? driver, Future<String?> Function(String name)? env, DateTime Function()? now})
    : _driver = driver ?? ClaudeDriver(),
      _env = env ?? envVar,
      _now = now ?? DateTime.now;

  final ClaudeDriver _driver;

  /// The environment the CLI runs with (tests replace it).
  final Future<String?> Function(String name) _env;
  final DateTime Function() _now;

  @override
  String get harness => 'claude-code';

  @override
  Future<ImportedSession?> write(NativeImportSource source) async {
    if (!canImport || source.sessionTag.isEmpty) return null;
    final steps = importSteps(source, into: 'Claude Code');
    if (steps == null) return null;
    // Where the CLI keeps its files: `CLAUDE_CONFIG_DIR`, else `~/.claude`.
    final root = await _env('CLAUDE_CONFIG_DIR') ?? '${await _env('HOME') ?? ''}/.claude';
    final cwd = await realPath(source.cwd);
    final slug = claudeProjectSlug(cwd);
    if (slug.length > claudeSlugMax) return null;
    final id = const Uuid().v4();
    final lines = claudeSessionLines(steps, sessionId: id, cwd: cwd, start: _now());
    await writeTextFile('$root/projects/$slug/$id.jsonl', '${lines.join('\n')}\n');
    await _driver.adoptImported(
      id,
      cwd: source.cwd,
      sessionTag: source.sessionTag,
      model: source.model,
      effort: source.effort,
      mode: source.mode,
    );
    return ImportedSession(nativeId: id, note: 'Imported ${importedTurns(steps)} turns into Claude Code');
  }
}

/// [steps] as Claude's records (one JSON object per line): a `parentUuid`
/// chain of user and assistant messages; calls next to each other share one
/// assistant message, and their results one user message.
List<String> claudeSessionLines(
  List<ImportStep> steps, {
  required String sessionId,
  required String cwd,
  required DateTime start,
}) {
  // (role, content blocks); a message of the same role as the last one joins it.
  final messages = <(String, List<Map<String, Object?>>)>[];
  final results = <Map<String, Object?>>[];
  var calls = 0;
  void add(String role, Map<String, Object?> block) {
    if (messages.isNotEmpty && messages.last.$1 == role) {
      messages.last.$2.add(block);
    } else {
      messages.add((role, [block]));
    }
  }

  void flush() {
    for (final r in results) {
      add('user', r);
    }
    results.clear();
  }

  for (final s in steps) {
    switch (s) {
      case UserStep(:final text):
        flush();
        add('user', {'type': 'text', 'text': text});
      case AgentStep(:final text):
        flush();
        add('assistant', {'type': 'text', 'text': text});
      case CallStep():
        final tool = claudeTool(s, cwd);
        if (tool == null) {
          flush();
          add('assistant', {'type': 'text', 'text': callAsText(s)});
          continue;
        }
        final id = 'toolu_imp_${++calls}';
        add('assistant', {'type': 'tool_use', 'id': id, 'name': tool.name, 'input': tool.input});
        results.add({'type': 'tool_result', 'tool_use_id': id, 'content': s.result, if (s.isError) 'is_error': true});
    }
  }
  flush();
  String? parent;
  final out = <String>[];
  for (final (i, (role, blocks)) in messages.indexed) {
    final uuid = const Uuid().v4();
    final message = role == 'user'
        ? {
            'role': 'user',
            'content': blocks.length == 1 && blocks.single['type'] == 'text' ? blocks.single['text'] : blocks,
          }
        : {
            'id': 'msg_imp_${i + 1}',
            'type': 'message',
            'role': 'assistant',
            'model': '<synthetic>',
            'content': blocks,
            'stop_reason': blocks.last['type'] == 'tool_use' ? 'tool_use' : 'end_turn',
            'usage': {'input_tokens': 0, 'output_tokens': 0},
          };
    out.add(
      jsonEncode({
        'parentUuid': parent,
        'isSidechain': false,
        'userType': 'external',
        'cwd': cwd,
        'sessionId': sessionId,
        'version': claudeImportVersion,
        'type': role,
        'message': message,
        'uuid': uuid,
        'timestamp': start.add(Duration(milliseconds: i)).toUtc().toIso8601String(),
      }),
    );
    parent = uuid;
  }
  return out;
}

/// The Claude Code tool [c] was, with its input; null when none stands for it.
({String name, Map<String, Object?> input})? claudeTool(CallStep c, String cwd) {
  final path = absolutePath(cwd, c.str('path'));
  return switch (c.kind) {
    'TerminalAction' when c.str('command').isNotEmpty => (name: 'Bash', input: {'command': c.str('command')}),
    'FileEditorAction' when path.isNotEmpty => switch (c.str('command')) {
      'create' => (name: 'Write', input: {'file_path': path, 'content': c.str('file_text')}),
      'str_replace' when c.str('old_str').isNotEmpty => (
        name: 'Edit',
        input: {'file_path': path, 'old_string': c.str('old_str'), 'new_string': c.str('new_str')},
      ),
      'view' => (name: 'Read', input: {'file_path': path}),
      _ => null,
    },
    'ReadFileAction' when path.isNotEmpty => (name: 'Read', input: {'file_path': path}),
    'GrepAction' || 'GlobAction' when c.str('pattern').isNotEmpty => (
      name: c.kind == 'GrepAction' ? 'Grep' : 'Glob',
      input: {'pattern': c.str('pattern'), if (path.isNotEmpty) 'path': path},
    ),
    _ => null,
  };
}
