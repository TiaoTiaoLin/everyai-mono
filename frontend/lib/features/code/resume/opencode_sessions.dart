// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';

import '../drivers/opencode/opencode_events.dart';
import '../harness/events.dart';
import 'past_sessions.dart';
import 'resume_files.dart' as files;

// OpenCode's earlier sessions, read from its own SQLite file, read-only and without starting it.
//
// OpenCode 2.1.3 keeps every session in `$XDG_DATA_HOME/opencode/opencode.db` (default
// `~/.local/share/opencode/opencode.db`, on macOS too). Sessions are `session_v2` rows (`directory` is the folder
// they ran in); their messages are `session_message` rows (`type` + a JSON `data`, ordered by `seq`). A message's
// `{id, type, ...data}` is what `GET /api/session/{id}/message` serves, so the driver's own mapper reads it. The
// 1.x tables (`session`, `message`, `part`) were migrated into these and aren't read. A file without `session_v2`
// (an older OpenCode) lists nothing. Resume goes through the OpenCode driver with the session id.

/// The query reading one folder's sessions. Subagent sessions (`parent_id`) and archived ones are left out.
String _listSql(int dirs) =>
    '''
SELECT s.id, s.directory, s.title, s.model, s.time_updated,
  (SELECT count(*) FROM session_message m WHERE m.session_id = s.id AND m.type = 'user') AS turns,
  (SELECT json_extract(m.data, '\$.text') FROM session_message m
     WHERE m.session_id = s.id AND m.type = 'user' ORDER BY m.seq LIMIT 1) AS first_text
FROM session_v2 s
WHERE s.parent_id IS NULL AND s.time_archived IS NULL AND s.directory IN (${List.filled(dirs, '?').join(', ')})
ORDER BY s.time_updated DESC
LIMIT 200''';

const _historySql = 'SELECT id, type, data FROM session_message WHERE session_id = ? ORDER BY seq';

/// OpenCode's sessions for a folder.
final class OpenCodePastSessions implements PastSessionSource {
  OpenCodePastSessions({Future<Map<String, String>> Function()? env, this.dbPath}) : _env = env ?? files.resumeEnv;

  final Future<Map<String, String>> Function() _env;

  /// The database file; found from the environment when null.
  final String? dbPath;

  @override
  String get harness => 'opencode';

  Future<String?> _db() async {
    if (dbPath != null) return dbPath;
    final env = await _env();
    final data = (env['XDG_DATA_HOME'] ?? '').trim();
    final home = (env['HOME'] ?? '').trim();
    if (data.isNotEmpty) return '$data/opencode/opencode.db';
    if (home.isEmpty) return null;
    return '$home/.local/share/opencode/opencode.db';
  }

  @override
  Future<List<PastSession>> list(String folder, {List<String> worktrees = const []}) async {
    final db = await _db();
    if (db == null) return const [];
    final dirs = {
      for (final d in [folder, ...worktrees]) _trim(d),
    }.toList();
    final rows = await files.sqliteRows(db, _listSql(dirs.length), dirs);
    if (rows == null) return const [];
    return [for (final r in rows) ?_session(r)];
  }

  PastSession? _session(Map<String, Object?> r) {
    final id = r['id'];
    final dir = r['directory'];
    final updated = r['time_updated'];
    if (id is! String || dir is! String || updated is! int) return null;
    final title = (r['title'] as String? ?? '').trim();
    final first = (r['first_text'] as String? ?? '').trim();
    return PastSession(
      harness: harness,
      nativeId: id,
      cwd: dir,
      // OpenCode names an untitled session "New session - <time>"; the first message says more.
      title: title.isEmpty || (title.startsWith('New session') && first.isNotEmpty) ? pastSessionTitle(first) : title,
      lastActive: DateTime.fromMillisecondsSinceEpoch(updated),
      turns: r['turns'] as int?,
      model: _model(r['model']),
    );
  }

  @override
  Future<List<HarnessEvent>> history(PastSession session) async {
    final db = await _db();
    if (db == null) return const [];
    final rows = await files.sqliteRows(db, _historySql, [session.nativeId]);
    if (rows == null) return const [];
    final messages = <Object?>[for (final r in rows) ?_message(r)];
    // The driver's mapper, so tool names, todos and reasoning read as in a live OpenCode session.
    return OpenCodeMapper(workingDir: session.cwd).history(messages);
  }

  static Map<String, Object?>? _message(Map<String, Object?> r) {
    final data = r['data'];
    if (data is! String) return null;
    try {
      if (jsonDecode(data) case final Map<String, Object?> m) return {...m, 'id': r['id'], 'type': r['type']};
    } on FormatException {
      // A torn row: skipped.
    }
    return null;
  }

  static String? _model(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    try {
      if (jsonDecode(raw) case {'id': final String id} && final m) {
        final provider = m['providerID'];
        return provider is String && provider.isNotEmpty ? '$provider/$id' : id;
      }
    } on FormatException {
      return null;
    }
    return null;
  }
}

/// OpenCode's past sessions, read from its database.
PastSessionSource openCodePastSessions({Future<Map<String, String>> Function()? env, String? dbPath}) =>
    OpenCodePastSessions(env: env, dbPath: dbPath);

/// [text]'s first line, at most 80 characters, for a session row.
String pastSessionTitle(String text) {
  final line = text.trim().split('\n').first.trim();
  return line.length <= 80 ? line : '${line.substring(0, 79).trimRight()}…';
}

String _trim(String dir) => dir.length > 1 && dir.endsWith('/') ? dir.substring(0, dir.length - 1) : dir;
