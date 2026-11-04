// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';

import '../drivers/claude/claude_wire.dart' show ClaudeDecoder, userMessage;
import '../handoff/native/claude_import.dart' show claudeProjectSlug;
import '../handoff/native/native_files.dart' show envVar, realPath;
import '../harness/events.dart';
import 'past_sessions.dart';
import 'session_files.dart';

// Claude Code keeps each conversation as JSONL under
// `<CLAUDE_CONFIG_DIR or ~/.claude>/projects/<slug of the folder>/<session id>.jsonl` (the slug rule is the one the
// native import uses). Records carry `type` (user, assistant, system, attachment, ai-title, custom-title, summary, ...),
// `uuid`, `timestamp`, `cwd`, `gitBranch`, `isSidechain`, `isMeta`, `isCompactSummary` and an API-shaped `message`.
// Subagent threads live in `<session id>/subagents/`, so only the folder's top-level files are sessions. The format
// is Claude's own and undocumented: unknown records are skipped and a broken line is ignored.

/// The driver id these sessions resume on.
const claudeHarness = 'claude-code';

/// Files over this are listed from their first and last half only (turns then unknown).
const claudeListCap = 8 << 20;

const _titleChars = 80;

/// Claude Code's sessions for a folder, read from its project files.
PastSessionSource claudePastSessions({
  Future<String?> Function(String name)? env,
  Future<String> Function(String path)? resolve,
}) => ClaudePastSessions(env: env, resolve: resolve);

final class ClaudePastSessions implements PastSessionSource {
  ClaudePastSessions({Future<String?> Function(String name)? env, Future<String> Function(String path)? resolve})
    : _env = env ?? envVar,
      _resolve = resolve ?? realPath;

  final Future<String?> Function(String name) _env;
  final Future<String> Function(String path) _resolve;

  @override
  String get harness => claudeHarness;

  Future<String?> _root() async {
    final dir = await _env('CLAUDE_CONFIG_DIR');
    if (dir != null && dir.isNotEmpty) return dir;
    final home = await _env('HOME');
    return home == null || home.isEmpty ? null : '$home/.claude';
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
    final seen = <String>{};
    for (final slug in {for (final d in dirs) claudeProjectSlug(d)}) {
      for (final path in await listJsonl('$root/projects/$slug')) {
        if (!seen.add(path)) continue;
        final read = await readLinesCapped(path, maxBytes: claudeListCap);
        final s = claudeSessionOf(_idOf(path), read.lines, dirs: dirs, cut: read.cut);
        if (s != null) out.add(s);
      }
    }
    out.sort((a, b) => b.lastActive.compareTo(a.lastActive));
    return out;
  }

  @override
  Future<List<HarnessEvent>> history(PastSession session) async {
    final root = await _root();
    if (root == null) return const [];
    for (final d in {_trim(session.cwd), _trim(await _resolve(session.cwd))}) {
      final path = '$root/projects/${claudeProjectSlug(d)}/${session.nativeId}.jsonl';
      final lines = await streamLines(path).toList();
      if (lines.isNotEmpty) return claudeHistory(lines);
    }
    return const [];
  }
}

String _trim(String p) => p.length > 1 && p.endsWith('/') ? p.substring(0, p.length - 1) : p;

String _idOf(String path) {
  final name = path.split('/').last;
  return name.substring(0, name.length - '.jsonl'.length);
}

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

