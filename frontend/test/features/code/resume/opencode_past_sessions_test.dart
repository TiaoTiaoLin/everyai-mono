// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';
import 'dart:io';

import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/resume/opencode_sessions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

// A synthetic OpenCode 2.1.3 database: the `session_v2` / `session_message` columns the reader uses, with message
// data in the shapes `GET /api/session/{id}/message` serves (see docs/research/batches/multi-harness/run5/i1.md).

void main() {
  late Directory tmp;
  late String dbPath;
  late String project;
  late String worktree;

  void session(
    Database db,
    String id, {
    required String dir,
    required int updated,
    String title = '',
    String? parent,
    int? archived,
    Object? model,
  }) {
    db.execute(
      'INSERT INTO session_v2 (id, project_id, parent_id, slug, directory, title, version, model, time_created, '
      'time_updated, time_archived) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        id,
        'prj',
        parent,
        id,
        dir,
        title,
        '2.1.3',
        model == null ? null : jsonEncode(model),
        updated - 1000,
        updated,
        archived,
      ],
    );
  }

  var seq = 0;
  void message(Database db, String session, String id, String type, Object data) => db.execute(
    'INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data) VALUES (?, ?, ?, ?, ?, ?, ?)',
    [id, session, type, seq++, 0, 0, data is String ? data : jsonEncode(data)],
  );

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('opencode_resume');
    project = '${tmp.path}/repo';
    worktree = '${tmp.path}/wt/repo-1';
    dbPath = '${tmp.path}/data/opencode/opencode.db';
    Directory('${tmp.path}/data/opencode').createSync(recursive: true);
    final db = sqlite3.open(dbPath);
    db.execute('''
      CREATE TABLE session_v2 (id text PRIMARY KEY, project_id text NOT NULL, parent_id text, slug text NOT NULL,
        directory text NOT NULL, title text, version text NOT NULL, model text, time_created integer NOT NULL,
        time_updated integer NOT NULL, time_archived integer);
      CREATE TABLE session_message (id text PRIMARY KEY, session_id text NOT NULL, type text NOT NULL,
        seq integer NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL);
    ''');
    session(
      db,
      'ses_old',
      dir: project,
      updated: 1000000,
      title: 'Fix the parser',
      model: {'id': 'claude-x', 'providerID': 'anthropic', 'variant': 'high'},
    );
    session(db, 'ses_new', dir: worktree, updated: 3000000, title: 'New session - 2026-11-01T10:00:00.000Z');
    session(db, 'ses_other', dir: '${tmp.path}/other', updated: 4000000, title: 'Elsewhere');
    session(db, 'ses_child', dir: project, updated: 5000000, title: 'Subagent', parent: 'ses_old');
    session(db, 'ses_archived', dir: project, updated: 6000000, title: 'Gone', archived: 6000001);

    message(db, 'ses_old', 'msg_1', 'user', {
      'text': 'Make the parser accept tabs',
      'time': {'created': 1},
      'files': <Object?>[],
      'agents': <Object?>[],
    });
    message(db, 'ses_old', 'msg_2', 'assistant', {
      'agent': 'build',
      'model': {'id': 'claude-x', 'providerID': 'anthropic'},
      'time': {'created': 2, 'completed': 3},
      'finish': 'stop',
      'content': [
        {
          'type': 'reasoning',
          'text': 'Tabs are split by the lexer.',
          'time': {'completed': 2},
        },
        {
          'type': 'tool',
          'id': 'call_1',
          'name': 'shell',
          'executed': false,
          'state': {
            'status': 'completed',
            'input': {'command': 'rg tab lib'},
            'content': [
              {'type': 'text', 'text': 'lib/lexer.dart: tab'},
            ],
          },
        },
        {
          'type': 'tool',
          'id': 'call_2',
          'name': 'todowrite',
          'executed': false,
          'state': {
            'status': 'completed',
            'input': {
              'todos': [
                {'content': 'Patch the lexer', 'status': 'in_progress', 'priority': 'high'},
              ],
            },
            'content': <Object?>[],
          },
        },
        {
          'type': 'text',
          'text': 'The lexer splits on spaces only.',
          'time': {'completed': 3},
        },
      ],
    });
    message(db, 'ses_old', 'msg_bad', 'assistant', '{torn');
    message(db, 'ses_old', 'msg_3', 'user', {'text': 'go on'});
    message(db, 'ses_new', 'msg_4', 'user', {'text': 'Add a README\nwith install steps'});
    db.close();
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test("lists the folder's and its worktrees' sessions, newest first, without subagents or archived ones", () async {
    final source = openCodePastSessions(dbPath: dbPath);
    expect(source.harness, 'opencode');
    final list = await source.list('$project/', worktrees: [worktree]);
    expect([for (final s in list) s.nativeId], ['ses_new', 'ses_old']);
    final (newer, older) = (list.first, list.last);
    expect(newer.title, 'Add a README', reason: "OpenCode's placeholder title gives way to the first message");
    expect(newer.cwd, worktree);
    expect(newer.turns, 1);
    expect(older.title, 'Fix the parser');
    expect(older.model, 'anthropic/claude-x');
    expect(older.turns, 2);
    expect(older.lastActive, DateTime.fromMillisecondsSinceEpoch(1000000));
  });

  test("history is the driver's mapping: tool names as sent, todos, reasoning; a torn row is skipped", () async {
    final source = openCodePastSessions(dbPath: dbPath);
    final old = (await source.list(project)).single;
    final events = await source.history(old);
    final messages = events.whereType<ChatMessage>().toList();
    expect(messages.first.fromUser, isTrue);
    expect(messages.first.text, 'Make the parser accept tabs');
    expect(messages.any((m) => m.reasoning == 'Tabs are split by the lexer.'), isTrue);
    expect(messages.any((m) => m.text == 'The lexer splits on spaces only.'), isTrue);
    expect(messages.last.text, 'go on');
    final calls = events.whereType<ActionCall>().toList();
    expect([for (final c in calls) c.toolName], ['shell', 'todowrite']);
    expect(calls.first.actionKind, 'TerminalAction');
    expect(calls.first.action['command'], 'rg tab lib');
    expect(calls.last.actionKind, 'TaskTrackerAction');
    expect(events.whereType<ToolResult>().first.text, 'lib/lexer.dart: tab');
  });

  test('the database is found under XDG_DATA_HOME, else ~/.local/share', () async {
    final xdg = openCodePastSessions(env: () async => {'XDG_DATA_HOME': '${tmp.path}/data', 'HOME': '/nowhere'});
    expect((await xdg.list(project)).length, 1);
    Directory('${tmp.path}/home/.local/share').createSync(recursive: true);
    Directory('${tmp.path}/data/opencode').renameSync('${tmp.path}/home/.local/share/opencode');
    final home = openCodePastSessions(env: () async => {'HOME': '${tmp.path}/home'});
    expect((await home.list(project)).length, 1);
    expect(await openCodePastSessions(env: () async => const {}).list(project), isEmpty);
  });

  test('a missing file, a non-database or an older OpenCode without session_v2 lists nothing', () async {
    expect(await openCodePastSessions(dbPath: '${tmp.path}/none.db').list(project), isEmpty);
    File('${tmp.path}/junk.db').writeAsStringSync('not sqlite');
    expect(await openCodePastSessions(dbPath: '${tmp.path}/junk.db').list(project), isEmpty);
    final old = sqlite3.open('${tmp.path}/old.db')
      ..execute('CREATE TABLE session (id text PRIMARY KEY, directory text NOT NULL)');
    old.close();
    expect(await openCodePastSessions(dbPath: '${tmp.path}/old.db').list(project), isEmpty);
  });

  test('the reader never writes to the database', () async {
    final before = File(dbPath).lastModifiedSync();
    final source = openCodePastSessions(dbPath: dbPath);
    await source.history((await source.list(project)).single);
    expect(File(dbPath).lastModifiedSync(), before);
    expect(File('$dbPath-wal').existsSync(), isFalse);
  });

  test('pastSessionTitle keeps the first line, cut at 80', () {
    expect(pastSessionTitle('  one\ntwo'), 'one');
    final long = pastSessionTitle('x' * 200);
    expect(long.length, 80);
    expect(long.endsWith('…'), isTrue);
  });
}
