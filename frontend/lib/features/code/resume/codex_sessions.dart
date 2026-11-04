// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';

import '../drivers/codex/codex_mapping.dart' show callOf, messageOf, planCall, resultOf, userMessage;
import '../handoff/native/native_files.dart' show envVar, realPath;
import '../harness/events.dart';
import 'past_sessions.dart';
import 'session_files.dart';

// Codex writes each thread as a rollout file, `<CODEX_HOME or ~/.codex>/sessions/YYYY/MM/DD/rollout-<time>-<thread
// id>.jsonl`. Every line is `{timestamp, type, payload}`: `session_meta` first (thread `id`, `cwd`, `git{branch}`,
// `source`), `turn_context` per turn (`model`, `cwd`), `event_msg` (`item_completed` carries the finished
// `ThreadItem` in the core's PascalCase/snake_case form, plus `plan_update`, `thread_name_updated`, ...) and
// `response_item` (the raw model messages, which hold injected context too, so the history uses the completed items).
// Read from files on disk (checked on codex-cli 0.166.0); nothing is written and no `codex` process is started.

/// The driver id these sessions resume on (`thread/resume` with the thread id).
const codexHarness = 'codex';

/// Files over this are listed from their first and last half only (turns then unknown).
const codexListCap = 8 << 20;

const _titleChars = 80;

/// Codex's threads for a folder, read from its rollout files.
PastSessionSource codexPastSessions({
  Future<String?> Function(String name)? env,
  Future<String> Function(String path)? resolve,
}) => CodexPastSessions(env: env, resolve: resolve);

final class CodexPastSessions implements PastSessionSource {
  CodexPastSessions({Future<String?> Function(String name)? env, Future<String> Function(String path)? resolve})
    : _env = env ?? envVar,
      _resolve = resolve ?? realPath;

  final Future<String?> Function(String name) _env;
  final Future<String> Function(String path) _resolve;

  /// Rollout path by thread id, from the last listing.
  final _paths = <String, String>{};

  @override
  String get harness => codexHarness;

  Future<String?> _root() async {
    final dir = await _env('CODEX_HOME');
    if (dir != null && dir.isNotEmpty) return dir;
    final home = await _env('HOME');
    return home == null || home.isEmpty ? null : '$home/.codex';
  }

  @override
  Future<List<PastSession>> list(String folder, {List<String> worktrees = const []}) async {
    final root = await _root();
    if (root == null) return const [];
    final dirs = <String>{};
    for (final d in [folder, ...worktrees]) {
      dirs
        ..add(_trim(d))
        ..add(_trim(await _resolve(d)));
    }
    final out = <PastSession>[];
    for (final path in await listJsonl('$root/sessions', recursive: true)) {
      if (!path.split('/').last.startsWith('rollout-')) continue;
      // The first line alone says whose folder the thread is in.
      final meta = codexMetaOf(await firstLine(path) ?? '');
      if (meta == null || !dirs.contains(_trim(meta.cwd)) || meta.subagent) continue;
      final read = await readLinesCapped(path, maxBytes: codexListCap);
      final s = codexSessionOf(read.lines, cut: read.cut);
      if (s == null) continue;
      _paths[s.nativeId] = path;
      out.add(s);
    }
    out.sort((a, b) => b.lastActive.compareTo(a.lastActive));
    return out;
  }

  @override
  Future<List<HarnessEvent>> history(PastSession session) async {
    var path = _paths[session.nativeId];
    if (path == null) {
      final root = await _root();
      if (root == null) return const [];
      for (final p in await listJsonl('$root/sessions', recursive: true)) {
        if (p.endsWith('-${session.nativeId}.jsonl')) path = p;
      }
    }
    if (path == null) return const [];
    return codexHistory(await streamLines(path).toList(), cwd: session.cwd);
  }
}

String _trim(String p) => p.length > 1 && p.endsWith('/') ? p.substring(0, p.length - 1) : p;

Map<String, Object?>? _json(String line) {
  if (line.trim().isEmpty) return null;
  try {
    return switch (jsonDecode(line)) {
      final Map<String, Object?> m => m,
      _ => null,
    };
  } on FormatException {
    return null;
  }
}

Map<String, Object?> _payload(Map<String, Object?> r) => r['payload'] as Map<String, Object?>? ?? const {};

/// The `session_meta` line: thread id, folder, and whether a parent thread spawned it.
({String id, String cwd, bool subagent})? codexMetaOf(String line) {
  final r = _json(line);
  if (r == null || r['type'] != 'session_meta') return null;
  final p = _payload(r);
  final id = p['id'] as String? ?? '';
  final cwd = p['cwd'] as String? ?? '';
  if (id.isEmpty || cwd.isEmpty) return null;
  final source = p['source'];
  final subagent = source is Map && source.containsKey('subagent');
  return (id: id, cwd: cwd, subagent: subagent);
}

