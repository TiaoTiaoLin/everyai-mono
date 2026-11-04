// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';

import '../../drivers/codex/codex_driver.dart';
import '../native_import.dart';
import 'import_steps.dart';
import 'native_files.dart';

// Codex's app server takes history as raw Responses API items on a new
// thread (`thread/inject_items`, a stable method); the thread keeps them in
// its rollout and resumes with them, even after a restart with no turn in
// between (checked on codex-cli 0.166.0, docs/research/batches/
// multi-harness/run5/i1.md). Shell calls and patches go in as Codex's own
// `shell` and `apply_patch` calls, which its model reads as its own; the
// rest is text (an edit by search and replace has no V4A hunk without
// context lines, so it stays text rather than a made-up patch).

final class CodexImporter implements NativeImporter {
  CodexImporter({CodexDriver? driver}) : _driver = driver ?? CodexDriver();

  final CodexDriver _driver;

  @override
  String get harness => 'codex';

  @override
  Future<ImportedSession?> write(NativeImportSource source) async {
    if (!canImport || source.sessionTag.isEmpty) return null;
    final steps = importSteps(source, into: 'Codex');
    if (steps == null) return null;
    final id = await _driver.importThread(
      cwd: source.cwd,
      sessionTag: source.sessionTag,
      model: source.model,
      effort: source.effort,
      mode: source.mode,
      items: codexItems(steps, source.cwd),
    );
    if (id == null) return null;
    return ImportedSession(nativeId: id, note: 'Imported ${importedTurns(steps)} turns into Codex');
  }
}

/// [steps] as Responses API items.
List<Map<String, Object?>> codexItems(List<ImportStep> steps, String cwd) {
  var calls = 0;
  Map<String, Object?> message(String role, String text) => {
    'type': 'message',
    'role': role,
    'content': [
      {'type': role == 'user' ? 'input_text' : 'output_text', 'text': text},
    ],
  };
  return [
    for (final s in steps)
      ...switch (s) {
        UserStep(:final text) => [message('user', text)],
        AgentStep(:final text) => [message('assistant', text)],
        CallStep() => switch (_codexCall(s, cwd)) {
          null => [message('assistant', callAsText(s))],
          (name: 'shell', :final input) => [
            {'type': 'function_call', 'call_id': 'call_imp_${++calls}', 'name': 'shell', 'arguments': input},
            {'type': 'function_call_output', 'call_id': 'call_imp_$calls', 'output': s.result},
          ],
          (:final name, :final input) => [
            {'type': 'custom_tool_call', 'call_id': 'call_imp_${++calls}', 'name': name, 'input': input},
            {'type': 'custom_tool_call_output', 'call_id': 'call_imp_$calls', 'output': s.result},
          ],
        },
      },
  ];
}

/// The Codex call [c] was: `shell` (JSON arguments) or `apply_patch` (a V4A
/// patch); null when none stands for it.
({String name, String input})? _codexCall(CallStep c, String cwd) {
  switch (c.kind) {
    case 'TerminalAction' when c.str('command').isNotEmpty:
      return (
        name: 'shell',
        input: jsonEncode({
          'command': ['bash', '-lc', c.str('command')],
          'workdir': c.str('cwd').isEmpty ? cwd : c.str('cwd'),
        }),
      );
    case 'FileEditorAction' when c.str('command') == 'create' && c.str('path').isNotEmpty:
      final body = c.str('file_text');
      final lines = body.isEmpty ? const <String>[] : body.split('\n');
      if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
      return (
        name: 'apply_patch',
        input: [
          '*** Begin Patch',
          '*** Add File: ${relativePath(cwd, c.str('path'))}',
          for (final l in lines) '+$l',
          '*** End Patch',
          '',
        ].join('\n'),
      );
    case 'ApplyPatchAction' when c.str('patch').trimLeft().startsWith('*** Begin Patch'):
      return (name: 'apply_patch', input: c.str('patch'));
  }
  return null;
}
