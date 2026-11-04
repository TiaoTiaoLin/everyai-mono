// The Codex driver against hand-built `codex app-server` transcripts.
//
// UNVERIFIED: every fixture in test/fixtures/drivers/codex/ is hand-built from the generated schema in
// github.com/openai/codex codex-rs/app-server-protocol at 3a2788e6 (Codex isn't installed here, by the owner's
// choice). Replace them with a live recording when one can be made; real traffic may differ in order and nulls.
import 'dart:io';

import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/permissions.dart' show floorReason;
import 'package:every_ai/features/code/drivers/codex/codex_driver.dart';
import 'package:every_ai/features/code/drivers/codex/codex_mapping.dart';
import 'package:every_ai/features/code/drivers/driver.dart';
import 'package:every_ai/features/code/drivers/driver_policy.dart';
import 'package:every_ai/features/code/drivers/json_rpc.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/replay_transport.dart';

const _fixtures = 'test/fixtures/drivers/codex';

ReplayChannel _fixture(String name) => ReplayChannel.file('$_fixtures/$name.jsonl');

/// The lines of fixture [name] up to and including the first one with [until].
String _upTo(String name, String until) {
  final lines = File('$_fixtures/$name.jsonl').readAsLinesSync();
  return lines.take(lines.indexWhere((l) => l.contains(until)) + 1).join('\n');
}

/// thr_1 started, with turn_1 ("Run the tests") running (approve_command.jsonl).
String _running() => _upTo('approve_command', '"method":"turn/started"');

/// The text of each turn/start sent so far.
List<String> _turnStarts(ReplayChannel c) => [
  for (final m in c.sent)
    if (m['method'] == 'turn/start') (((m['params']! as Map)['input'] as List).first as Map)['text'] as String,
];

typedef _Spawned = ({List<String> args, String cwd, Map<String, String> env, String sessionTag});

/// A driver whose processes are [channels], in order; what it asked to
/// start lands in [spawned].
CodexDriver _driver(String data, List<LineChannel> channels, [List<_Spawned>? spawned]) => CodexDriver(
  which: (_) async => '/bin/echo',
  dataDir: () async => data,
  spawn: ({required args, required cwd, required env, required sessionTag}) async {
    spawned?.add((args: args, cwd: cwd, env: env, sessionTag: sessionTag));
    if (channels.isEmpty) fail('started Codex more often than expected');
    return channels.removeAt(0);
  },
);

SessionSpec _spec(String dir, {AgentMode mode = AgentMode.ask, DriverBriefing? briefing}) => SessionSpec(
  workingDir: dir,
  model: 'gpt-5.5-codex',
  mode: mode,
  llmBaseUrl: '',
  llmApiKey: '',
  sessionTag: 'tag-1',
  briefing: briefing,
);

/// Collects a session's events.
List<HarnessEvent> _listen(HarnessSession s) {
  final out = <HarnessEvent>[];
  s.events.listen(out.add);
  return out;
}

List<ExecutionStatus> _states(List<HarnessEvent> events) => [
  for (final e in events)
    if (e is StateChange) e.executionStatus,
];