/// A listing row from a rollout's [lines]; null without a `session_meta` or any user message.
PastSession? codexSessionOf(List<String> lines, {bool cut = false}) {
  ({String id, String cwd, bool subagent})? meta;
  String? branch, model, name, first;
  DateTime? last;
  var turns = 0;
  for (final line in lines) {
    final r = _json(line);
    if (r == null) continue;
    if (r['timestamp'] case final String t) {
      final at = DateTime.tryParse(t);
      if (at != null && (last == null || at.isAfter(last))) last = at;
    }
    final p = _payload(r);
    switch (r['type']) {
      case 'session_meta':
        meta ??= codexMetaOf(line);
        if ((p['git'] as Map<String, Object?>?)?['branch'] case final String b when b.isNotEmpty) branch = b;
      case 'turn_context':
        model = p['model'] as String? ?? model;
      case 'event_msg':
        switch (p['type']) {
          case 'thread_name_updated':
            name = p['thread_name'] as String? ?? name;
          case 'item_completed':
            final item = p['item'] as Map<String, Object?>? ?? const {};
            if (item['type'] == 'UserMessage') {
              final text = _userText(item);
              if (text.isNotEmpty) {
                turns++;
                first ??= text;
              }
            }
        }
    }
  }
  if (meta == null || last == null || turns == 0) return null;
  final title = [name, first].whereType<String>().map((t) => t.trim()).firstWhere((t) => t.isNotEmpty);
  return PastSession(
    harness: codexHarness,
    nativeId: meta.id,
    cwd: meta.cwd,
    title: _cut(title),
    lastActive: last,
    turns: cut ? null : turns,
    model: model,
    branch: branch,
  );
}

String _cut(String text) {
  final one = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return one.length <= _titleChars ? one : '${one.substring(0, _titleChars - 1).trimRight()}…';
}

String _texts(Object? content) => [
  for (final c in (content as List<Object?>? ?? const []))
    if (c case {'text': final String t} when t.isNotEmpty) t,
].join('\n');

String _userText(Map<String, Object?> item) => _texts(item['content']).trim();

/// A completed rollout item in the app-server's `ThreadItem` form, which the Codex driver's mapping reads; null for
/// items it doesn't show.
Map<String, Object?>? codexItemOf(Map<String, Object?> item) {
  final id = item['id'] as String? ?? '';
  switch (item['type']) {
    case 'AgentMessage':
      return {'type': 'agentMessage', 'id': id, 'text': _texts(item['content'])};
    case 'Plan':
      return {'type': 'plan', 'id': id, 'text': item['text'] as String? ?? ''};
    case 'Reasoning':
      return {
        'type': 'reasoning',
        'id': id,
        'summary': [...?item['summary_text'] as List<Object?>?],
        'content': [...?item['raw_content'] as List<Object?>?],
      };
    case 'ContextCompaction':
      return {'type': 'contextCompaction', 'id': id};
    case 'CommandExecution':
      return {
        'type': 'commandExecution',
        'id': id,
        'command': _commandText(item['command']),
        'cwd': item['cwd'],
        'status': _status(item['status']),
        'aggregatedOutput': item['aggregated_output'],
        'exitCode': item['exit_code'],
      };
    case 'FileChange':
      final changes = item['changes'];
      return {
        'type': 'fileChange',
        'id': id,
        'status': _status(item['status']),
        'changes': [
          if (changes is Map<String, Object?>)
            for (final MapEntry(key: path, value: c) in changes.entries)
              if (c is Map<String, Object?>)
                {
                  'path': path,
                  'kind': {'type': c['type'] ?? 'update', 'move_path': c['move_path']},
                  'diff': c['unified_diff'] ?? c['content'] ?? '',
                },
          if (changes is List<Object?>) ...changes,
        ],
      };
    case 'McpToolCall':
      return {
        'type': 'mcpToolCall',
        'id': id,
        'server': item['server'],
        'tool': item['tool'],
        'arguments': item['arguments'],
        'status': _status(item['status']),
        'result': item['result'],
        'error': item['error'],
      };
    case 'WebSearch':
      return {'type': 'webSearch', 'id': id, 'query': item['query'] ?? '', 'status': 'completed'};
    case 'ImageView':
      return {'type': 'imageView', 'id': id, 'path': item['path'] ?? '', 'status': 'completed'};
  }
  return null;
}

/// The core writes the argv (`["/bin/zsh", "-lc", "ls"]`); the driver's mapping takes the command line.
String _commandText(Object? command) => switch (command) {
  final String s => s,
  final List<Object?> argv when argv.length == 3 && const {'-c', '-lc'}.contains(argv[1]) => '${argv[2]}',
  final List<Object?> argv => argv.join(' '),
  _ => '',
};

String _status(Object? s) => switch (s) {
  'in_progress' => 'inProgress',
  final String v => v,
  _ => 'completed',
};

/// A rollout's lines as events, mapped as the Codex driver maps the app-server's items: `shell`, `apply_patch`,
/// `server__tool`, `update_plan` and reasoning as Codex sends them.
List<HarnessEvent> codexHistory(Iterable<String> lines, {required String cwd}) {
  final out = <HarnessEvent>[];
  var plans = 0;
  for (final line in lines) {
    final r = _json(line);
    if (r == null || r['type'] != 'event_msg') continue;
    final p = _payload(r);
    switch (p['type']) {
      case 'item_completed':
        final raw = p['item'] as Map<String, Object?>? ?? const {};
        if (raw['type'] == 'UserMessage') {
          final text = _userText(raw);
          if (text.isNotEmpty) out.add(userMessage(raw['id'] as String? ?? 'user-${out.length}', text));
          continue;
        }
        final item = codexItemOf(raw);
        if (item == null) continue;
        if (callOf(item, cwd) case final call?) {
          out.add(call);
          if (resultOf(item, call) case final result?) out.add(result);
        } else if (messageOf(item) case final m?) {
          out.add(m);
        }
      case 'plan_update':
        out.add(
          planCall('plan-${++plans}', {
            'plan': [
              for (final s in (p['plan'] as List<Object?>? ?? const []))
                if (s is Map<String, Object?>) {...s, 'status': _status(s['status'])},
            ],
          }),
        );
    }
  }
  return out;
}
