import 'dart:convert';
import 'dart:io';

import 'package:every_ai/features/code/domain/agent_mode.dart';
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

/// A driver whose server is [http] playing a recording.
({OpenCodeDriver driver, Directory data}) _driver(ReplayHttpClient http) {
  final data = Directory.systemTemp.createTempSync('opencode_session_test');
  addTearDown(() => data.deleteSync(recursive: true));
  final driver = OpenCodeDriver(
    which: (_) async => '/bin/echo',
    run: (exe, args) async => (exitCode: 0, stdout: File('$_dir/auth_list.json').readAsStringSync()),
    dataDir: () async => data.path,
    reconnectDelay: Duration.zero,
    launch: ({required executable, required cwd, required sessionTag, required logPath, env = const {}}) async =>
        OpenCodeServer(base: Uri.parse('http://127.0.0.1:4096'), password: 'pw', client: http),
  );
  return (driver: driver, data: data);
}

ReplayHttpClient _replay(String name) => ReplayHttpClient.script(File('$_dir/$name').readAsStringSync());

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

  test('refusing every waiting call sends a bare reject, which parks the run', () async {
    final http = _replay('external_dir_cancel.jsonl');
    final (:driver, data: _) = _driver(http);
    final session = await driver.start(_spec(model: 'x', initial: 'Read /etc/hosts.'));
    final events = await _collect(session);
    await session.respond(accept: true, callIds: [events.whereType<ActionCall>().single.id]);
    await pumpEventQueue();
    await session.respond(accept: false, reason: 'The user said no.');
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
