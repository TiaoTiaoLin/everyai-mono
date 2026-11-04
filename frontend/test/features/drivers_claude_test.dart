import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/drivers/briefing/briefing_types.dart';
import 'package:every_ai/features/code/drivers/claude/claude_driver.dart';
import 'package:every_ai/features/code/drivers/claude/claude_wire.dart';
import 'package:every_ai/features/code/drivers/driver.dart';
import 'package:every_ai/features/code/drivers/driver_policy.dart';
import 'package:every_ai/features/code/drivers/json_rpc.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/replay_transport.dart';

// Recorded from claude 2.1.318 (scrubbed; see
// docs/research/batches/multi-harness/run2/c1.md), with our initialize request.
String _fixture(String name) => File('test/fixtures/drivers/claude/$name').readAsStringSync();

typedef _Spawned = ({List<String> args, String cwd, Map<String, String> env});

/// Hands out [channels] in order and records how each process was started.
final class _Spawner {
  _Spawner(this.channels);
  final List<LineChannel> channels;
  final calls = <_Spawned>[];

  Future<LineChannel> call(
    List<String> args, {
    required String cwd,
    required Map<String, String> env,
    required String sessionTag,
    required String logPath,
  }) async {
    calls.add((args: args, cwd: cwd, env: env));
    if (channels.isEmpty) throw StateError('no CLI here');
    return channels.removeAt(0);
  }
}

SessionSpec _spec({String? message, AgentMode mode = AgentMode.ask, String model = 'haiku', String? effort}) =>
    SessionSpec(
      workingDir: '/work/repo',
      model: model,
      mode: mode,
      llmBaseUrl: '',
      llmApiKey: '',
      sessionTag: 'tag-1',
      initialMessage: message,
      effort: effort,
    );

const _pixel = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC';

/// Plays [session]'s events into a list; [onEvent] may answer them.
List<HarnessEvent> _record(HarnessSession session, [void Function(HarnessEvent e)? onEvent]) {
  final out = <HarnessEvent>[];
  session.events.listen((e) {
    out.add(e);
    onEvent?.call(e);
  });
  return out;
}

bool _isState(HarnessEvent e, ExecutionStatus s) => e is StateChange && e.executionStatus == s;

