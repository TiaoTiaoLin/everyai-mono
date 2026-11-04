// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../drivers/acp/acp_mapping.dart';
import '../drivers/driver_events.dart';
import '../drivers/json_rpc.dart';
import '../harness/events.dart';
import 'opencode_sessions.dart' show pastSessionTitle;
import 'past_sessions.dart';
import 'resume_files.dart' as files;

// Earlier sessions of ACP agents. Resume is ACP `session/load` (the ACP driver's reopen path, for agents that
// advertise `loadSession`), so a session is only offered where it can be listed:
// - Gemini CLI writes each chat to `~/.gemini/tmp/<project>/chats/session-*.json` (0.33.2), read here as files.
//   `<project>` is the short name `~/.gemini/projects.json` gives the folder (`{projects: {<abs path>: <name>}}`),
//   or, on older versions, the sha256 of the folder's absolute path; every file carries that hash as
//   `projectHash`, which is checked. Chats of `kind: "subagent"` are left out. History is mapped from the file,
//   because Gemini's own replay on `session/load` is quieted by the driver (`lateReplay`).
// - Agents that answer the (unstable) ACP `session/list` — `agentCapabilities.sessionCapabilities.list` — are
//   listed by asking them ([AcpListedSessions]); that starts the agent (initialize and list only, no prompt, no
//   model call). Their history comes from the agent's own replay on `session/load`, so [history] is empty.
// - Everything else is not offered; [acpResumeUnsupported] says why for Settings.

/// Gemini CLI's chats for a folder.
final class GeminiPastSessions implements PastSessionSource {
  GeminiPastSessions({Future<Map<String, String>> Function()? env, this.home}) : _env = env ?? files.resumeEnv;

  final Future<Map<String, String>> Function() _env;

  /// The user's home (`~/.gemini` lives there); from the environment when null.
  final String? home;

  /// Chat files by session id, from the last [list].
  final _files = <String, String>{};

  @override
  String get harness => 'gemini';

  Future<String?> _root() async {
    final h = home ?? (await _env())['HOME'];
    return h == null || h.trim().isEmpty ? null : '${h.trim()}/.gemini';
  }

  @override
  Future<List<PastSession>> list(String folder, {List<String> worktrees = const []}) async {
    final root = await _root();
    if (root == null) return const [];
    final names = _projectNames(await files.readSmallFile('$root/projects.json', maxBytes: 4 << 20));
    final out = <PastSession>[];
    final seen = <String>{};
    for (final dir in {
      for (final d in [folder, ...worktrees]) _trim(d),
    }) {
      final hash = sha256.convert(utf8.encode(dir)).toString();
      for (final project in {?names[dir], hash}) {
        for (final path in await files.filesIn('$root/tmp/$project/chats', suffix: '.json')) {
          final chat = _decode(await files.readSmallFile(path));
          if (chat == null) continue;
          final s = _session(chat, dir, hash);
          if (s == null || !seen.add(s.nativeId)) continue;
          _files[s.nativeId] = path;
          out.add(s);
        }
      }
    }
    out.sort((a, b) => b.lastActive.compareTo(a.lastActive));
    return out;
  }

  PastSession? _session(Map<String, Object?> chat, String dir, String hash) {
    final id = chat['sessionId'];
    if (id is! String || id.isEmpty) return null;
    if (chat['projectHash'] case final String h when h != hash) return null;
    if (chat['kind'] == 'subagent') return null;
    final messages = _list(chat['messages']);
    final users = [
      for (final m in messages)
        if (m['type'] == 'user') _userText(m['content']),
    ].where((t) => t.trim().isNotEmpty).toList();
    if (users.isEmpty) return null;
    final updated = DateTime.tryParse('${chat['lastUpdated'] ?? chat['startTime'] ?? ''}');
    if (updated == null) return null;
    final model = [
      for (final m in messages)
        if (m['type'] == 'gemini' && m['model'] is String) m['model'] as String,
    ].lastOrNull;
    return PastSession(
      harness: harness,
      nativeId: id,
      cwd: dir,
      title: pastSessionTitle(users.first),
      lastActive: updated,
      turns: users.length,
      model: model,
    );
  }

  @override
  Future<List<HarnessEvent>> history(PastSession session) async {
    var path = _files[session.nativeId];
    if (path == null) {
      await list(session.cwd);
      path = _files[session.nativeId];
    }
    final chat = path == null ? null : _decode(await files.readSmallFile(path));
    if (chat == null) return const [];
    return geminiChatEvents(chat, cwd: session.cwd);
  }
}

