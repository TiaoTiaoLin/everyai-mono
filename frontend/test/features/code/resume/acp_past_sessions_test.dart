// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:every_ai/features/code/drivers/json_rpc.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/resume/acp_sessions.dart';
import 'package:flutter_test/flutter_test.dart';

String _hash(String dir) => sha256.convert(utf8.encode(dir)).toString();

void main() {
  late Directory tmp;
  late String home;
  late String project;
  late String worktree;

  String chat({String? id, String? dir, String? updated, String kind = 'main', String? hash}) {
    final d = dir ?? project;
    var text = File('test/fixtures/resume/gemini_chat.json').readAsStringSync();
    text = text.replaceAll('__HASH__', hash ?? _hash(d)).replaceAll('__DIR__', d);
    final m = jsonDecode(text) as Map<String, Object?>;
    if (id != null) m['sessionId'] = id;
    if (updated != null) m['lastUpdated'] = updated;
    m['kind'] = kind;
    return jsonEncode(m);
  }

  void put(String folderName, String file, String body) {
    final f = File('$home/.gemini/tmp/$folderName/chats/$file');
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(body);
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('acp_resume');
    home = '${tmp.path}/home';
    project = '${tmp.path}/repo';
    worktree = '${tmp.path}/wt/repo-1';
    File('$home/.gemini/projects.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({
          'projects': {project: 'repo', '${tmp.path}/other': 'other'},
        }),
      );
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  group('Gemini CLI chats', () {
    test("lists the folder's and its worktrees' chats, newest first, with their fields", () async {
      put('repo', 'session-a.json', chat(id: 'a', updated: '2026-11-01T10:05:00.000Z'));
      // An older Gemini named the folder by the path's hash.
      put(_hash(worktree), 'session-b.json', chat(id: 'b', dir: worktree, updated: '2026-11-02T09:00:00.000Z'));
      put('other', 'session-c.json', chat(id: 'c', dir: '${tmp.path}/other'));
      put('repo', 'session-d.json', chat(id: 'd', kind: 'subagent'));
      // A chat copied in from another folder carries that folder's hash.
      put('repo', 'session-e.json', chat(id: 'e', hash: _hash('/elsewhere')));
      put('repo', 'session-f.json', '{not json');
      put('repo', 'notes.txt', 'ignored');

      final source = GeminiPastSessions(home: home);
      final list = await source.list('$project/', worktrees: [worktree]);
      expect([for (final s in list) s.nativeId], ['b', 'a']);
      final a = list.last;
      expect(a.harness, 'gemini');
      expect(a.cwd, project);
      expect(a.title, 'Add a greeting to hello.txt');
      expect(a.turns, 2);
      expect(a.model, 'gemini-3.5-pro');
      expect(a.lastActive, DateTime.utc(2026, 11, 1, 10, 5));
      expect(list.first.cwd, worktree);
    });

    test('maps the chat in its own vocabulary: tool names, todos, thoughts, results', () async {
      put('repo', 'session-a.json', chat(id: 'a'));
      final source = GeminiPastSessions(home: home);
      final session = (await source.list(project)).single;
      final events = await source.history(session);

      final messages = events.whereType<ChatMessage>().toList();
      expect(
        [for (final m in messages) (m.fromUser, m.text)],
        [
          (true, 'Add a greeting to hello.txt\nand keep it short'),
          (false, "I'll look at the file first."),
          (true, 'thanks'),
          (false, 'Done.'),
        ],
      );
      expect(messages[1].reasoning, '**Reading**\nCheck what hello.txt holds.');

      final calls = events.whereType<ActionCall>().toList();
      expect([for (final c in calls) c.nativeName], ['read_file', 'run_shell_command', 'plan', 'replace']);
      expect(calls[0].actionKind, 'ReadFileAction');
      expect(calls[0].action['path'], '$project/hello.txt');
      expect(calls[1].actionKind, 'TerminalAction');
      expect(calls[1].action['command'], 'ls');
      expect(calls[2].actionKind, 'TaskTrackerAction');
      expect([for (final t in calls[2].action['task_list']! as List) (t as Map)['status']], ['in_progress', 'todo']);
      expect(calls[3].actionKind, 'FileEditorAction');

      final results = {for (final r in events.whereType<ToolResult>()) r.actionId: r};
      expect(results['read_file-1']!.text, 'hi');
      expect(results['run_shell_command-2']!.text, 'hello.txt');
      expect(results['replace-4']!.text, 'old_string not found');
      expect(results['replace-4']!.outcome, ToolOutcome.error);
    });

    test('no home, no Gemini folder or a broken projects.json lists nothing and never throws', () async {
      expect(await GeminiPastSessions(env: () async => const {}).list(project), isEmpty);
      expect(await GeminiPastSessions(home: '${tmp.path}/nobody').list(project), isEmpty);
      File('$home/.gemini/projects.json').writeAsStringSync('[1,2');
      put(_hash(project), 'session-a.json', chat(id: 'a'));
      expect([for (final s in await GeminiPastSessions(home: home).list(project)) s.nativeId], ['a']);
    });

    test('a chat with no user message is not offered', () async {
      final m = jsonDecode(chat(id: 'a')) as Map<String, Object?>;
      m['messages'] = [
        {'id': 'x', 'type': 'info', 'content': 'hello'},
      ];
      put('repo', 'session-a.json', jsonEncode(m));
      expect(await GeminiPastSessions(home: home).list(project), isEmpty);
    });
  });

  group('ACP session/list', () {
    test('lists only when the agent offers list and load, and keeps to the folders', () async {
      final fake = _FakeAgent(
        caps: {
          'loadSession': true,
          'sessionCapabilities': {'list': <String, Object?>{}},
        },
        pages: [
          {
            'sessions': [
              {'sessionId': 's1', 'cwd': project, 'title': 'Fix the build', 'updatedAt': '2026-11-01T10:00:00Z'},
              {'sessionId': 's2', 'cwd': '/elsewhere', 'title': 'Not here'},
            ],
            'nextCursor': 'p2',
          },
          {
            'sessions': [
              {'sessionId': 's3', 'cwd': '$project/', 'updatedAt': '2026-11-03T10:00:00Z'},
            ],
          },
        ],
      );
      final source = acpPastSessions('kimi', open: (_) async => fake.peer)!;
      final list = await source.list(project);
      expect(
        [for (final s in list) (s.nativeId, s.title, s.cwd)],
        [('s3', 'Untitled session', project), ('s1', 'Fix the build', project)],
      );
      expect(fake.calls, ['initialize', 'session/list', 'session/list']);
      expect(fake.listParams.last, {'cwd': project, 'cursor': 'p2'});
      expect(fake.closed, isTrue);
      expect(await source.history(list.first), isEmpty);
    });

    test('an agent without list or load offers nothing; a failing agent offers nothing', () async {
      final noList = _FakeAgent(caps: {'loadSession': true});
      expect(await acpPastSessions('kimi', open: (_) async => noList.peer)!.list(project), isEmpty);
      expect(noList.calls, ['initialize']);
      final noLoad = _FakeAgent(
        caps: {
          'sessionCapabilities': {'list': <String, Object?>{}},
        },
      );
      expect(await acpPastSessions('kimi', open: (_) async => noLoad.peer)!.list(project), isEmpty);
      expect(await acpPastSessions('kimi', open: (_) async => throw StateError('no'))!.list(project), isEmpty);
    });

    test('acpCanListAndLoad reads the initialize reply', () {
      expect(acpCanListAndLoad(null), isFalse);
      expect(
        acpCanListAndLoad({
          'agentCapabilities': {
            'loadSession': true,
            'sessionCapabilities': {'list': <String, Object?>{}},
          },
        }),
        isTrue,
      );
    });
  });

  test('sources and unsupported reasons per agent', () {
    expect(acpPastSessions('gemini'), isA<GeminiPastSessions>());
    expect(acpPastSessions('acp:gemini'), isA<GeminiPastSessions>());
    expect(acpPastSessions('kimi'), isNull, reason: 'no way to start it given');
    expect(acpPastSessions('antigravity', open: (_) async => throw UnimplementedError()), isNull);
    expect(acpResumeUnsupported('gemini'), isNull);
    expect(acpResumeUnsupported('antigravity'), contains('session/resume'));
    expect(acpResumeUnsupported('acp:agy'), contains('session/resume'));
    expect(acpResumeUnsupported('opencode'), contains('OpenCode'));
    expect(acpResumeUnsupported('qwen-code'), isNotNull);
    expect(acpResumeUnsupported('kimi'), isNull);
  });
}

/// An ACP agent on a fake line channel: answers initialize with [caps] and session/list with [pages] in turn.
final class _FakeAgent implements LineChannel {
  _FakeAgent({required this.caps, this.pages = const []});

  final Map<String, Object?> caps;
  final List<Map<String, Object?>> pages;
  final calls = <String>[];
  final listParams = <Object?>[];
  var closed = false;
  final _out = StreamController<String>();
  late final peer = JsonRpcPeer(this);

  @override
  Stream<String> get lines => _out.stream;

  @override
  String get lastError => '';

  @override
  void send(String line) {
    final m = jsonDecode(line) as Map<String, Object?>;
    final method = m['method'] as String;
    calls.add(method);
    Object? result;
    if (method == 'initialize') {
      result = {'protocolVersion': 1, 'agentCapabilities': caps};
    } else if (method == 'session/list') {
      listParams.add(m['params']);
      final n = listParams.length - 1;
      result = n < pages.length ? pages[n] : {'sessions': <Object?>[]};
    }
    scheduleMicrotask(() => _out.add(jsonEncode({'jsonrpc': '2.0', 'id': m['id'], 'result': result})));
  }

  @override
  Future<void> close() async {
    closed = true;
    await _out.close();
  }
}
