// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:io';

import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/resume/claude_sessions.dart';
import 'package:every_ai/features/code/resume/codex_sessions.dart';
import 'package:every_ai/features/code/resume/past_sessions.dart';
import 'package:flutter_test/flutter_test.dart';

String _fixture(String name, String cwd, {String id = 'THREAD'}) =>
    File('test/fixtures/resume/$name').readAsStringSync().replaceAll('CWD', cwd).replaceAll('THREAD', id);

void main() {
  late Directory tmp;
  late String home;
  late String project;
  late String worktree;

  Future<String?> env(String name) async => name == 'HOME' ? home : null;
  Future<String> same(String p) async => p;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('resume_cli_');
    home = '${tmp.path}/home';
    project = '${tmp.path}/work/app';
    worktree = '${tmp.path}/wt/app-s1';
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  String slug(String p) => p.replaceAll(RegExp('[^A-Za-z0-9]'), '-');

  void claudeFile(String cwd, String id, String body) {
    File('$home/.claude/projects/${slug(cwd)}/$id.jsonl')
      ..createSync(recursive: true)
      ..writeAsStringSync(body);
  }

  group('Claude Code', () {
    test('lists the folder and its worktrees, newest first, with title, turns, model and branch', () async {
      claudeFile(project, 'old', _fixture('claude_session.jsonl', project));
      final newer = _fixture(
        'claude_session.jsonl',
        worktree,
      ).replaceAll('2026-11-01', '2026-11-03').replaceAll(RegExp(r'\{"type":"ai-title".*\}\n?'), '');
      claudeFile(worktree, 'new', newer);
      // A subagent thread under the session's folder and an empty file are not sessions.
      claudeFile(project, 'old/subagents/agent-1', _fixture('claude_session.jsonl', project));
      claudeFile(project, 'empty', '');
      // Another folder whose slug collides (`/work/app` and `/work-app`) is filtered by the records' cwd.
      claudeFile(project, 'other', _fixture('claude_session.jsonl', '${tmp.path}/work-app'));

      final list = await claudePastSessions(env: env, resolve: same).list(project, worktrees: [worktree]);
      expect(list.map((s) => s.nativeId), ['new', 'old']);
      final old = list[1];
      expect(old.harness, 'claude-code');
      expect(old.title, 'Counter with reset on the home page');
      expect(old.turns, 2); // the request and /review; tool results, meta and subagent lines don't count
      expect(old.model, 'claude-opus-5-5');
      expect(old.branch, 'feature/counter');
      expect(old.cwd, project);
      expect(old.lastActive, DateTime.utc(2026, 11, 1, 10, 2));
      expect(list[0].title, 'Add a counter to the home page please, with a reset button');
      expect(list[0].cwd, worktree);
    });

    test('a file that starts in a subagent thread is skipped', () async {
      claudeFile(
        project,
        'side',
        _fixture('claude_session.jsonl', project).replaceAll('"isSidechain":false', '"isSidechain":true'),
      );
      expect(await claudePastSessions(env: env, resolve: same).list(project), isEmpty);
    });

    test('CLAUDE_CONFIG_DIR wins over HOME', () async {
      final dir = '${tmp.path}/cfg';
      File('$dir/projects/${slug(project)}/c.jsonl')
        ..createSync(recursive: true)
        ..writeAsStringSync(_fixture('claude_session.jsonl', project));
      final source = claudePastSessions(env: (n) async => n == 'CLAUDE_CONFIG_DIR' ? dir : home, resolve: same);
      expect((await source.list(project)).single.nativeId, 'c');
    });

    test("history keeps Claude's tool names, thinking and TodoWrite, and skips meta and subagent lines", () async {
      claudeFile(project, 's', _fixture('claude_session.jsonl', project));
      final source = claudePastSessions(env: env, resolve: same);
      final events = await source.history((await source.list(project)).single);
      final users = [
        for (final e in events)
          if (e is ChatMessage && e.fromUser) e.text,
      ];
      expect(users, ['Add a counter to the home page please, with a reset button', '/review main']);
      expect(events.whereType<ChatMessage>().any((m) => m.reasoning == 'Look at the page first.'), isTrue);
      final calls = events.whereType<ActionCall>().toList();
      expect(calls.map((c) => c.toolName), ['Read', 'TodoWrite']);
      expect(calls.last.actionKind, 'TaskTrackerAction');
      expect((calls.last.action['task_list'] as List).first, containsPair('status', 'in_progress'));
      final results = events.whereType<ToolResult>().toList();
      expect(results.first.text, 'class Home {}');
      expect(results.first.toolName, 'Read');
      expect(events.whereType<ChatMessage>().any((m) => m.text.contains('subagent')), isFalse);
      expect(
        events.whereType<ChatMessage>().where((m) => !m.fromUser).last.text,
        'Done: the counter and its reset button.',
      );
    });

    test('a big file is listed from its head and tail, with turns unknown', () async {
      final body = _fixture('claude_session.jsonl', project);
      final filler = '${List.filled(200, '{"type":"attachment","attachment":{"x":"${'y' * 4000}"}}').join('\n')}\n';
      final lines = body.split('\n');
      claudeFile(project, 'big', '${lines.take(3).join('\n')}\n$filler${lines.skip(3).join('\n')}');
      final s = claudeSessionOf('big', [...lines.take(3), ...lines.skip(3)], dirs: {project}, cut: true);
      expect(s!.turns, isNull);
      expect(s.title, 'Counter with reset on the home page');
    });
  });

  group('Codex', () {
    void rollout(String day, String time, String id, String body) {
      File('$home/.codex/sessions/2026/11/$day/rollout-2026-11-${day}T$time-$id.jsonl')
        ..createSync(recursive: true)
        ..writeAsStringSync(body);
    }

    test('lists threads of the folder and its worktrees from rollout files, newest first', () async {
      rollout('02', '09-00-00', 'aaa', _fixture('codex_rollout.jsonl', project, id: 'aaa'));
      rollout(
        '03',
        '09-00-00',
        'bbb',
        _fixture('codex_rollout.jsonl', worktree, id: 'bbb').replaceAll('2026-11-02', '2026-11-03'),
      );
      rollout('03', '10-00-00', 'ccc', _fixture('codex_rollout.jsonl', '${tmp.path}/elsewhere', id: 'ccc'));
      // A thread a parent spawned is not listed.
      rollout(
        '03',
        '11-00-00',
        'ddd',
        _fixture(
          'codex_rollout.jsonl',
          project,
          id: 'ddd',
        ).replaceAll('"source":"vscode"', '"source":{"subagent":"review"}'),
      );
      final list = await codexPastSessions(env: env, resolve: same).list(project, worktrees: [worktree]);
      expect(list.map((s) => s.nativeId), ['bbb', 'aaa']);
      final a = list[1];
      expect(a.harness, 'codex');
      expect(a.title, 'List the files and fix the typo in notes.txt');
      expect(a.turns, 2);
      expect(a.model, 'gpt-6.1-sol');
      expect(a.branch, 'dev');
      expect(a.lastActive, DateTime.utc(2026, 11, 2, 9, 5, 1));
    });

    test('CODEX_HOME wins over HOME, and a rollout with no user message is skipped', () async {
      final dir = '${tmp.path}/codex';
      File('$dir/sessions/2026/11/02/rollout-x-eee.jsonl')
        ..createSync(recursive: true)
        ..writeAsStringSync(_fixture('codex_rollout.jsonl', project, id: 'eee'));
      File('$dir/sessions/2026/11/02/rollout-y-fff.jsonl')
          .writeAsStringSync(_fixture('codex_rollout.jsonl', project, id: 'fff').split('\n').take(2).join('\n'));
      final source = codexPastSessions(env: (n) async => n == 'CODEX_HOME' ? dir : home, resolve: same);
      expect((await source.list(project)).map((s) => s.nativeId), ['eee']);
    });

    test('history maps items the way the driver does: shell, apply_patch, update_plan, reasoning', () async {
      rollout('02', '09-00-00', 'aaa', _fixture('codex_rollout.jsonl', project, id: 'aaa'));
      final source = codexPastSessions(env: env, resolve: same);
      final session = (await source.list(project)).single;
      final events = await source.history(session);
      final users = [
        for (final e in events)
          if (e is ChatMessage && e.fromUser) e.text,
      ];
      expect(users, ['List the files and fix the typo in notes.txt', 'Thanks']); // no injected context
      expect(events.whereType<ChatMessage>().any((m) => m.reasoning == 'Listing first.'), isTrue);
      final calls = events.whereType<ActionCall>().toList();
      expect(calls.map((c) => c.toolName), ['shell', 'update_plan', 'apply_patch']);
      expect(calls.first.str('command'), 'ls');
      expect((calls[1].action['task_list'] as List).first, containsPair('status', 'in_progress'));
      expect(calls.last.action['paths'], ['$project/notes.txt']);
      final results = events.whereType<ToolResult>().toList();
      expect(results.first.text, 'notes.txt\nExit code 0');
      expect(events.whereType<ChatMessage>().last.text, 'Thanks');
      // A fresh source finds the file by thread id too.
      final again = await codexPastSessions(env: env, resolve: same).history(session);
      expect(again.length, events.length);
    });
  });

  test('nothing to list without a home', () async {
    Future<String?> none(String _) async => null;
    expect(await claudePastSessions(env: none).list(project), isEmpty);
    expect(await codexPastSessions(env: none).list(project), isEmpty);
    final s = PastSession(harness: 'codex', nativeId: 'x', cwd: project, title: 't', lastActive: DateTime(2026));
    expect(await codexPastSessions(env: none).history(s), isEmpty);
  });
}