/// A Gemini CLI chat file as the app's events, in Gemini's own vocabulary (its tool names, its todos, its
/// thoughts as reasoning). Pure, for tests.
List<HarnessEvent> geminiChatEvents(Map<String, Object?> chat, {String? cwd}) {
  final out = <HarnessEvent>[];
  var n = 0;
  for (final m in _list(chat['messages'])) {
    final id = '${m['id'] ?? 'g${n++}'}';
    switch (m['type']) {
      case 'user':
        final text = _userText(m['content']);
        if (text.trim().isNotEmpty) out.add(userMessageEvent('$id-u', text));
      case 'gemini':
        final thoughts = [
          for (final t in _list(m['thoughts']))
            [
              if (t['subject'] case final String s when s.isNotEmpty) '**$s**',
              if (t['description'] case final String d when d.isNotEmpty) d,
            ].join('\n'),
        ].where((t) => t.isNotEmpty).join('\n\n');
        final text = m['content'] is String ? m['content'] as String : _userText(m['content']);
        if (text.trim().isNotEmpty || thoughts.isNotEmpty) {
          out.add(agentMessageEvent('$id-a', text, reasoning: thoughts));
        }
        for (final call in _list(m['toolCalls'])) {
          out.addAll(_toolEvents(call, cwd: cwd));
        }
    }
  }
  return out;
}

List<HarnessEvent> _toolEvents(Map<String, Object?> call, {String? cwd}) {
  final name = call['name'] is String ? call['name'] as String : 'tool';
  final callId = call['id'] is String ? call['id'] as String : name;
  final args = call['args'] is Map<String, Object?> ? call['args'] as Map<String, Object?> : const <String, Object?>{};
  if (name == 'write_todos') {
    final todos = _list(args['todos']);
    final (a, r) = acpPlanEvents([
      for (final t in todos) {'content': t['description'] ?? t['content'] ?? '', 'status': t['status']},
    ], id: callId);
    return [a, r];
  }
  final path = [
    args['absolute_path'],
    args['file_path'],
    args['path'],
    args['dir_path'],
  ].whereType<String>().firstOrNull;
  final kind = switch (name) {
    'run_shell_command' => 'execute',
    'read_file' || 'read_many_files' => 'read',
    'write_file' || 'replace' => 'edit',
    'glob' || 'search_file_content' || 'list_directory' => 'search',
    'web_fetch' => 'fetch',
    _ => 'other',
  };
  final acpCall = <String, Object?>{
    'toolCallId': callId,
    'name': name,
    'kind': kind,
    'title': call['description'] ?? call['displayName'] ?? name,
    'rawInput': args,
    if (path != null)
      'locations': [
        {'path': path},
      ],
    if (name == 'write_file' && path != null)
      'content': [
        {'type': 'diff', 'path': path, 'oldText': '', 'newText': args['content'] ?? ''},
      ],
    if (name == 'replace' && path != null)
      'content': [
        {'type': 'diff', 'path': path, 'oldText': args['old_string'] ?? '', 'newText': args['new_string'] ?? ''},
      ],
  };
  final action = acpActionEvent(acpCall, id: callId, cwd: cwd);
  final status = call['status'];
  return [
    action,
    resultEvent(
      id: '$callId-r',
      actionId: callId,
      toolName: action.toolName,
      text: _resultText(call),
      isError: status == 'error' || status == 'cancelled',
    ),
  ];
}

String _resultText(Map<String, Object?> call) {
  if (call['resultDisplay'] case final String s when s.trim().isNotEmpty) return s;
  for (final r in _list(call['result'])) {
    if (r['functionResponse'] case {'response': final Map<String, Object?> body}) {
      final v = body['output'] ?? body['error'] ?? body['content'];
      if (v is String) return v;
      if (v != null) return jsonEncode(v);
    }
  }
  return call['status'] == 'cancelled' ? 'Cancelled.' : '';
}

/// An ACP agent that lists its own sessions (`session/list`). [open] starts the agent in a folder and returns a
/// connected peer (the integration wires it to the ACP launcher); it is closed after listing.
final class AcpListedSessions implements PastSessionSource {
  AcpListedSessions({required this.harness, required this.open, this.pages = 5});

  @override
  final String harness;
  final Future<JsonRpcPeer> Function(String cwd) open;

  /// At most this many `nextCursor` pages per folder.
  final int pages;

