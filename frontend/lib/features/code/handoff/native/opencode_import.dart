// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:math';

import '../../drivers/opencode/opencode_driver.dart';
import '../../drivers/opencode/opencode_session.dart' show openCodeModelRef;
import '../native_import.dart';
import 'import_steps.dart';
import 'native_files.dart';

// OpenCode imports a session in its own export format
// (`POST /api/experimental/session/import`, the route behind `opencode
// session import`; checked on 2.1.3, docs/research/batches/multi-harness/
// run5/i1.md). Its tools are 2.1.3's: shell, read, write, edit, grep, glob;
// every call is marked as not run by the provider (`executed: false`), or
// the AI SDK refuses to send it. Each message carries our marker, so a
// reopened session doesn't show the imported history twice.

/// The marker every imported message carries (`metadata`).
const openCodeImportedMeta = {
  'everyai': {'imported': true},
};

final class OpenCodeImporter implements NativeImporter {
  OpenCodeImporter({OpenCodeDriver? driver, DateTime Function()? now, Random? random})
    : _driver = driver ?? OpenCodeDriver(),
      _now = now ?? DateTime.now,
      _random = random ?? Random.secure();

  final OpenCodeDriver _driver;
  final DateTime Function() _now;
  final Random _random;

  @override
  String get harness => 'opencode';

  /// Null without a `provider/model` (the session's model is part of the
  /// format, and we don't guess a provider).
  @override
  Future<ImportedSession?> write(NativeImportSource source) async {
    if (!canImport || source.sessionTag.isEmpty) return null;
    final model = openCodeModelRef(source.model, source.effort);
    if (model == null) return null;
    final steps = importSteps(source, into: 'OpenCode');
    if (steps == null) return null;
    final body = openCodeImport(
      steps,
      cwd: source.cwd,
      title: source.title,
      model: model,
      now: _now(),
      random: _random,
    );
    final id = await _driver.importSession(
      cwd: source.cwd,
      sessionTag: source.sessionTag,
      model: source.model,
      effort: source.effort,
      session: body.info,
      messages: body.messages,
    );
    if (id == null) return null;
    return ImportedSession(nativeId: id, note: 'Imported ${importedTurns(steps)} turns into OpenCode');
  }
}

/// [steps] as OpenCode's session info and messages. Message ids and times
/// go up in order; agent text and calls share an assistant message until
/// text follows a call (a new step of the model).
({Map<String, Object?> info, List<Map<String, Object?>> messages}) openCodeImport(
  List<ImportStep> steps, {
  required String cwd,
  required String title,
  required Map<String, Object?> model,
  required DateTime now,
  required Random random,
}) {
  final start = now.millisecondsSinceEpoch;
  var n = 0;
  var calls = 0;
  final messageModel = {'id': model['id'], 'providerID': model['providerID']};
  final messages = <Map<String, Object?>>[];
  List<Map<String, Object?>>? parts;
  void close() {
    if (parts case final p? when p.isNotEmpty) {
      messages.last['finish'] = p.last['type'] == 'tool' ? 'tool-calls' : 'stop';
    }
    parts = null;
  }

  List<Map<String, Object?>> assistant() {
    if (parts case final p?) return p;
    final at = start + n;
    final content = <Map<String, Object?>>[];
    messages.add({
      'id': openCodeId('msg', at, n++, random),
      'type': 'assistant',
      'time': {'created': at, 'completed': at},
      'agent': 'build',
      'model': messageModel,
      'content': content,
      'metadata': openCodeImportedMeta,
    });
    return parts = content;
  }

  for (final s in steps) {
    switch (s) {
      case UserStep(:final text):
        close();
        final at = start + n;
        messages.add({
          'id': openCodeId('msg', at, n++, random),
          'type': 'user',
          'time': {'created': at},
          'text': text,
          'metadata': openCodeImportedMeta,
        });
      case AgentStep(:final text):
        if (parts case final p? when p.isNotEmpty && p.last['type'] == 'tool') close();
        assistant().add({'type': 'text', 'text': text});
      case CallStep():
        final tool = openCodeTool(s, cwd);
        if (tool == null) {
          if (parts case final p? when p.isNotEmpty && p.last['type'] == 'tool') close();
          assistant().add({'type': 'text', 'text': callAsText(s)});
          continue;
        }
        final at = start + n;
        assistant().add({
          'type': 'tool',
          'id': 'call_imp_${++calls}',
          'name': tool.name,
          'executed': false,
          'state': {
            // Errors stay `completed` with the text saying so: only that
            // state was checked to import.
            'status': 'completed',
            'input': tool.input,
            'content': [
              {'type': 'text', 'text': s.isError ? 'Error: ${s.result}' : s.result},
            ],
            'metadata': <String, Object?>{},
          },
          'time': {'created': at, 'completed': at},
        });
    }
  }
  close();
  final at = start + n;
  return (
    info: {
      'id': openCodeId('ses', start, 0, random, descending: true),
      'model': model,
      'cost': 0,
      'tokens': {
        'input': 0,
        'output': 0,
        'reasoning': 0,
        'cache': {'read': 0, 'write': 0},
      },
      'time': {'created': start, 'updated': at},
      'location': {'directory': cwd},
      'title': title,
    },
    messages: messages,
  );
}

/// An id the way OpenCode makes them: [prefix], 12 hex digits of the time
/// in ms × 4096 plus a counter (inverted for sessions, which list newest
/// first), then 14 random base62 characters.
String openCodeId(String prefix, int ms, int counter, Random random, {bool descending = false}) {
  const mask = (1 << 48) - 1;
  var v = (ms * 4096 + counter) & mask;
  if (descending) v = ~v & mask;
  const chars = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
  final tail = String.fromCharCodes([for (var i = 0; i < 14; i++) chars.codeUnitAt(random.nextInt(chars.length))]);
  return '${prefix}_${v.toRadixString(16).padLeft(12, '0')}$tail';
}

/// The OpenCode 2.1.3 tool [c] was, with its input; null when none stands for it.
({String name, Map<String, Object?> input})? openCodeTool(CallStep c, String cwd) {
  final path = absolutePath(cwd, c.str('path'));
  return switch (c.kind) {
    'TerminalAction' when c.str('command').isNotEmpty => (name: 'shell', input: {'command': c.str('command')}),
    'FileEditorAction' when path.isNotEmpty => switch (c.str('command')) {
      'create' => (name: 'write', input: {'path': path, 'content': c.str('file_text')}),
      'str_replace' when c.str('old_str').isNotEmpty => (
        name: 'edit',
        input: {'path': path, 'oldString': c.str('old_str'), 'newString': c.str('new_str')},
      ),
      'view' => (name: 'read', input: {'path': path}),
      _ => null,
    },
    'ReadFileAction' when path.isNotEmpty => (name: 'read', input: {'path': path}),
    'GrepAction' || 'GlobAction' when c.str('pattern').isNotEmpty => (
      name: c.kind == 'GrepAction' ? 'grep' : 'glob',
      input: {'pattern': c.str('pattern'), if (path.isNotEmpty) 'path': path},
    ),
    _ => null,
  };
}
