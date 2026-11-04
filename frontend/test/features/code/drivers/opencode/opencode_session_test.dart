import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/drivers/briefing/briefing_types.dart';
import 'package:every_ai/features/code/drivers/driver_process.dart';
import 'package:every_ai/features/code/drivers/opencode/opencode_driver.dart';
import 'package:every_ai/features/code/drivers/opencode/opencode_server.dart';
import 'package:every_ai/features/code/drivers/opencode/opencode_session.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/replay_http.dart';

const _dir = 'test/fixtures/drivers/opencode';
const _ses = 'ses_e5adfc323ffe0y4ahZgv1t4ECA';
const _cwd = '/work/tree';

SessionSpec _spec({String model = 'minimax-coding-plan/MiniMax-M3.1-Flash', String? initial = 'Try again please.'}) =>
    SessionSpec(
      workingDir: _cwd,
      model: model,
      mode: AgentMode.ask,
      llmBaseUrl: 'http://127.0.0.1:9/v1',
      llmApiKey: 'sk-test',
      sessionTag: 'tag-1',
      initialMessage: initial,
    );

/// The server's process: the test reads whether it was ended.
final class _Process implements DriverProcess {
  var closed = false;
  @override
  Stream<String> get lines => const Stream.empty();
  @override
  String get lastError => '';
  @override
  int get pid => 1;
  @override
  Future<int> get exitCode => Completer<int>().future;
  @override
  void send(String line) {}
  @override
  Future<void> close() async => closed = true;
}

/// A driver whose server is [http] playing a recording, run by [process].
/// What each server was started with lands in [envs].
({OpenCodeDriver driver, Directory data}) _driver(
  ReplayHttpClient http, {
  _Process? process,
  void Function()? found,
  List<Map<String, String>>? envs,
}) {
  final data = Directory.systemTemp.createTempSync('opencode_session_test');
  addTearDown(() => data.deleteSync(recursive: true));
  final driver = OpenCodeDriver(
    which: (_) async {
      found?.call();
      return '/bin/echo';
    },
    run: (exe, args) async => (exitCode: 0, stdout: File('$_dir/auth_list.json').readAsStringSync()),
    dataDir: () async => data.path,
    reconnectDelay: Duration.zero,
    launch: ({required executable, required cwd, required sessionTag, required logPath, env = const {}}) async {
      envs?.add(env);
      return OpenCodeServer(base: Uri.parse('http://127.0.0.1:4096'), password: 'pw', client: http, process: process);
    },
  );
  return (driver: driver, data: data);
}

ReplayHttpClient _replay(String name) => ReplayHttpClient.script(File('$_dir/$name').readAsStringSync());

/// The lines of the recording [name] before the first that contains [stop].
String _head(String name, String stop) {
  final lines = File('$_dir/$name').readAsLinesSync();
  return lines.take(lines.indexWhere((l) => l.contains(stop))).join('\n');
}

String _line(String dir, Map<String, Object?> msg) => jsonEncode({'dir': dir, 'msg': msg});

/// Collects [session]'s events and waits until everything sent so far has played.
Future<List<HarnessEvent>> _collect(HarnessSession session) async {
  final events = <HarnessEvent>[];
  session.events.listen(events.add);
  await pumpEventQueue();
  return events;
}

List<Map<String, Object?>> _replies(ReplayHttpClient http) => [
  for (final m in http.channel.sent)
    if ('${m['path']}'.endsWith('/reply')) m['body']! as Map<String, Object?>,
];

void _expectAuth(ReplayHttpClient http) {
  final basic = 'Basic ${base64.encode(utf8.encode('opencode:pw'))}';
  expect(http.requests.map((r) => r.headers['authorization']).toSet(), {basic});
}