  @override
  Future<List<PastSession>> list(String folder, {List<String> worktrees = const []}) async {
    final dirs = {
      for (final d in [folder, ...worktrees]) _trim(d),
    };
    final out = <PastSession>[];
    final seen = <String>{};
    JsonRpcPeer? peer;
    try {
      peer = await open(_trim(folder));
      final init = await peer.request('initialize', {
        'protocolVersion': 1,
        'clientCapabilities': {
          'fs': {'readTextFile': false, 'writeTextFile': false},
          'terminal': false,
        },
        'clientInfo': {'name': 'everyai', 'title': 'EveryAI', 'version': '0.1.0'},
      });
      if (!acpCanListAndLoad(init)) return const [];
      for (final dir in dirs) {
        String? cursor;
        for (var page = 0; page < pages; page++) {
          final reply = await peer.request('session/list', {'cwd': dir, 'cursor': ?cursor});
          final body = reply is Map<String, Object?> ? reply : const <String, Object?>{};
          for (final s in _list(body['sessions'])) {
            final session = acpListedSession(s, harness: harness, dirs: dirs);
            if (session != null && seen.add(session.nativeId)) out.add(session);
          }
          cursor = body['nextCursor'] as String?;
          if (cursor == null || cursor.isEmpty) break;
        }
      }
    } on Object {
      // An agent that fails to start or refuses to list offers nothing.
    } finally {
      await peer?.close();
    }
    out.sort((a, b) => b.lastActive.compareTo(a.lastActive));
    return out;
  }

  /// The agent replays the conversation itself on `session/load`; nothing is read ahead of it.
  @override
  Future<List<HarnessEvent>> history(PastSession session) async => const [];
}

/// Whether an `initialize` reply offers both `session/list` and `session/load`.
bool acpCanListAndLoad(Object? init) {
  if (init is! Map<String, Object?>) return false;
  final caps = init['agentCapabilities'];
  if (caps is! Map<String, Object?> || caps['loadSession'] != true) return false;
  final session = caps['sessionCapabilities'];
  return session is Map<String, Object?> && session['list'] != null;
}

/// One `session/list` entry (`{sessionId, cwd, title?, updatedAt?}`) as a row, or null when it isn't in [dirs].
PastSession? acpListedSession(Map<String, Object?> s, {required String harness, required Set<String> dirs}) {
  final id = s['sessionId'];
  final cwd = s['cwd'];
  if (id is! String || id.isEmpty || cwd is! String || !dirs.contains(_trim(cwd))) return null;
  final title = s['title'] is String ? (s['title'] as String).trim() : '';
  return PastSession(
    harness: harness,
    nativeId: id,
    cwd: _trim(cwd),
    title: title.isEmpty ? 'Untitled session' : pastSessionTitle(title),
    lastActive: DateTime.tryParse('${s['updatedAt'] ?? ''}') ?? DateTime.fromMillisecondsSinceEpoch(0),
  );
}

/// The past-session source for an ACP driver id: Gemini CLI's files, or `session/list` when [open] is given.
PastSessionSource? acpPastSessions(
  String harness, {
  Future<JsonRpcPeer> Function(String cwd)? open,
  Future<Map<String, String>> Function()? env,
  String? home,
}) {
  if (harness == 'gemini' || harness == 'acp:gemini') return GeminiPastSessions(env: env, home: home);
  if (acpResumeUnsupported(harness) != null || open == null) return null;
  return AcpListedSessions(harness: harness, open: open);
}

/// Why an ACP agent's earlier sessions aren't offered, for Settings → Harnesses; null when they can be.
/// Agents not named here are offered only if they answer `session/list` (checked when they start).
String? acpResumeUnsupported(String harness) => switch (harness.startsWith('acp:') ? harness.substring(4) : harness) {
  'gemini' => null,
  'antigravity' || 'agy' => "Antigravity CLI reopens with session/resume, which this app doesn't use yet.",
  'opencode' => "Listed under OpenCode, from OpenCode's own sessions.",
  'qwen-code' || 'qwen' => "Qwen Code's saved chats aren't read yet.",
  _ => null,
};

Map<String, String> _projectNames(String? json) {
  if (json == null) return const {};
  try {
    if (jsonDecode(json) case {'projects': final Map<String, Object?> p}) {
      return {
        for (final e in p.entries)
          if (e.value case final String name when name.isNotEmpty && !name.contains('/') && name != '..')
            _trim(e.key): name,
      };
    }
  } on FormatException {
    return const {};
  }
  return const {};
}

Map<String, Object?>? _decode(String? text) {
  if (text == null) return null;
  try {
    if (jsonDecode(text) case final Map<String, Object?> m) return m;
  } on FormatException {
    return null;
  }
  return null;
}

String _userText(Object? content) => switch (content) {
  final String s => s,
  final List<Object?> parts => [
    for (final p in parts.whereType<Map<String, Object?>>())
      if (p['text'] case final String t) t,
  ].join('\n'),
  _ => '',
};

List<Map<String, Object?>> _list(Object? v) => v is List ? v.whereType<Map<String, Object?>>().toList() : const [];

String _trim(String dir) => dir.length > 1 && dir.endsWith('/') ? dir.substring(0, dir.length - 1) : dir;