void main() {
  late Directory tmp;
  late String work;
  late String data;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('codex_driver_test');
    work = '${tmp.path}/work';
    data = '${tmp.path}/data';
    Directory(work).createSync();
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  group('mapping', () {
    test('every mode lets Codex ask and the app answer; no sandbox outside Plan, Plan read-only with network', () {
      List<Object?> flat(CodexPolicy p) => [p.approvalPolicy, p.sandbox, p.sandboxPolicy];
      expect(flat(codexPolicy(AgentMode.plan)), [
        'untrusted',
        'read-only',
        {'type': 'readOnly', 'networkAccess': true},
      ]);
      for (final m in [AgentMode.ask, AgentMode.autoEdit, AgentMode.fullAuto]) {
        expect(flat(codexPolicy(m)), [
          'untrusted',
          'danger-full-access',
          {'type': 'dangerFullAccess'},
        ], reason: m.name);
      }
    });

    test('commands run through a shell are unwrapped; anything else is left alone', () {
      expect(unwrapCommand("/bin/zsh -lc 'npm test'"), 'npm test');
      expect(unwrapCommand('bash -c "git status && git diff"'), 'git status && git diff');
      expect(unwrapCommand('npm test'), 'npm test');
      expect(unwrapCommand("python -c 'print(1)'"), "python -c 'print(1)'");
      expect(unwrapCommand("bash -lc 'a' extra"), "bash -lc 'a' extra");
    });

    test('usage: running totals become deltas, falling back to the last call when a counter goes down', () {
      const t1 = (input: 1000, cached: 200, output: 50, total: 1050);
      const t2 = (input: 2500, cached: 1200, output: 90, total: 2590);
      const last2 = (input: 1500, cached: 1000, output: 40, total: 1540);
      final d = usageDelta(t1, t2, last2, turnId: 't', onPlan: true)!;
      expect(
        (d.id, d.input, d.cached, d.output, d.contextTokens, d.onPlan),
        ('usage-t-2590', 1500, 1000, 40, 1540, true),
      );
      const reset = (input: 10, cached: 0, output: 5, total: 15);
      final r = usageDelta(t2, reset, reset, turnId: 't', onPlan: false)!;
      expect((r.input, r.output), (10, 5));
      expect(usageDelta(t2, t2, last2, turnId: 't', onPlan: false), isNull);
    });
  });

  group('start', () {
    test('with a briefing: handshake, skill root, developer instructions; the token only in env', () async {
      final skills = '${tmp.path}/session/briefing/skills';
      Directory(skills).createSync(recursive: true);
      File('${tmp.path}/session/briefing/session.md').writeAsStringSync('You are in an EveryAI session.');
      final channel = _fixture('start');
      final spawned = <_Spawned>[];
      final driver = _driver(data, [channel], spawned);
      final s = await driver.start(
        _spec(
          work,
          briefing: DriverBriefing(mcpUrl: 'http://127.0.0.1:4567/mcp', mcpToken: 'tok-secret', skillDir: skills),
        ),
      );
      channel.expectFinished();
      expect(s.id, 'thr_1');
      expect(channel.sent.first.containsKey('jsonrpc'), isFalse);
      expect(channel.sent[3]['params'], {
        'extraRoots': [skills],
      });
      final launch = spawned.single;
      expect((launch.cwd, launch.sessionTag), (work, 'tag-1'));
      expect(launch.args, [
        '-c',
        'mcp_servers.everyai.url="http://127.0.0.1:4567/mcp"',
        '-c',
        'mcp_servers.everyai.bearer_token_env_var="EVERYAI_MCP_TOKEN"',
        '-c',
        'mcp_servers.everyai.tool_timeout_sec=330',
        '-c',
        'mcp_servers.everyai.default_tools_approval_mode="approve"',
      ]);
      expect(launch.args.join(' '), isNot(contains('tok-secret')));
      expect(launch.env, {'EVERYAI_MCP_TOKEN': 'tok-secret'});
      expect(File('$data/drivers/codex/threads/thr_1.json').existsSync(), isTrue);
      expect(await driver.statuses(['thr_1', 'other']), {'thr_1': ExecutionStatus.idle});
      await s.close();
    });

    test('without a briefing: no -c, no skill root, no instructions', () async {
      final channel = _fixture('approve_command');
      final spawned = <_Spawned>[];
      final s = await _driver(data, [channel], spawned).start(_spec(work));
      final threadStart = channel.sent.firstWhere((m) => m['method'] == 'thread/start');
      expect((threadStart['params']! as Map).containsKey('developerInstructions'), isFalse);
      expect(channel.sent.any((m) => m['method'] == 'skills/extraRoots/set'), isFalse);
      expect(spawned.single.args, isEmpty);
      expect(spawned.single.env, isEmpty);
      await s.close();
    });
  });

  test(
    'a turn: user message at once, reasoning, plan, steer, streamed text, usage, then the next turn in Plan',
    () async {
      final channel = _fixture('turn');
      final s = await _driver(data, [channel]).start(_spec(work));
      final events = _listen(s);
      await s.send('Fix the failing test', images: ['data:image/png;base64,iVBORw0KGgo=']);
      expect(events.whereType<ChatMessage>().first.fromUser, isTrue);
      await pumpEventQueue();
      await (s as SteersRuns).steer('Also update the README');
      await pumpEventQueue();
      await s.setMode(AgentMode.plan);
      // No turn is running now: the steer starts one.
      await (s as SteersRuns).steer('One more thing');
      await channel.finished;
      await pumpEventQueue();
      channel.expectFinished();

      final messages = events.whereType<ChatMessage>().toList();
      expect(
        [for (final m in messages) (m.fromUser, m.text, m.reasoning)],
        [
          (true, 'Fix the failing test', ''),
          (false, '', 'Looking at the test.'),
          (true, 'Also update the README', ''),
          (false, 'Fixed the test.', ''),
          (true, 'One more thing', ''),
        ],
      );
      final deltas = events.whereType<StreamDelta>().toList();
      expect(deltas.map((d) => d.reasoning).join(), 'Looking at the test.');
      expect(deltas.map((d) => d.content).join(), 'Fixed the test.');
      final plan = events.whereType<ActionCall>().single;
      expect(plan.actionKind, 'TaskTrackerAction');
      expect(plan.action['task_list'], [
        {'title': 'Read the test', 'status': 'done'},
        {'title': 'Fix the bug', 'status': 'in_progress'},
        {'title': 'Run the tests', 'status': 'todo'},
      ]);
      final usage = events.whereType<UsageReport>().toList();
      expect(
        [for (final u in usage) (u.input, u.cached, u.output, u.contextTokens, u.onPlan)],
        [(1000, 200, 50, 1050, true), (1500, 1000, 40, 1540, true)],
      );
      expect(_states(events), [ExecutionStatus.running, ExecutionStatus.finished, ExecutionStatus.finished]);
      await s.close();
    },
  );

  test('a command approval: the unwrapped command waits, accept goes back once, never for the session', () async {
    final channel = _fixture('approve_command');
    final s = await _driver(data, [channel]).start(_spec(work));
    final events = _listen(s);
    await s.send('Run the tests');
    await pumpEventQueue();
    final call = events.whereType<ActionCall>().single;
    expect(
      (call.id, call.actionKind, call.str('command'), call.str('cwd')),
      ('call_1', 'TerminalAction', 'npm test', work),
    );
    expect(autoDecidable(call), isTrue);
    expect(_states(events).last, ExecutionStatus.waitingForConfirmation);
    await s.respond(accept: true, callIds: ['call_1']);
    await channel.finished;
    await pumpEventQueue();
    channel.expectFinished();
    final result = events.whereType<ToolResult>().single;
    expect((result.actionId, result.outcome, result.text), ('call_1', ToolOutcome.ok, '3 passing\nExit code 0'));
    expect(_states(events), [
      ExecutionStatus.running,
      ExecutionStatus.waitingForConfirmation,
      ExecutionStatus.running,
      ExecutionStatus.finished,
    ]);
    expect(channel.sent.toString(), isNot(contains('acceptForSession')));
    await s.close();
  });

  test('file changes: decline by name with the reason as a steer; refusing them all cancels each', () async {
    final channel = _fixture('file_change');
    final s = await _driver(data, [channel]).start(_spec(work));
    final events = _listen(s);
    await s.send('Rename the helper');
    await pumpEventQueue();
    final edit = events.whereType<ActionCall>().single;
    expect(edit.actionKind, 'ApplyPatchAction');
    expect(edit.action['paths'], ['$work/lib/a.dart', '$work/lib/old.dart', '$work/lib/new.dart']);
    expect(edit.action['files'], [
      {'path': '$work/lib/a.dart', 'op': 'update'},
      {'path': '$work/lib/old.dart', 'op': 'move', 'to': '$work/lib/new.dart'},
    ]);
    expect(autoDecidable(edit), isTrue);
    await s.respond(accept: false, reason: 'Plan mode: no edits yet.', callIds: ['call_2']);
    await pumpEventQueue();
    final steer = channel.sent.firstWhere((m) => m['method'] == 'turn/steer');
    expect(((steer['params']! as Map)['input'] as List).single, {
      'type': 'text',
      'text':
          'EveryAI refused the edit to $work/lib/a.dart, $work/lib/old.dart, $work/lib/new.dart: Plan mode: no edits yet.',
    });
    expect(events.whereType<ActionCall>().map((c) => c.id), ['call_2', 'call_3', 'call_4']);
    await s.respond(accept: false, reason: 'Stopped by the user');
    await channel.finished;
    await pumpEventQueue();
    channel.expectFinished();
    final results = events.whereType<ToolResult>().toList();
    expect(
      [for (final r in results) (r.actionId, r.outcome)],
      [('call_2', ToolOutcome.rejected), ('call_3', ToolOutcome.rejected), ('call_4', ToolOutcome.rejected)],
    );
    expect(results.first.observation['reason'], 'Plan mode: no edits yet.');
    expect(channel.sent.where((m) => m['method'] == 'turn/steer'), hasLength(1));
    expect(_states(events).last, ExecutionStatus.paused);
    await s.close();
  });

  test('interrupt: turn/interrupt, the dropped approval is cancelled and a later answer sends nothing', () async {
    final channel = _fixture('interrupt');
    final s = await _driver(data, [channel]).start(_spec(work));
    final events = _listen(s);
    await s.send('Clean up');
    await pumpEventQueue();
    await s.interrupt();
    await channel.finished;
    await pumpEventQueue();
    channel.expectFinished();
    final sent = channel.sent.length;
    await s.respond(accept: true);
    expect(channel.sent, hasLength(sent));
    final result = events.whereType<ToolResult>().single;
    expect((result.actionId, result.outcome), ('call_9', ToolOutcome.rejected));
    expect(_states(events).last, ExecutionStatus.paused);
    await s.close();
  });

  test('Codex going away mid-turn: the waiting call is closed and the run fails', () async {
    // approve_command up to the approval request, then the process ends.
    final lines = File('$_fixtures/approve_command.jsonl').readAsLinesSync();
    final cut = lines.indexWhere((l) => l.contains('requestApproval'));
    final channel = ReplayChannel([...lines.take(cut + 1), '{"dir":"eof"}'].join('\n'));
    final s = await _driver(data, [channel]).start(_spec(work));
    final events = _listen(s);
    await s.send('Run the tests');
    await pumpEventQueue();
    final result = events.whereType<ToolResult>().single;
    expect((result.actionId, result.outcome), ('call_1', ToolOutcome.rejected));
    expect(events.whereType<ConversationFailure>().single.message, 'Codex stopped.');
    expect(_states(events).last, ExecutionStatus.error);
    await s.close();
  });

  test('other requests: MCP tool approval, URL elicitation, questions, client tools, permissions, v1', () async {
    final channel = _fixture('server_requests');
    final s = await _driver(data, [channel]).start(_spec(work));
    final events = _listen(s);
    await s.send('Look it up');
    await pumpEventQueue();
    final call = events.whereType<ActionCall>().single;
    expect((call.actionKind, call.toolName, call.action['q']), ('MCPToolAction', 'docs__search', 'riverpod'));
    expect(_states(events).last, ExecutionStatus.waitingForConfirmation);
    await s.respond(accept: true, callIds: [call.id]);
    await channel.finished;
    await pumpEventQueue();
    channel.expectFinished();
    expect(events.whereType<ToolResult>().single.outcome, ToolOutcome.ok);
    await s.close();
  });

  test('attach: thread/resume without turns, the journal replayed, open calls closed, then live', () async {
    final first = _fixture('approve_command');
    final a = await _driver(data, [first]).start(_spec(work));
    await a.send('Run the tests');
    await pumpEventQueue();
    await a.close();

    final channel = _fixture('resume');
    final spawned = <_Spawned>[];
    final s = await _driver(data, [channel], spawned).attach('thr_1');
    expect((spawned.single.cwd, spawned.single.sessionTag), (work, 'tag-1'));
    expect(spawned.single.args, isEmpty);
    final events = _listen(s);
    await pumpEventQueue();
    expect(
      [for (final e in events) e.runtimeType],
      [ChatMessage, StateChange, ActionCall, StateChange, ToolResult, StateChange],
    );
    final closed = events.whereType<ToolResult>().single;
    expect(
      (closed.actionId, closed.outcome, closed.text),
      ('call_1', ToolOutcome.error, 'Stopped when the app closed.'),
    );
    expect(_states(events).last, ExecutionStatus.idle);
    // The saved count Codex replays on resume isn't counted again.
    expect(events.whereType<UsageReport>(), isEmpty);

    await s.send('Carry on');
    await channel.finished;
    await pumpEventQueue();
    channel.expectFinished();
    final usage = events.whereType<UsageReport>().single;
    expect(
      (usage.id, usage.input, usage.cached, usage.output, usage.contextTokens, usage.onPlan),
      ('usage-turn_2-7900', 2500, 2000, 100, 2600, false),
    );
    final later = _listen(s);
    await pumpEventQueue();
    expect(later.where((e) => e is! StreamDelta).length, events.where((e) => e is! StreamDelta).length);
    await s.close();
  });

  test('a command whose item text Codex redacted is judged on the exact command in the request', () async {
    final channel = ReplayChannel('''
${_running()}
{"dir":"in","msg":{"method":"item/started","params":{"threadId":"thr_1","turnId":"turn_1","item":{"type":"commandExecution","id":"call_1","command":"/bin/zsh -lc 'echo token=[REDACTED_SECRET] -rf ~'","cwd":"{{cwd}}","status":"inProgress"}}}}
{"dir":"in","msg":{"id":0,"method":"item/commandExecution/requestApproval","params":{"threadId":"thr_1","turnId":"turn_1","itemId":"call_1","approvalId":null,"kind":"command","command":"/bin/zsh -lc 'echo token=aaaaaaaa;rm -rf ~'","cwd":"{{cwd}}","reason":null}}}
{"dir":"out","msg":{"id":0,"result":{"decision":"decline"}}}
{"dir":"in","msg":{"method":"item/completed","params":{"threadId":"thr_1","turnId":"turn_1","item":{"type":"commandExecution","id":"call_1","command":"/bin/zsh -lc 'echo token=[REDACTED_SECRET] -rf ~'","cwd":"{{cwd}}","status":"declined"}}}}
{"dir":"in","msg":{"method":"turn/completed","params":{"threadId":"thr_1","turn":{"id":"turn_1","status":"completed","items":[]}}}}
''');
    final s = await _driver(data, [channel]).start(_spec(work));
    final events = _listen(s);
    await s.send('Run the tests');
    await pumpEventQueue();
    final calls = events.whereType<ActionCall>().toList();
    expect(
      [for (final c in calls) (c.id, c.str('command'))],
      [('call_1', 'echo token=[REDACTED_SECRET] -rf ~'), ('call_1#exact', 'echo token=aaaaaaaa;rm -rf ~')],
    );
    final exact = calls.last;
    expect(autoDecidable(exact), isTrue);
    expect(floorReason(exact.str('command')), isNotNull);
    // Allowing the redacted copy decides nothing.
    final sent = channel.sent.length;
    await s.respond(accept: true, callIds: ['call_1']);
    expect(channel.sent, hasLength(sent));
    await s.respond(accept: false, callIds: ['call_1#exact']);
    await channel.finished;
    await pumpEventQueue();
    channel.expectFinished();
    expect(
      [for (final r in events.whereType<ToolResult>()) (r.actionId, r.outcome)],
      [('call_1#exact', ToolOutcome.rejected), ('call_1', ToolOutcome.rejected)],
    );
    await s.close();
  });

  test('a network grant for a running command is its own call, which only the user may approve', () async {
    final channel = ReplayChannel('''
${_running()}
{"dir":"in","msg":{"method":"item/started","params":{"threadId":"thr_1","turnId":"turn_1","item":{"type":"commandExecution","id":"call_1","command":"/bin/zsh -lc 'npm install'","cwd":"{{cwd}}","status":"inProgress"}}}}
{"dir":"in","msg":{"id":0,"method":"item/commandExecution/requestApproval","params":{"threadId":"thr_1","turnId":"turn_1","itemId":"call_1","approvalId":null,"kind":"command","command":"/bin/zsh -lc 'npm install'","cwd":"{{cwd}}","reason":"needs the registry","networkApprovalContext":{"host":"registry.npmjs.org","protocol":"https"}}}}
{"dir":"out","msg":{"id":0,"result":{"decision":"accept"}}}
{"dir":"in","msg":{"method":"item/completed","params":{"threadId":"thr_1","turnId":"turn_1","item":{"type":"commandExecution","id":"call_1","command":"/bin/zsh -lc 'npm install'","cwd":"{{cwd}}","status":"completed","aggregatedOutput":"added 3 packages","exitCode":0}}}}
{"dir":"in","msg":{"method":"turn/completed","params":{"threadId":"thr_1","turn":{"id":"turn_1","status":"completed","items":[]}}}}
''');
    final s = await _driver(data, [channel]).start(_spec(work));
    final events = _listen(s);
    await s.send('Run the tests');
    await pumpEventQueue();
    final net = events.whereType<ActionCall>().last;
    expect(
      (net.id, net.actionKind, net.str('host'), net.str('command'), net.str('reason')),
      ('call_1#network', 'CodexNetworkAction', 'registry.npmjs.org', 'npm install', 'needs the registry'),
    );
    expect(autoDecidable(net), isFalse);
    await s.respond(accept: true, callIds: ['call_1#network']);
    await channel.finished;
    await pumpEventQueue();
    channel.expectFinished();
    expect(
      [for (final r in events.whereType<ToolResult>()) (r.actionId, r.outcome)],
      [('call_1#network', ToolOutcome.ok), ('call_1', ToolOutcome.ok)],
    );
    await s.close();
  });

  test('two sends close together: the second turn/start waits for the first turn', () async {
    final channel = ReplayChannel('''
${_upTo('approve_command', '"id":3,"result"')}
{"dir":"out","msg":{"id":4,"method":"turn/start","params":{"threadId":"thr_1","input":[{"type":"text","text":"first"}],"model":"gpt-5.5-codex","approvalPolicy":"untrusted","sandboxPolicy":{"type":"dangerFullAccess"}}}}
{"dir":"in","msg":{"id":4,"result":{"turn":{"id":"turn_1","status":"inProgress","items":[]}}}}
{"dir":"in","msg":{"method":"turn/started","params":{"threadId":"thr_1","turn":{"id":"turn_1","status":"inProgress","items":[]}}}}
{"dir":"out","msg":{"id":5,"method":"turn/interrupt","params":{"threadId":"thr_1","turnId":"turn_1"}}}
{"dir":"in","msg":{"id":5,"result":{}}}
{"dir":"in","msg":{"method":"turn/completed","params":{"threadId":"thr_1","turn":{"id":"turn_1","status":"interrupted","items":[]}}}}
{"dir":"out","msg":{"id":6,"method":"turn/start","params":{"threadId":"thr_1","input":[{"type":"text","text":"second"}],"model":"gpt-5.5-codex","approvalPolicy":"untrusted","sandboxPolicy":{"type":"dangerFullAccess"}}}}
{"dir":"in","msg":{"id":6,"result":{"turn":{"id":"turn_2","status":"inProgress","items":[]}}}}
{"dir":"in","msg":{"method":"turn/completed","params":{"threadId":"thr_1","turn":{"id":"turn_2","status":"completed","items":[]}}}}
''');
    final s = await _driver(data, [channel]).start(_spec(work));
    final first = s.send('first');
    final second = s.send('second');
    await pumpEventQueue();
    expect(_turnStarts(channel), ['first']);
    await s.interrupt();
    await Future.wait([first, second]);
    await channel.finished;
    await pumpEventQueue();
    channel.expectFinished();
    expect(_turnStarts(channel), ['first', 'second']);
    await s.close();
  });

  test('a mode, model or effort changed after start is what a reopened session runs with', () async {
    final s = await _driver(data, [_fixture('approve_command')]).start(_spec(work));
    await s.switchLlm(
      const SessionSpec(
        workingDir: '',
        model: 'gpt-5.4-mini',
        effort: 'max',
        mode: AgentMode.ask,
        llmBaseUrl: '',
        llmApiKey: '',
        sessionTag: '',
      ),
    );
    await s.setMode(AgentMode.plan);
    await s.close();

    final channel = ReplayChannel('''
${_upTo('resume', '"id":2,"result"')}
{"dir":"out","msg":{"id":3,"method":"thread/resume","params":{"threadId":"thr_1","cwd":"{{cwd}}","excludeTurns":true,"approvalPolicy":"untrusted","sandbox":"read-only"}}}
{"dir":"in","msg":{"id":3,"result":{"thread":{"id":"thr_1","cwd":"{{cwd}}","turns":[]}}}}
{"dir":"out","msg":{"id":4,"method":"turn/start","params":{"threadId":"thr_1","input":[{"type":"text","text":"Carry on"}],"model":"gpt-5.4-mini","effort":"xhigh","approvalPolicy":"untrusted","sandboxPolicy":{"type":"readOnly","networkAccess":true}}}}
{"dir":"in","msg":{"id":4,"result":{"turn":{"id":"turn_2","status":"inProgress","items":[]}}}}
{"dir":"in","msg":{"method":"turn/completed","params":{"threadId":"thr_1","turn":{"id":"turn_2","status":"completed","items":[]}}}}
''');
    final again = await _driver(data, [channel]).attach('thr_1');
    await again.send('Carry on');
    await channel.finished;
    await pumpEventQueue();
    channel.expectFinished();
    await again.close();
  });

  test('Codex going away on its own: the next send starts it again on the same thread', () async {
    final lines = File('$_fixtures/approve_command.jsonl').readAsLinesSync();
    final cut = lines.indexWhere((l) => l.contains('requestApproval'));
    final dead = ReplayChannel([...lines.take(cut + 1), '{"dir":"eof"}'].join('\n'));
    final channel = ReplayChannel('''
${_upTo('resume', '"id":2,"result"')}
{"dir":"out","msg":{"id":3,"method":"thread/resume","params":{"threadId":"thr_1","cwd":"{{cwd}}","excludeTurns":true,"approvalPolicy":"untrusted","sandbox":"danger-full-access"}}}
{"dir":"in","msg":{"id":3,"result":{"thread":{"id":"thr_1","cwd":"{{cwd}}","turns":[]}}}}
{"dir":"out","msg":{"id":4,"method":"turn/start","params":{"threadId":"thr_1","input":[{"type":"text","text":"Try again"}],"model":"gpt-5.5-codex","approvalPolicy":"untrusted","sandboxPolicy":{"type":"dangerFullAccess"}}}}
{"dir":"in","msg":{"id":4,"result":{"turn":{"id":"turn_2","status":"inProgress","items":[]}}}}
{"dir":"in","msg":{"method":"turn/started","params":{"threadId":"thr_1","turn":{"id":"turn_2","status":"inProgress","items":[]}}}}
{"dir":"in","msg":{"method":"turn/completed","params":{"threadId":"thr_1","turn":{"id":"turn_2","status":"completed","items":[]}}}}
''');
    final spawned = <_Spawned>[];
    final driver = _driver(data, [dead, channel], spawned);
    final s = await driver.start(_spec(work));
    final events = _listen(s);
    await s.send('Run the tests');
    await pumpEventQueue();
    expect(_states(events).last, ExecutionStatus.error);
    expect(await driver.attach('thr_1'), same(s));
    await s.send('Try again');
    await channel.finished;
    await pumpEventQueue();
    channel.expectFinished();
    expect(spawned, hasLength(2));
    expect((spawned.last.cwd, spawned.last.sessionTag), (work, 'tag-1'));
    final states = _states(events);
    expect(states.sublist(states.indexOf(ExecutionStatus.error)), [
      ExecutionStatus.error,
      ExecutionStatus.idle,
      ExecutionStatus.running,
      ExecutionStatus.finished,
    ]);
    await s.close();
  });

  test('attachBriefed: the reopened process and its respawn carry the new token and skill root', () async {
    final skills = '${tmp.path}/session/briefing/skills';
    Directory(skills).createSync(recursive: true);
    File('${tmp.path}/session/briefing/session.md').writeAsStringSync('You are in an EveryAI session.');
    final first = _fixture('start');
    final spawned = <_Spawned>[];
    final a = await _driver(data, [first], spawned).start(
      _spec(
        work,
        briefing: DriverBriefing(mcpUrl: 'http://127.0.0.1:4567/mcp', mcpToken: 'tok-old', skillDir: skills),
      ),
    );
    await a.close();
    expect(spawned.single.env, {'EVERYAI_MCP_TOKEN': 'tok-old'});

    String reopen({required bool dies}) =>
        '''
${_upTo('resume', '"id":2,"result"')}
{"dir":"out","msg":{"id":3,"method":"skills/extraRoots/set","params":{"extraRoots":["$skills"]}}}
{"dir":"in","msg":{"id":3,"result":{}}}
{"dir":"out","msg":{"id":4,"method":"thread/resume","params":{"threadId":"thr_1","cwd":"{{cwd}}","excludeTurns":true,"approvalPolicy":"untrusted","sandbox":"danger-full-access"}}}
{"dir":"in","msg":{"id":4,"result":{"thread":{"id":"thr_1","cwd":"{{cwd}}","turns":[]}}}}
${dies ? '{"dir":"eof"}' : ''}
''';
    final channel = ReplayChannel(reopen(dies: true));
    final again = ReplayChannel(reopen(dies: false));
    spawned.clear();
    final s = await _driver(data, [channel, again], spawned).attachBriefed(
      'thr_1',
      DriverBriefing(mcpUrl: 'http://127.0.0.1:4568/mcp', mcpToken: 'tok-new', skillDir: skills),
    );
    await channel.finished;
    await pumpEventQueue();
    channel.expectFinished();
    // Gone on its own: Retry starts it again with the same briefing.
    await s.resume();
    await again.finished;
    again.expectFinished();
    expect(spawned, hasLength(2));
    for (final launch in spawned) {
      expect(launch.env, {'EVERYAI_MCP_TOKEN': 'tok-new'});
      expect(launch.args, contains('mcp_servers.everyai.url="http://127.0.0.1:4568/mcp"'));
      expect(launch.args.join(' '), isNot(contains('tok-')));
    }
    for (final f in Directory(data).listSync(recursive: true).whereType<File>()) {
      expect(f.readAsStringSync(), isNot(contains('tok-')), reason: f.path);
    }
    await s.close();
  });

  test('attach without saved details is refused', () async {
    await expectLater(
      _driver(data, []).attach('nope'),
      throwsA(isA<HarnessError>().having((e) => e.message, 'message', contains("can't be reopened"))),
    );
  });

  group('detect and models', () {
    test('not on PATH: not installed, nothing started, and start says so', () async {
      final d = CodexDriver(
        which: (_) async => null,
        dataDir: () async => data,
        spawn: ({required args, required cwd, required env, required sessionTag}) async => fail('started Codex'),
      );
      final s = await d.detect();
      expect((s.installed, s.signedIn, s.problem), (false, null, null));
      expect(await d.models(), isEmpty);
      await expectLater(
        d.start(_spec(work)),
        throwsA(isA<HarnessError>().having((e) => e.message, 'message', contains("isn't installed"))),
      );
    });

    test('signed in with ChatGPT, not signed in, or the probe failing', () async {
      final chatgpt = ReplayChannel(
        File('$_fixtures/probe.jsonl').readAsStringSync().replaceFirst(
          '"account":null',
          '"account":{"type":"chatgpt","email":"user@example.com","planType":"plus"}',
        ),
      );
      final ok = await _driver(data, [chatgpt]).detect();
      expect((ok.installed, ok.path, ok.signedIn, ok.problem), (true, '/bin/echo', true, null));
      final channel = _fixture('probe');
      final out = await _driver(data, [channel]).detect();
      channel.expectFinished();
      expect((out.installed, out.signedIn), (true, false));
      final broken = ReplayChannel('''
{"dir":"out","msg":{"id":1,"method":"initialize","params":"{{any}}"}}
{"dir":"eof"}
''');
      final failed = await _driver(data, [broken]).detect();
      expect((failed.installed, failed.signedIn), (true, null));
      expect(failed.problem, contains("Couldn't ask Codex"));
    });

    test('models: two pages, hidden ones dropped, efforts kept', () async {
      final channel = _fixture('models');
      final models = await _driver(data, [channel]).models();
      channel.expectFinished();
      expect(
        [
          for (final m in models) [m.id, m.label, m.isDefault, m.efforts],
        ],
        [
          [
            'gpt-5.5-codex',
            'GPT-5.5 Codex',
            true,
            ['low', 'medium', 'high', 'xhigh'],
          ],
          [
            'gpt-5.4-mini',
            'GPT-5.4 mini',
            false,
            ['low'],
          ],
        ],
      );
    });
  });

  test('caps and markers match what the session implements', () async {
    final channel = _fixture('approve_command');
    final d = _driver(data, [channel]);
    final s = await d.start(_spec(work));
    expect(s, isA<PerCallApprovals>());
    expect(s, isA<SteersRuns>());
    expect(d.caps, containsAll([DriverCap.steer, DriverCap.perCallApprovals, DriverCap.resume, DriverCap.usage]));
    expect(d.caps.intersection({DriverCap.fork, DriverCap.rewind, DriverCap.subagents}), isEmpty);
    await expectLater(s.rewindTo(null), throwsA(isA<HarnessError>()));
    await s.close();
  });
}