void main() {
  test(
    "the / menu: OpenCode's command list plus compact, refreshed on command.updated; each runs on its route",
    () async {
      // Derived from T3 Code's OpenCode 2 fixture and the 2.1.3 binary's route and event names, not recorded.
      const list = {
        'location': {'directory': _cwd},
        'data': [
          {'name': 'init', 'description': 'guided AGENTS.md setup'},
          {'name': 'review', 'description': 'review changes [commit|branch|pr], defaults to uncommitted'},
        ],
      };
      final http = ReplayHttpClient.script(
        [
          _head('turn_approvals.jsonl', '/prompt'),
          _line('out', {'id': 3, 'method': 'GET', 'path': '/api/command'}),
          _line('in', {'id': 3, 'status': 200, 'body': list}),
          _line('in', {
            'event': {'type': 'command.updated', 'data': <String, Object?>{}},
          }),
          _line('out', {'id': 4, 'method': 'GET', 'path': '/api/command'}),
          _line('in', {
            'id': 4,
            'status': 200,
            'body': {
              'data': [
                {'name': 'init', 'description': 'guided AGENTS.md setup'},
              ],
            },
          }),
          _line('out', {
            'id': 5,
            'method': 'POST',
            'path': '/api/session/$_ses/command',
            'body': {'name': 'review', 'text': 'x'},
          }),
          _line('in', {'id': 5, 'status': 200, 'body': <String, Object?>{}}),
          _line('out', {'id': 6, 'method': 'POST', 'path': '/api/session/$_ses/compact', 'body': <String, Object?>{}}),
          _line('in', {'id': 6, 'status': 200, 'body': true}),
        ].join('\n'),
      );
      final (:driver, data: _) = _driver(http);
      final session = await driver.start(_spec(initial: null));
      final native = session as HasNativeCommands;
      final lists = <List<NativeCommand>>[];
      native.commands.listen(lists.add);
      await pumpEventQueue();
      expect([for (final c in lists[1]) c.name], ['compact', 'init', 'review']);
      expect(lists.last.map((c) => c.name), ['compact', 'init']);
      await native.runCommand('review', 'x');
      await native.runCommand('compact', '');
      http.channel.expectFinished();
      await session.close();
    },
  );

  test(
    "the modes picker: OpenCode's primary agents (hidden and subagents left out); a pick switches the agent",
    () async {
      // Shaped by the 2.1.3 OpenAPI's Agent.Info, not recorded.
      Map<String, Object?> agent(String id, String mode, {bool hidden = false, String description = ''}) => {
        'id': id,
        'name': id,
        'description': description,
        'mode': mode,
        'hidden': hidden,
        'request': <String, Object?>{},
        'permissions': <Object?>[],
      };
      final http = ReplayHttpClient.script(
        [
          _head('turn_approvals.jsonl', '/prompt'),
          _line('out', {'id': 3, 'method': 'GET', 'path': '/api/agent'}),
          _line('in', {
            'id': 3,
            'status': 200,
            'body': {
              'location': {'directory': _cwd},
              'data': [
                agent('build', 'primary', description: 'The default agent'),
                agent('plan', 'primary', description: 'Plans without changing files'),
                agent('general', 'subagent'),
                agent('title', 'primary', hidden: true),
                agent('docs', 'all', description: 'Writes the docs'),
              ],
            },
          }),
          _line('out', {
            'id': 4,
            'method': 'POST',
            'path': '/api/session/$_ses/agent',
            'body': {'agent': 'plan'},
          }),
          _line('in', {'id': 4, 'status': 204, 'body': null}),
        ].join('\n'),
      );
      final (:driver, data: _) = _driver(http);
      final session = await driver.start(_spec(initial: null));
      final native = session as NativeModes;
      final sets = <NativeModeSet>[];
      native.nativeModes.listen(sets.add);
      await pumpEventQueue();
      final modes = sets.last.modes;
      expect([for (final m in modes) m.id], ['build', 'plan', 'docs']);
      expect([for (final m in modes) m.policy], [AgentMode.ask, AgentMode.plan, AgentMode.ask]);
      expect(modes.every((m) => m.blocked == null), isTrue);
      expect(sets.last.current, 'build');
      await expectLater(native.setNativeMode('general'), throwsA(isA<HarnessError>()));
      await native.setNativeMode('plan');
      await pumpEventQueue();
      expect(sets.last.current, 'plan');
      http.channel.expectFinished();
      await session.close();
    },
  );

  test('compact is offered before the list loads, and a failed load is tried again by the next listen', () async {
    final http = ReplayHttpClient.script(
      [
        _head('turn_approvals.jsonl', '/prompt'),
        _line('out', {'id': 3, 'method': 'GET', 'path': '/api/command'}),
        _line('in', {
          'id': 3,
          'status': 503,
          'body': {'error': 'warming up'},
        }),
        _line('out', {'id': 4, 'method': 'GET', 'path': '/api/command'}),
        _line('in', {
          'id': 4,
          'status': 200,
          'body': {
            'data': [
              {'name': 'init', 'description': 'guided AGENTS.md setup'},
            ],
          },
        }),
      ].join('\n'),
    );
    final (:driver, data: _) = _driver(http);
    final session = await driver.start(_spec(initial: null));
    final native = session as HasNativeCommands;
    expect((await native.commands.first).map((c) => c.name), ['compact']);
    await pumpEventQueue();
    final lists = <List<NativeCommand>>[];
    native.commands.listen(lists.add);
    await pumpEventQueue();
    expect(lists.last.map((c) => c.name), ['compact', 'init']);
    http.channel.expectFinished();
    await session.close();
  });

  test('a session is created with our rules, listens before the first prompt, and answers per call', () async {
    final http = _replay('turn_approvals.jsonl');
    final (:driver, :data) = _driver(http);
    final session = await driver.start(_spec());
    expect(session.id, _ses);
    expect(session, isA<PerCallApprovals>());
    final sent = http.channel.sent;
    expect(sent.map((m) => m['path']).take(3), ['/api/event', '/api/session', '/api/session/$_ses/prompt']);
    expect((sent[1]['body']! as Map)['permissions'], openCodeSessionRules);
    expect(((sent[1]['body']! as Map)['location'] as Map)['directory'], _cwd);

    final events = await _collect(session);
    final calls = events.whereType<ActionCall>().toList();
    expect(calls, hasLength(2));
    expect(events.last, isA<StateChange>());
    await session.respond(accept: true, callIds: [calls[0].id]);
    await session.respond(accept: false, reason: 'Not now: write it as hello.md instead.', callIds: [calls[1].id]);
    await pumpEventQueue();
    final third = events.whereType<ActionCall>().last;
    expect(third.str('path'), '$_cwd/hello.md');
    // OpenCode no longer has the request (404): that counts as answered.
    await session.respond(accept: true, callIds: [third.id]);
    await pumpEventQueue();
    http.channel.expectFinished();

    expect(_replies(http), [
      {'decision': 'once'},
      {'decision': 'reject', 'message': 'Not now: write it as hello.md instead.'},
      {'decision': 'once'},
    ]);
    expect(events.whereType<ToolResult>().map((r) => r.outcome), [
      ToolOutcome.ok,
      ToolOutcome.rejected,
      ToolOutcome.ok,
    ]);
    expect(events.whereType<StateChange>().last.executionStatus, ExecutionStatus.finished);
    _expectAuth(http);
    // What attach needs is kept.
    final record = jsonDecode(File('${data.path}/driver-sessions/opencode/$_ses.json').readAsStringSync()) as Map;
    expect(record['workingDir'], _cwd);
    expect(record['sessionTag'], 'tag-1');
    expect(await driver.statuses([_ses, 'ses_other']), {_ses: ExecutionStatus.finished});
    await session.close();
    expect(await driver.statuses([_ses]), {_ses: ExecutionStatus.idle});
  });

  test('interrupt, steer and a model switch use their own calls', () async {
    final http = _replay('interrupt_steer.jsonl');
    final (:driver, data: _) = _driver(http);
    final session = await driver.start(_spec(model: 'default', initial: 'Run the shell command `sleep 30` once.'));
    final events = await _collect(session);
    expect(events.whereType<ActionCall>().single.str('command'), 'sleep 30');
    await session.interrupt();
    await pumpEventQueue();
    expect(events.whereType<ToolResult>().single.outcome, ToolOutcome.error);
    expect(events.whereType<StateChange>().last.executionStatus, ExecutionStatus.idle);

    await session.send('Read README.md with your read tool, then tell me what it says.');
    await pumpEventQueue();
    await (session as SteersRuns).steer('Also: end your reply with the word DONE.');
    await pumpEventQueue();
    await session.respond(accept: true);
    await pumpEventQueue();
    expect(events.whereType<ChatMessage>().last.text, endsWith('DONE'));
    await session.switchLlm(_spec(model: 'opencode/crouton-alpha-free').withEffort('high'));
    http.channel.expectFinished();
    // The prompt of a fresh session names no model when the app has none.
    expect((http.channel.sent[1]['body']! as Map).containsKey('model'), isFalse);
    expect(_replies(http).every((r) => r['decision'] != 'always'), isTrue);
    _expectAuth(http);
    await session.close();
  });

  test('refusing every waiting call without a reason sends a bare reject, which parks the run', () async {
    final http = _replay('external_dir_cancel.jsonl');
    final (:driver, data: _) = _driver(http);
    final session = await driver.start(_spec(model: 'x', initial: 'Read /etc/hosts.'));
    final events = await _collect(session);
    await session.respond(accept: true, callIds: [events.whereType<ActionCall>().single.id]);
    await pumpEventQueue();
    await session.respond(accept: false);
    await pumpEventQueue();
    http.channel.expectFinished();
    expect(_replies(http), [
      {'decision': 'once'},
      {'decision': 'reject'},
    ]);
    expect(events.whereType<ToolResult>().last.outcome, ToolOutcome.rejected);
    expect(events.whereType<StateChange>().last.executionStatus, ExecutionStatus.idle);
    await session.close();
  });

  test('attach replays history and waiting requests, and a dropped stream resyncs without repeats', () async {
    final http = _replay('attach_resync.jsonl');
    final (:driver, :data) = _driver(http);
    File('${data.path}/driver-sessions/opencode/$_ses.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({'workingDir': _cwd, 'sessionTag': 'tag-1'}));
    final session = await driver.attach(_ses);
    final events = await _collect(session);
    http.channel.expectFinished();
    final users = events.whereType<ChatMessage>().where((m) => m.fromUser).map((m) => m.id).toList();
    expect(users, [
      'msg_1a52059b2001NhaGFuWEzjzRTx',
      'msg_1a5209695001Wn4lAj5GApp3qQ',
      'msg_1a521520c0018PheqdCNWHB3wX',
    ]);
    final connections = events.whereType<ConnectionChange>().map((c) => c.connected).toList();
    expect(connections, [false, true]);
    final ids = [
      for (final e in events)
        if (e is! StateChange && e is! ConnectionChange && e is! StreamDelta) e.id,
    ];
    expect(ids.toSet(), hasLength(ids.length));
    expect(events.whereType<ActionCall>().last.str('command'), 'sleep 30');
    expect(events.whereType<StateChange>().last.executionStatus, ExecutionStatus.waitingForConfirmation);
    expect(await driver.statuses([_ses]), {_ses: ExecutionStatus.waitingForConfirmation});
    // Reopened again while open: the same session.
    expect(await driver.attach(_ses), same(session));
    _expectAuth(http);
    await session.close();
  });

  test('attachBriefed: the new server gets the new token and skills in its env; plain attach gets none', () async {
    for (final briefed in [true, false]) {
      final envs = <Map<String, String>>[];
      final (:driver, :data) = _driver(_replay('attach_resync.jsonl'), envs: envs);
      final record = File('${data.path}/driver-sessions/opencode/$_ses.json')
        ..createSync(recursive: true)
        ..writeAsStringSync(jsonEncode({'workingDir': _cwd, 'sessionTag': 'tag-1'}));
      final session = briefed
          ? await driver.attachBriefed(
              _ses,
              const DriverBriefing(mcpUrl: 'http://127.0.0.1:7001/mcp', mcpToken: 'tok-new', skillDir: '/s/skills'),
            )
          : await driver.attach(_ses);
      final env = envs.single;
      if (briefed) {
        expect(env[tokenEnvVar], 'tok-new');
        expect(env['OPENCODE_CONFIG_CONTENT'], contains('127.0.0.1:7001'));
        expect(env['OPENCODE_CONFIG_CONTENT'], isNot(contains('tok-new')));
      } else {
        expect(env, isEmpty);
      }
      expect(record.readAsStringSync(), isNot(contains('tok-')));
      await session.close();
    }
  });

  test("attach without a record says it can't find the session", () async {
    final (:driver, data: _) = _driver(ReplayHttpClient.script(''));
    await expectLater(driver.attach('ses_gone'), throwsA(isA<HarnessError>()));
  });

  test('rewinding is refused; models without a provider are refused for a switch', () async {
    final http = _replay('external_dir_cancel.jsonl');
    final (:driver, data: _) = _driver(http);
    final session = await driver.start(_spec(model: 'x', initial: null));
    await expectLater(session.rewindTo(null), throwsA(isA<HarnessError>()));
    await expectLater(session.switchLlm(_spec(model: 'plain')), throwsA(isA<HarnessError>()));
    await session.close();
  });

  test('refusing every waiting call with a reason hands the model the reason, then stops the run', () async {
    const ses = 'ses_e5adcc5e9ffeq46VWxD6qlLA9d';
    final http = ReplayHttpClient.script(
      [
        _head('external_dir_cancel.jsonl', '/reply'),
        _line('out', {
          'id': 4,
          'method': 'POST',
          'path': '/api/session/$ses/permission/per_1a5234e1d00183JhPxd9xRzFEu/reply',
          'body': {'decision': 'reject', 'message': 'Use pnpm, not npm.'},
        }),
        _line('in', {'id': 4, 'status': 204}),
        _line('out', {'id': 5, 'method': 'POST', 'path': '/api/session/$ses/interrupt'}),
        _line('in', {
          'id': 5,
          'status': 200,
          'body': {'interrupted': true},
        }),
      ].join('\n'),
    );
    final (:driver, data: _) = _driver(http);
    final session = await driver.start(_spec(model: 'x', initial: 'Read /etc/hosts.'));
    await _collect(session);
    await session.respond(accept: false, reason: 'Use pnpm, not npm.');
    await pumpEventQueue();
    http.channel.expectFinished();
    await session.close();
  });

  test('a first prompt OpenCode refuses ends the server, and nothing of the session stays', () async {
    final http = ReplayHttpClient.script(
      [
        _head('turn_approvals.jsonl', '/prompt'),
        _line('out', {
          'id': 3,
          'method': 'POST',
          'path': '/api/session/$_ses/prompt',
          'body': {'text': '{{any}}'},
        }),
        _line('in', {
          'id': 3,
          'status': 500,
          'body': {'message': 'boom'},
        }),
      ].join('\n'),
    );
    final process = _Process();
    final (:driver, data: _) = _driver(http, process: process);
    await expectLater(driver.start(_spec()), throwsA(isA<OpenCodeHttpError>()));
    http.channel.expectFinished();
    expect(process.closed, isTrue);
    // Not open any more: only the record says it existed.
    expect(await driver.statuses([_ses]), {_ses: ExecutionStatus.idle});
  });

  test('a stream that drops before it is connected fails the start, with no reconnecting after', () async {
    final http = ReplayHttpClient.script(
      [
        _line('out', {'id': 1, 'method': 'GET', 'path': '/api/event'}),
        jsonEncode({
          'dir': 'in',
          'msg': {'sse': 'drop'},
        }),
      ].join('\n'),
    );
    final process = _Process();
    final (:driver, data: _) = _driver(http, process: process);
    await expectLater(driver.start(_spec()), throwsA(isA<HarnessError>()));
    await pumpEventQueue();
    // A reconnect would have asked for the stream again, past the script's end.
    http.channel.expectFinished();
    expect(http.channel.sent, hasLength(1));
    expect(process.closed, isTrue);
  });

  test('reopening a session whose run was cut off when the app quit leaves it idle, not running', () async {
    final http = ReplayHttpClient.script(
      [
        _line('out', {'id': 1, 'method': 'GET', 'path': '/api/event'}),
        jsonEncode({
          'dir': 'in',
          'msg': {
            'event': {'type': 'server.connected', 'data': <String, Object?>{}},
          },
        }),
        _line('out', {
          'id': 2,
          'method': 'GET',
          'path': '/api/session/$_ses/message',
          'query': {'order': 'asc', 'limit': '100'},
        }),
        _line('in', {
          'id': 2,
          'status': 200,
          'body': {
            'data': [
              {
                'id': 'msg_u',
                'type': 'user',
                'text': 'Run the tests.',
                'time': {'created': 1},
              },
              {
                'id': 'msg_a',
                'type': 'assistant',
                'time': {'created': 2},
                'content': <Object?>[],
              },
            ],
          },
        }),
        _line('out', {'id': 3, 'method': 'GET', 'path': '/api/session/$_ses/permission'}),
        _line('in', {
          'id': 3,
          'status': 200,
          'body': {'data': <Object?>[]},
        }),
        _line('out', {'id': 4, 'method': 'GET', 'path': '/api/session/active'}),
        _line('in', {
          'id': 4,
          'status': 200,
          'body': {'data': <String, Object?>{}},
        }),
      ].join('\n'),
    );
    final (:driver, :data) = _driver(http);
    File('${data.path}/driver-sessions/opencode/$_ses.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({'workingDir': _cwd, 'sessionTag': 'tag-1'}));
    final session = await driver.attach(_ses);
    final events = await _collect(session);
    http.channel.expectFinished();
    expect(events.whereType<StateChange>().last.executionStatus, ExecutionStatus.idle);
    expect(await driver.statuses([_ses]), {_ses: ExecutionStatus.idle});
    await session.close();
  });

  test('the executable is looked up once per driver, not for every session', () async {
    var lookups = 0;
    final (:driver, data: _) = _driver(_replay('external_dir_cancel.jsonl'), found: () => lookups++);
    final session = await driver.start(_spec(model: 'x', initial: null));
    await session.close();
    await expectLater(driver.attach('ses_gone'), throwsA(isA<HarnessError>()));
    await driver.models();
    expect(lookups, 1);
  });
}

extension on SessionSpec {
  SessionSpec withEffort(String effort) => SessionSpec(
    workingDir: workingDir,
    model: model,
    mode: mode,
    llmBaseUrl: llmBaseUrl,
    llmApiKey: llmApiKey,
    sessionTag: sessionTag,
    effort: effort,
  );
}