Future<void> _played(ReplayChannel c) async {
  await c.finished;
  await pumpEventQueue();
  c.expectFinished();
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('claude_driver'));
  tearDown(() => tmp.deleteSync(recursive: true));

  ClaudeDriver driver(_Spawner s) => ClaudeDriver(dataDir: () async => tmp.path, spawn: s.call);

  group('command line', () {
    test('flags come in a fixed order, for a new session and a resumed one', () {
      final fresh = claudeLaunch(sessionId: 'abc', resume: false, mode: AgentMode.ask, model: 'haiku', effort: 'high');
      expect(fresh.args, [
        '-p',
        '--input-format',
        'stream-json',
        '--output-format',
        'stream-json',
        '--verbose',
        '--include-partial-messages',
        '--permission-prompt-tool',
        'stdio',
        '--permission-mode',
        'default',
        '--session-id',
        'abc',
        '--model',
        'haiku',
        '--effort',
        'high',
      ]);
      final resumed = claudeLaunch(sessionId: 'abc', resume: true, mode: AgentMode.plan, model: 'default');
      expect(resumed.args.sublist(9), ['--permission-mode', 'plan', '--resume', 'abc']);
      for (final a in [fresh.args, resumed.args]) {
        expect(a, isNot(contains('--dangerously-skip-permissions')));
        expect(a, isNot(contains('--max-turns')));
        expect(a, isNot(contains('--disallowedTools')));
      }
      expect(fresh.env, {'MCP_TOOL_TIMEOUT': '330000', 'CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT': '330000'});
    });

    test('our modes map onto Claude permission modes', () {
      expect(
        {for (final m in AgentMode.values) m: permissionModeFor(m)},
        {
          AgentMode.ask: 'default',
          AgentMode.autoEdit: 'acceptEdits',
          AgentMode.plan: 'plan',
          AgentMode.fullAuto: 'default',
        },
      );
    });

    test('models: Claude aliases pass, OpenRouter ids are translated, the default is left out', () {
      expect(claudeModelArg('sonnet'), 'sonnet');
      expect(claudeModelArg('anthropic/claude-sonnet-5.5'), 'claude-sonnet-5-5');
      expect(claudeModelArg('default'), isNull);
      expect(claudeModelArg(''), isNull);
    });

    test('a briefing adds the recipe and turns off Claude\'s own question tool; the token stays in env', () {
      const b = DriverBriefing(
        mcpUrl: 'http://127.0.0.1:7000/mcp',
        mcpToken: 'tok-secret',
        skillDir: '/s/briefing/skills',
      );
      final l = claudeLaunch(
        sessionId: 'abc',
        resume: false,
        mode: AgentMode.ask,
        briefing: claudeDelivery(b, sessionText: 'Session rules.'),
      );
      final at = l.args.indexOf('--disallowedTools');
      expect(l.args.sublist(at, at + 4), ['--disallowedTools', 'AskUserQuestion', '--plugin-dir', '/s/briefing']);
      expect(l.args, containsAll(['--mcp-config', '--append-system-prompt', 'Session rules.', '--add-dir']));
      expect(l.args.join(' '), isNot(contains('tok-secret')));
      expect(l.env[tokenEnvVar], 'tok-secret');
      expect(l.env['MCP_TOOL_TIMEOUT'], '330000');

      final bare = claudeDelivery(const DriverBriefing(mcpUrl: 'http://127.0.0.1:7000/mcp', mcpToken: 't'));
      expect(
        [
          for (final a in bare.args)
            if (a.startsWith('--')) a,
        ],
        ['--mcp-config', '--settings'],
      );
    });
  });

  group('tool calls', () {
    test('map onto the app\'s kinds with the fields the rules read', () {
      final d = ClaudeDecoder();
      final bash = d.action('1', 'Bash', {'command': 'ls', 'description': 'list'});
      final edit = d.action('2', 'Edit', {'file_path': '/r/a.dart', 'old_string': 'a', 'new_string': 'b'});
      final write = d.action('3', 'Write', {'file_path': '/r/b.txt', 'content': 'hi'});
      final read = d.action('4', 'Read', {'file_path': '/r/a.dart'});
      final nb = d.action('5', 'NotebookEdit', {'notebook_path': '/r/n.ipynb', 'new_source': 'x'});
      final mcp = d.action('6', 'mcp__github__create_issue', {'title': 't'});
      final other = d.action('7', 'ExitPlanMode', {'plan': 'p'});
      final todo = d.action('8', 'TodoWrite', {
        'todos': [
          {'content': 'Fix it', 'status': 'completed', 'activeForm': 'Fixing it'},
        ],
      });
      expect(
        [
          for (final c in [bash, edit, write, read, nb, mcp, other, todo]) c.actionKind,
        ],
        [
          'TerminalAction',
          'FileEditorAction',
          'FileEditorAction',
          'ReadFileAction',
          'FileEditorAction',
          'MCPToolAction',
          'ClaudeToolAction',
          'TaskTrackerAction',
        ],
      );
      expect(bash.str('command'), 'ls');
      expect(
        (edit.str('command'), edit.str('path'), edit.str('old_str'), edit.str('new_str')),
        ('str_replace', '/r/a.dart', 'a', 'b'),
      );
      expect(edit.action.containsKey('file_path'), isFalse);
      expect((write.str('command'), write.str('path'), write.str('file_text')), ('create', '/r/b.txt', 'hi'));
      expect(read.str('path'), '/r/a.dart');
      expect(nb.str('path'), '/r/n.ipynb');
      expect(mcp.toolName, 'mcp__github__create_issue');
      expect(other.str('plan'), 'p');
      expect(todo.action['task_list'], [
        {'title': 'Fix it', 'status': 'done'},
      ]);
      for (final c in [bash, edit, write, read, nb, mcp, todo]) {
        expect(autoDecidable(c), isTrue, reason: c.toolName);
      }
      expect(autoDecidable(other), isFalse);
      expect(answeredBySession('mcp__everyai__ask_user_question'), isTrue);
      expect(answeredBySession('Skill'), isTrue);
      expect(answeredBySession('Bash'), isFalse);
      expect(answeredBySession('mcp__github__create_issue'), isFalse);
    });
  });

  group('sessions', () {
    test('a turn with a picture: hook registered first, image sent, usage on the plan, then finished', () async {
      final channel = ReplayChannel(_fixture('init_image_turn.jsonl'));
      final s = _Spawner([channel]);
      final session = await driver(s).start(_spec());
      final events = _record(session);
      await session.setMode(AgentMode.ask);
      await session.switchLlm(_spec(model: 'haiku'));
      await session.send('What colour is this pixel? Reply in one word.', images: ['data:image/png;base64,$_pixel']);
      await _played(channel);

      expect(channel.sent.first['request'], {'subtype': 'initialize', 'hooks': gateHooks});
      expect(s.calls.single.args, containsAllInOrder(['--session-id', session.id, '--model', 'haiku']));
      expect(s.calls.single.cwd, '/work/repo');
      final shown = [
        for (final e in events)
          if (e is! StreamDelta) e,
      ];
      expect(shown.first, isA<ChatMessage>().having((m) => m.fromUser, 'fromUser', isTrue));
      expect(_isState(shown[1], ExecutionStatus.running), isTrue);
      expect(events.whereType<StreamDelta>().map((d) => d.content).join(), 'Red.');
      final agent = shown.whereType<ChatMessage>().where((m) => !m.fromUser).single;
      expect(agent.text, 'Red.');
      final usage = shown.whereType<UsageReport>().single;
      expect(
        (usage.input, usage.cached, usage.output, usage.costMicros, usage.contextTokens, usage.onPlan),
        (23127, 12932, 120, 2228, 23127, true),
      );
      expect(_isState(shown.last, ExecutionStatus.finished), isTrue);
      await session.close();
    });

    test('with an API key the turn is spending, not the plan', () async {
      final channel = ReplayChannel(
        _fixture('init_image_turn.jsonl').replaceAll('"apiKeySource":"none"', '"apiKeySource":"ANTHROPIC_API_KEY"'),
      );
      final session = await driver(_Spawner([channel])).start(_spec());
      final events = _record(session);
      await session.setMode(AgentMode.ask);
      await session.switchLlm(_spec());
      await session.send('What colour is this pixel? Reply in one word.', images: ['data:image/png;base64,$_pixel']);
      await _played(channel);
      expect(events.whereType<UsageReport>().single.onPlan, isFalse);
      await session.close();
    });

    test('a call waits at our hook until it is answered, then runs', () async {
      final channel = ReplayChannel(_fixture('hook_allow.jsonl'));
      final session = await driver(_Spawner([channel]))
          .start(_spec(message: 'Run the shell command `touch a.txt` with the Bash tool, then reply DONE.'));
      final events = _record(session, (e) {
        if (_isState(e, ExecutionStatus.waitingForConfirmation)) {
          unawaited(session.respond(accept: true, callIds: ['toolu_0529b669']));
        }
      });
      await _played(channel);

      final call = events.whereType<ActionCall>().single;
      expect(
        (call.id, call.actionKind, call.str('command'), call.toolName),
        ('toolu_0529b669', 'TerminalAction', 'touch a.txt', 'Bash'),
      );
      final states = [
        for (final e in events)
          if (e is StateChange) e.executionStatus,
      ];
      expect(states, [
        ExecutionStatus.running,
        ExecutionStatus.waitingForConfirmation,
        ExecutionStatus.running,
        ExecutionStatus.finished,
      ]);
      final result = events.whereType<ToolResult>().single;
      expect((result.actionId, result.outcome), ('toolu_0529b669', ToolOutcome.ok));
      expect(events.indexOf(result), greaterThan(events.indexOf(call)));
      expect(channel.sent[2]['response'], {
        'subtype': 'success',
        'request_id': '00000000-0000-4000-8000-000000000003',
        'response': {
          'hookSpecificOutput': {
            'hookEventName': 'PreToolUse',
            'permissionDecision': 'allow',
            'permissionDecisionReason': 'Allowed in EveryAI.',
          },
        },
      });
      await session.close();
    });

    test('a refused permission prompt goes back to the model, which carries on', () async {
      final channel = ReplayChannel(_fixture('deny_write.jsonl'));
      final session = await driver(_Spawner([channel])).start(
        _spec(
          message: 'Now create a file named note.txt containing the word hi using the Write tool, then reply DONE.',
        ),
      );
      final events = _record(session, (e) {
        if (_isState(e, ExecutionStatus.waitingForConfirmation)) {
          unawaited(session.respond(accept: false, reason: 'The user said no.', callIds: ['toolu_00224ce4']));
        }
      });
      await _played(channel);

      final call = events.whereType<ActionCall>().single;
      expect((call.actionKind, call.str('path')), ('FileEditorAction', '/work/repo/note.txt'));
      final result = events.whereType<ToolResult>().single;
      expect(
        (result.actionId, result.outcome, result.observation['reason']),
        ('toolu_00224ce4', ToolOutcome.rejected, 'The user said no.'),
      );
      final states = [
        for (final e in events)
          if (e is StateChange) e.executionStatus,
      ];
      expect(states, isNot(contains(ExecutionStatus.paused)));
      expect(states.last, ExecutionStatus.finished);
      expect(events.whereType<ChatMessage>().last.text, startsWith("I didn't create `note.txt`."));
      await session.close();
    });

    test('Stop interrupts the turn over the control channel; the aborted turn pauses and reports nothing', () async {
      final channel = ReplayChannel(_fixture('interrupt.jsonl'));
      final session = await driver(_Spawner([channel]))
          .start(_spec(message: 'Write the numbers 1 to 300 separated by spaces, no tools.'));
      final streaming = Completer<void>();
      final events = _record(session, (e) {
        if (e is StreamDelta && !streaming.isCompleted) streaming.complete();
      });
      await streaming.future;
      await session.interrupt();
      await _played(channel);

      expect(channel.sent[2], {
        'type': 'control_request',
        'request_id': 'req_2',
        'request': {'subtype': 'interrupt'},
      });
      expect(events.whereType<UsageReport>(), isEmpty);
      expect(_isState(events.last, ExecutionStatus.paused), isTrue);
      await session.close();
    });

    test('an answer given before its hook arrives is used when it does, without asking again', () async {
      final channel = ReplayChannel('''
{"dir":"out","msg":{"type":"control_request","request_id":"req_1","request":{"subtype":"initialize","hooks":{"PreToolUse":[{"matcher":null,"hookCallbackIds":["everyai_gate"],"timeout":86400,"onFailure":"block"}]}}}}
{"dir":"in","msg":{"type":"control_response","response":{"subtype":"success","request_id":"req_1","response":{}}}}
{"dir":"out","msg":{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Two at once."}]},"parent_tool_use_id":null,"session_id":""}}
{"dir":"in","msg":{"type":"system","subtype":"init","apiKeySource":"none","session_id":"s"}}
{"dir":"in","msg":{"type":"assistant","message":{"id":"m","role":"assistant","content":[{"type":"tool_use","id":"toolu_a","name":"Bash","input":{"command":"echo a"}}]},"uuid":"u1"}}
{"dir":"in","msg":{"type":"assistant","message":{"id":"m","role":"assistant","content":[{"type":"tool_use","id":"toolu_b","name":"Bash","input":{"command":"echo b"}}]},"uuid":"u2"}}
{"dir":"in","msg":{"type":"control_request","request_id":"h1","request":{"subtype":"hook_callback","callback_id":"everyai_gate","input":{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo a"},"tool_use_id":"toolu_a"}}}}
{"dir":"out","msg":{"type":"control_response","response":{"subtype":"success","request_id":"h1","response":{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"Allowed in EveryAI."}}}}}
{"dir":"in","msg":{"type":"control_request","request_id":"h2","request":{"subtype":"hook_callback","callback_id":"everyai_gate","input":{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo b"},"tool_use_id":"toolu_b"}}}}
{"dir":"out","msg":{"type":"control_response","response":{"subtype":"success","request_id":"h2","response":{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Not b."}}}}}
{"dir":"in","msg":{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_a","type":"tool_result","content":"a","is_error":false},{"tool_use_id":"toolu_b","type":"tool_result","content":"Not b.","is_error":true}]},"uuid":"u3"}}
{"dir":"in","msg":{"type":"result","subtype":"success","is_error":false,"usage":{"input_tokens":0,"output_tokens":0},"uuid":"u4"}}
{"dir":"eof"}
''');
      final session = await driver(_Spawner([channel])).start(_spec(message: 'Two at once.'));
      final events = _record(session, (e) {
        if (_isState(e, ExecutionStatus.waitingForConfirmation)) {
          unawaited(session.respond(accept: true, callIds: ['toolu_a']));
          unawaited(session.respond(accept: false, reason: 'Not b.', callIds: ['toolu_b']));
        }
      });
      await _played(channel);
      expect(events.where((e) => _isState(e, ExecutionStatus.waitingForConfirmation)), hasLength(1));
      expect([for (final r in events.whereType<ToolResult>()) r.outcome], [ToolOutcome.ok, ToolOutcome.rejected]);
      await session.close();
    });

    test('a reopened session replays its journal, starts nothing, and resumes on the next message', () async {
      final first = ReplayChannel(_fixture('hook_allow.jsonl'));
      final one = await driver(_Spawner([first]))
          .start(_spec(message: 'Run the shell command `touch a.txt` with the Bash tool, then reply DONE.'));
      final before = _record(one, (e) {
        if (_isState(e, ExecutionStatus.waitingForConfirmation)) unawaited(one.respond(accept: true));
      });
      await _played(first);
      await one.close();

      final resumed = ReplayChannel(_fixture('resume_echo.jsonl'));
      final s = _Spawner([resumed]);
      final again = driver(s);
      final two = await again.attach(one.id);
      final after = _record(two);
      await pumpEventQueue();
      expect(s.calls, isEmpty);
      final ids = [
        for (final e in before)
          if (e is! StreamDelta) e.id,
      ];
      expect([for (final e in after) e.id].take(ids.length), ids);
      expect(_isState(after.last, ExecutionStatus.idle), isTrue);
      expect(await again.statuses([one.id, 'other']), {one.id: ExecutionStatus.idle});

      await two.send('Run the shell command `echo hi` with the Bash tool, then reply DONE.');
      await _played(resumed);
      expect(s.calls.single.args, containsAllInOrder(['--resume', one.id]));
      expect(s.calls.single.args, isNot(contains('--session-id')));
      expect(s.calls.single.cwd, '/work/repo');
      expect(after.whereType<ToolResult>().last.text, 'hi');
      expect(_isState(after.last, ExecutionStatus.finished), isTrue);
      await expectLater(two.rewindTo(null), throwsA(isA<HarnessError>()));
      await two.close();
    });

    test('a session without a record says so', () async {
      await expectLater(
        driver(_Spawner([])).attach('gone'),
        throwsA(isA<HarnessError>().having((e) => e.message, 'message', contains('record is gone'))),
      );
    });
  });

  group('driver', () {
    test('caps', () {
      expect(ClaudeDriver().caps, {
        DriverCap.resume,
        DriverCap.approvals,
        DriverCap.perCallApprovals,
        DriverCap.usage,
        DriverCap.mcp,
        DriverCap.skills,
        DriverCap.images,
        DriverCap.switchModel,
        DriverCap.effort,
        DriverCap.subagents,
      });
      expect((ClaudeDriver().info.id, ClaudeDriver().info.needsConsent), ('claude-code', true));
    });

    test('detect reads only whether the CLI is signed in', () async {
      Future<DriverStatus> withAuth(String? out) => ClaudeDriver(
        which: (_) async => '/bin/echo',
        run: (exe, args) async {
          expect(exe, '/bin/echo');
          expect(args, ['auth', 'status', '--json']);
          return out;
        },
      ).detect();
      final yes = await withAuth('{"loggedIn":true,"authMethod":"claude.ai","email":"x@y.z"}');
      expect((yes.installed, yes.path, yes.signedIn, yes.problem), (true, '/bin/echo', true, null));
      final no = await withAuth('{"loggedIn":false}');
      expect(no.signedIn, isFalse);
      expect(no.problem, contains('claude auth login'));
      final unsure = await withAuth('Error: unknown command');
      expect((unsure.installed, unsure.signedIn, unsure.problem), (true, null, null));
      final missing = await ClaudeDriver(which: (_) async => null).detect();
      expect(missing.installed, isFalse);
    });

    test('models come from initialize once, with their efforts; aliases when that fails', () async {
      final channel = ReplayChannel('''
{"dir":"out","msg":{"type":"control_request","request_id":"req_1","request":{"subtype":"initialize"}}}
{"dir":"in","msg":{"type":"control_response","response":{"subtype":"success","request_id":"req_1","response":{"models":[{"value":"default","displayName":"Default (recommended)","supportedEffortLevels":["low","high"]},{"value":"haiku","displayName":"Haiku 5.5"}]}}}}
''');
      final s = _Spawner([channel]);
      final d = driver(s);
      final models = await d.models();
      expect(
        [for (final m in models) (m.id, m.label, m.isDefault)],
        [('default', 'Default (recommended)', true), ('haiku', 'Haiku 5.5', false)],
      );
      expect(
        [for (final m in models) m.efforts],
        [
          ['low', 'high'],
          <String>[],
        ],
      );
      expect(s.calls.single.args, claudeProbeArgs);
      expect(await d.models(), same(models));
      expect(s.calls, hasLength(1));
      expect([for (final m in await driver(_Spawner([])).models()) m.id], ['default', 'opus', 'sonnet', 'haiku']);
    });
  });

  test('user lines carry the text and each picture as a base64 block', () {
    final line = userLine('Look', images: ['data:image/png;base64,$_pixel', 'not a data url']);
    expect(jsonDecode(jsonEncode(line)), {
      'type': 'user',
      'message': {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': 'Look'},
          {
            'type': 'image',
            'source': {'type': 'base64', 'media_type': 'image/png', 'data': _pixel},
          },
        ],
      },
      'parent_tool_use_id': null,
      'session_id': '',
    });
  });
}