/// A listing row from a session file's [lines], or null for a subagent thread, a file of another folder (the slug
/// rule maps `/a-b` and `/a/b` alike, so the records' cwd must be one of [dirs]) or one with no conversation.
PastSession? claudeSessionOf(String id, List<String> lines, {required Set<String> dirs, bool cut = false}) {
  String? cwd, branch, model, custom, ai, summary, first;
  DateTime? last;
  var turns = 0;
  var talk = false;
  bool? sidechain;
  for (final line in lines) {
    final r = _json(line);
    if (r == null) continue;
    if (r['timestamp'] case final String t) {
      final at = DateTime.tryParse(t);
      if (at != null && (last == null || at.isAfter(last))) last = at;
    }
    switch (r['type']) {
      case 'custom-title':
        custom = r['customTitle'] as String? ?? custom;
      case 'ai-title':
        ai = r['aiTitle'] as String? ?? ai;
      case 'summary':
        summary = r['summary'] as String? ?? summary;
      case 'user' || 'assistant':
        sidechain ??= r['isSidechain'] == true;
        if (r['isSidechain'] == true) continue;
        talk = true;
        cwd = r['cwd'] as String? ?? cwd;
        if (r['gitBranch'] case final String b when b.isNotEmpty) branch = b;
        if (r['type'] == 'assistant') {
          if ((r['message'] as Map<String, Object?>?)?['model'] case final String m when m != '<synthetic>') model = m;
        } else if (_userText(r) case final text?) {
          turns++;
          first ??= text;
        }
    }
  }
  if (sidechain == true || !talk || last == null) return null;
  if (cwd != null && !dirs.contains(_trim(cwd))) return null;
  final title = [
    custom,
    ai,
    summary,
    first,
  ].whereType<String>().map((t) => t.trim()).firstWhere((t) => t.isNotEmpty, orElse: () => 'Claude Code session');
  return PastSession(
    harness: claudeHarness,
    nativeId: id,
    cwd: cwd ?? dirs.first,
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

final _commandName = RegExp(r'<command-name>([^<]*)</command-name>');
final _commandArgs = RegExp(r'<command-args>([^<]*)</command-args>', dotAll: true);

/// What the user typed in a `user` record, or null for tool results, Claude's own notes (meta, compaction
/// summaries, local command output) and empty text. A slash command shows as `/name args`.
String? _userText(Map<String, Object?> r) {
  if (r['isMeta'] == true || r['isCompactSummary'] == true || r['isSidechain'] == true) return null;
  final content = (r['message'] as Map<String, Object?>?)?['content'];
  final text = switch (content) {
    final String s => s,
    final List<Object?> parts => [
      for (final p in parts)
        if (p case {'type': 'text', 'text': final String t}) t,
    ].join('\n'),
    _ => '',
  }.trim();
  if (text.isEmpty) return null;
  if (_commandName.firstMatch(text) case final m?) {
    final args = _commandArgs.firstMatch(text)?.group(1)?.trim() ?? '';
    final name = m.group(1)!.trim();
    return args.isEmpty ? name : '$name $args';
  }
  if (text.startsWith('<local-command-') || text.startsWith('Caveat: ')) return null;
  return text;
}

/// A session file's records as events, mapped the way the Claude driver maps its stream-json lines: Claude's own
/// tool names, thinking, TodoWrite as a task list. Subagent and meta records are left out.
List<HarnessEvent> claudeHistory(Iterable<String> lines) {
  final decoder = ClaudeDecoder();
  final out = <HarnessEvent>[];
  var n = 0;
  for (final line in lines) {
    final r = _json(line);
    if (r == null || r['isSidechain'] == true) continue;
    switch (r['type']) {
      case 'user':
        if (r['isCompactSummary'] == true) {
          out.add(_note('${r['uuid'] ?? 'compact-${++n}'}', 'Claude Code compacted the conversation.'));
          continue;
        }
        if (_userText(r) case final text?) out.add(userMessage(r['uuid'] as String? ?? 'user-${++n}', text));
        // Tool results come as content blocks; a plain-string message has none.
        if ((r['message'] as Map<String, Object?>?)?['content'] is List) out.addAll(decoder.decode(r));
      case 'assistant':
        // A file's assistant record is the API message, with no `parent_tool_use_id` of the stream form.
        out.addAll(decoder.decode({...r, 'parent_tool_use_id': null}));
    }
  }
  return out;
}

ChatMessage _note(String id, String text) => HarnessEvent.decode({
  'kind': 'MessageEvent',
  'id': id,
  'source': 'agent',
  'llm_message': {
    'role': 'assistant',
    'content': [
      {'type': 'text', 'text': text},
    ],
  },
}) as ChatMessage;
