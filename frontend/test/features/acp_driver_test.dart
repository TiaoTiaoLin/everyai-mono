import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/permissions.dart';
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/drivers/acp/acp_agents.dart';
import 'package:every_ai/features/code/drivers/acp/acp_driver.dart';
import 'package:every_ai/features/code/drivers/acp/acp_files.dart';
import 'package:every_ai/features/code/drivers/briefing/briefing_types.dart';
import 'package:every_ai/features/code/drivers/driver_policy.dart';
import 'package:every_ai/features/code/drivers/usage_limit.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:every_ai/features/code/host/host.dart';
import 'package:every_ai/features/questions/domain/questions.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/replay_transport.dart';

const _fixtures = 'test/fixtures/drivers';

typedef _Spawn = ({String executable, List<String> args, String cwd, String logPath, Map<String, String> env});

/// Drivers on recorded (or derived) agents: each start of the agent plays
/// the next script.
final class _Rig {
  _Rig(this.root, this.scripts);

  final String root;
  final List<String> scripts;
  final spawns = <_Spawn>[];
  final channels = <ReplayChannel>[];

  String get dataDir => '$root/data';
  String get work => '$root/work';

  AcpDriver driver(
    String id,
    String command, {
    List<String> args = const [],
    Duration? initTimeout,
    Future<String?> Function(String command)? which,
  }) => AcpDriver(
    id: id,
    label: switch (command) {
      'gemini' => 'Gemini CLI',
      'opencode' => 'OpenCode',
      'cursor-agent' => 'Cursor CLI',
      _ => command,
    },
    command: command,
    args: args,
    which: which ?? (c) async => '/usr/local/bin/$c',
    dataDir: () async => dataDir,
    initTimeout: initTimeout ?? const Duration(seconds: 60),
    replayQuiet: Duration.zero,
    connect:
        ({
          required String executable,
          required List<String> args,
          required String cwd,
          required String sessionTag,
          required String logPath,
          required Map<String, String> env,
        }) async {
          spawns.add((executable: executable, args: args, cwd: cwd, logPath: logPath, env: env));
          final c = ReplayChannel.file('$_fixtures/${scripts.removeAt(0)}');
          channels.add(c);
          return c;
        },
  );

  SessionSpec spec({
    AgentMode mode = AgentMode.ask,
    String model = 'm',
    String? effort,
    DriverBriefing? briefing,
    String? initial,
  }) => SessionSpec(
    workingDir: work,
    model: model,
    effort: effort,
    mode: mode,
    llmBaseUrl: 'http://127.0.0.1:9/v1',
    llmApiKey: 'sk-test',
    sessionTag: 's1',
    briefing: briefing,
    initialMessage: initial,
  );

  void expectPlayed() {
    for (final c in channels) {
      c.expectFinished();
    }
  }
}

/// Collects a session's events.
final class _Seen {
  _Seen(HarnessSession s) {
    s.events.listen(all.add);
  }

  final all = <HarnessEvent>[];

  List<ExecutionStatus> get statuses => [for (final e in all.whereType<StateChange>()) e.executionStatus];
  ExecutionStatus? get status => statuses.lastOrNull;
  List<ActionCall> get calls => all.whereType<ActionCall>().toList();
  List<ToolResult> get results => all.whereType<ToolResult>().toList();
  List<String> get notices => [for (final e in all.whereType<ConversationFailure>()) e.message];
  List<ChatMessage> get messages => all.whereType<ChatMessage>().toList();

  Future<void> until(bool Function() cond) async {
    for (var i = 0; i < 100 && !cond(); i++) {
      await pumpEventQueue();
    }
    expect(cond(), isTrue, reason: 'events: ${all.map((e) => e.raw['kind'] ?? e.runtimeType).toList()}');
  }

  Future<void> untilStatus(ExecutionStatus s) => until(() => status == s);
}

/// The text of each prompt sent on [c].
List<String> _prompts(ReplayChannel c) => [
  for (final m in c.sent)
    if (m['method'] == 'session/prompt') (((m['params']! as Map)['prompt']! as List).first as Map)['text']! as String,
];

/// A stored conversation `conv` for [r], as the driver leaves one.
Directory _stored(
  _Rig r,
  String conv,
  String acpSessionId, {
  List<String> mcp = const [],
  List<Map<String, Object?>> events = const [],
}) {
  final dir = Directory('${r.dataDir}/acp-sessions/$conv')..createSync(recursive: true);
  File('${dir.path}/meta.json').writeAsStringSync(
    jsonEncode({'acpSessionId': acpSessionId, 'cwd': r.work, 'sessionTag': 's1', 'mode': 'ask', 'mcpServers': mcp}),
  );
  if (events.isNotEmpty) File('${dir.path}/events.jsonl').writeAsStringSync('${events.map(jsonEncode).join('\n')}\n');
  return dir;
}

/// The app's side of the MCP host for a session: records each call and
/// answers it when the test says.
final class _Host implements HostTools {
  final calls = <HostCall>[];
  final _replies = <Completer<HostResult>>[];

  @override
  Future<HostResult> call(HostCall call) {
    calls.add(call);
    final c = Completer<HostResult>();
    _replies.add(c);
    return c.future;
  }

  void answer(String text, {bool isError = false}) => _replies.removeAt(0).complete((text: text, isError: isError));
}

DriverBriefing _cursorBrief(HostTools host) =>
    DriverBriefing(mcpUrl: 'http://127.0.0.1:7777/mcp', mcpToken: 'tok-cursor', host: host);

/// Our reply to the agent's request [id] on [c].
Object? _replyTo(ReplayChannel c, String id) =>
    c.sent.singleWhere((m) => m['id'] == id && m['method'] == null)['result'];

/// The question card arguments of `cursor/ask.jsonl`'s request.
Map<String, Object?> _askArgs() => {
  'questions': [
    {
      'question': 'Which database?',
      'options': [
        {'label': 'Postgres'},
        {'label': 'SQLite'},
      ],
    },
    {
      'question': 'Which extras?',
      'multi_select': true,
      'options': [
        {'label': 'Auth'},
        {'label': 'Billing'},
        {'label': 'Search'},
      ],
    },
  ],
};

Transcript _transcript(List<HarnessEvent> events) {
  final b = TranscriptBuilder();
  events.forEach(b.add);
  return b.snapshot;
}

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('acp-driver');
    Directory('${tmp.path}/work').createSync();
  });
  tearDown(() => tmp.delete(recursive: true));

  _Rig rig(List<String> scripts) => _Rig(tmp.path, scripts);

  group('OpenCode (recorded)', () {
    test('the handshake: our initialize and session/new, the metadata, the models, Plan pinned', () async {
      final r = rig(['opencode/handshake.jsonl']);
      final d = r.driver('acp:opencode', 'opencode');
      final s = await d.start(r.spec(mode: AgentMode.plan));
      await r.channels.single.finished;
      r.expectPlayed();
      final spawn = r.spawns.single;
      expect((spawn.executable, spawn.cwd), ('/usr/local/bin/opencode', r.work));
      expect(spawn.args, ['acp']);
      final config = jsonDecode(spawn.env['OPENCODE_CONFIG_CONTENT']!) as Map<String, Object?>;
      expect((config['permission']! as Map)['*'], 'ask');
      final meta =
          jsonDecode(File('${r.dataDir}/acp-sessions/${s.id}/meta.json').readAsStringSync()) as Map<String, Object?>;
      expect(meta, {
        'acpSessionId': 'ses_e5adb7e4effeCCHUFq6T8P7fJY',
        'cwd': r.work,
        'sessionTag': 's1',
        'mode': 'plan',
        'mcpServers': <Object?>[],
      });
      final models = await d.models();
      expect(models, hasLength(4));
      final def = models.singleWhere((m) => m.isDefault);
      expect(def.id, 'opencode/crouton-alpha-free');
      expect(def.efforts, ['minimal', 'low', 'medium', 'high', 'xhigh', 'max']);
      expect(await d.statuses([s.id, 'nope']), {s.id: ExecutionStatus.idle});
      await s.close();
    });

    test('a prompt refused for sign-in says how to sign in; the model went through set_config_option', () async {
      final r = rig(['opencode/auth_error.jsonl']);
      final d = r.driver('acp:opencode', 'opencode');
      final s = await d.start(r.spec(model: 'anthropic/claude-haiku-4-5'));
      final seen = _Seen(s);
      await s.send('Reply with just the word OK.');
      await seen.untilStatus(ExecutionStatus.error);
      expect(
        seen.notices.single,
        "OpenCode isn't signed in. Run `opencode auth login` in the terminal, then try again.",
      );
      // Already on it: nothing is sent, and set_model (-32601 on OpenCode) never.
      await s.switchLlm(r.spec(model: 'anthropic/claude-haiku-4-5'));
      await expectLater(
        s.switchLlm(r.spec(model: 'nope/model')),
        throwsA(isA<HarnessError>().having((e) => e.message, 'message', "OpenCode doesn't offer nope/model.")),
      );
      r.expectPlayed();
      expect([for (final m in r.channels.single.sent) m['method']], isNot(contains('session/set_model')));
      await s.close();
    });

    test('a reopened conversation shows its journal at once; the agent starts and loads on the next message', () async {
      final r = rig(['opencode/load.jsonl']);
      final first = r.driver('acp:opencode', 'opencode');
      final dir = Directory('${r.dataDir}/acp-sessions/conv-1')..createSync(recursive: true);
      File('${dir.path}/meta.json').writeAsStringSync(
        jsonEncode({
          'acpSessionId': 'ses_e5ad81ff1ffeGaamwMA9ctbrrE',
          'cwd': r.work,
          'sessionTag': 's1',
          'mode': 'ask',
        }),
      );
      File('${dir.path}/events.jsonl').writeAsStringSync(
        '${[
          {
            'kind': 'MessageEvent',
            'id': 'old-u1',
            'source': 'user',
            'llm_message': {'role': 'user', 'content': 'Earlier'},
          },
          {'kind': 'ConversationStateUpdateEvent', 'id': 'old-s1', 'key': 'execution_status', 'value': 'running'},
        ].map(jsonEncode).join('\n')}\n',
      );
      expect(await first.statuses(['conv-1']), {'conv-1': ExecutionStatus.idle});
      final s = await first.attach('conv-1');
      final seen = _Seen(s);
      await pumpEventQueue();
      expect(r.spawns, isEmpty);
      expect(seen.messages.single.text, 'Earlier');
      // A run cut off by the app closing ends as stopped.
      expect(seen.status, ExecutionStatus.paused);
      await s.send('Reply with just the word OK.');
      await seen.untilStatus(ExecutionStatus.error);
      r.expectPlayed();
      // The agent's replay of the old user message is dropped: only ours shows.
      expect([for (final m in seen.messages) m.text], ['Earlier', 'Reply with just the word OK.']);
      final journal = File('${dir.path}/events.jsonl').readAsLinesSync();
      expect(journal.length, greaterThan(2));
      await s.close();
    });

    test('a mode change while it is not running waits; Plan is set when the agent loads', () async {
      final r = rig(['opencode/load_then_plan.jsonl']);
      final d = r.driver('acp:opencode', 'opencode');
      final dir = Directory('${r.dataDir}/acp-sessions/conv-2')..createSync(recursive: true);
      File('${dir.path}/meta.json').writeAsStringSync(
        jsonEncode({
          'acpSessionId': 'ses_e5ad81ff1ffeGaamwMA9ctbrrE',
          'cwd': r.work,
          'sessionTag': 's1',
          'mode': 'ask',
        }),
      );
      final s = await d.attach('conv-2');
      final seen = _Seen(s);
      await s.setMode(AgentMode.plan);
      expect(r.spawns, isEmpty);
      await s.send('Plan it.');
      await seen.untilStatus(ExecutionStatus.error);
      r.expectPlayed();
      await s.close();
    });

    test('a conversation the agent no longer has starts fresh, with a notice', () async {
      final r = rig(['opencode/load_missing.jsonl']);
      final d = r.driver('acp:opencode', 'opencode');
      final dir = Directory('${r.dataDir}/acp-sessions/conv-3')..createSync(recursive: true);
      File('${dir.path}/meta.json')
          .writeAsStringSync(jsonEncode({'acpSessionId': 'ses_nonexistent', 'cwd': r.work, 'sessionTag': 's1'}));
      final s = await d.attach('conv-3');
      final seen = _Seen(s);
      await s.send('Reply with just the word OK.');
      await seen.untilStatus(ExecutionStatus.error);
      r.expectPlayed();
      expect(
        seen.notices.first,
        "OpenCode couldn't reopen its conversation, so it starts fresh. The history above is for you only.",
      );
      final meta = jsonDecode(File('${dir.path}/meta.json').readAsStringSync()) as Map<String, Object?>;
      expect(meta['acpSessionId'], 'ses_e5adb7e4effeCCHUFq6T8P7fJY');
      await s.close();
    });

    test('a conversation without files is refused plainly; rewinding is refused', () async {
      final r = rig(['opencode/handshake.jsonl']);
      final d = r.driver('acp:opencode', 'opencode');
      await expectLater(d.attach('gone'), throwsA(isA<HarnessError>()));
      final s = await d.start(r.spec(mode: AgentMode.plan));
      await expectLater(
        s.rewindTo(null),
        throwsA(isA<HarnessError>().having((e) => e.message, 'message', contains("OpenCode can't go back"))),
      );
      await s.close();
    });
  });

  group('review fixes', () {
    test("OpenCode's rules are pinned per agent too, and the project's own config is off", () async {
      final r = rig(['opencode/handshake.jsonl']);
      final s = await r.driver('acp:opencode', 'opencode').start(r.spec(mode: AgentMode.plan));
      final env = r.spawns.single.env;
      expect(env['OPENCODE_DISABLE_PROJECT_CONFIG'], '1');
      final config = jsonDecode(env['OPENCODE_CONFIG_CONTENT']!) as Map<String, Object?>;
      final agents = config['agent']! as Map<String, Object?>;
      expect(agents.keys, containsAll(['build', 'plan', 'general', 'explore']));
      for (final a in agents.values) {
        expect(((a! as Map)['permission']! as Map)['*'], 'ask');
      }
      await s.close();
    });

    test("Gemini doesn't start in a project whose .gemini settings allow tools ahead of time", () async {
      final r = rig(const []);
      Directory('${r.work}/.gemini').createSync();
      File('${r.work}/.gemini/settings.json').writeAsStringSync('{"ui":{"theme":"x"}}');
      expect(await geminiWorkspaceProblem(r.work), isNull);
      File('${r.work}/.gemini/settings.json')
          .writeAsStringSync('{"ui":{},"tools":{"allowed":["run_shell_command"]},"mcpServers":{"x":{"command":"sh"}}}');
      await expectLater(
        r.driver('gemini', 'gemini').start(r.spec()),
        throwsA(
          isA<HarnessError>().having(
            (e) => e.message,
            'message',
            contains('settings.json "tools", settings.json "mcpServers"'),
          ),
        ),
      );
      expect(r.spawns, isEmpty);
    });

    test('a Gemini conversation it no longer has (-32603) starts fresh, with a notice', () async {
      final r = rig(['gemini/load_unknown.jsonl']);
      _stored(r, 'g1', 'gemini-old');
      final s = await r.driver('gemini', 'gemini').attach('g1');
      final seen = _Seen(s);
      await s.send('Hello');
      await seen.untilStatus(ExecutionStatus.finished);
      r.expectPlayed();
      expect(seen.notices.single, contains("couldn't reopen its conversation"));
    });

    test("Gemini's replay after its load reply stays out of the new turn", () async {
      final r = rig(['gemini/load_late_replay.jsonl']);
      _stored(
        r,
        'g2',
        'gemini-old',
        events: [
          {
            'kind': 'MessageEvent',
            'id': 'old-u1',
            'source': 'user',
            'llm_message': {'role': 'user', 'content': 'Earlier'},
          },
        ],
      );
      final s = await r.driver('gemini', 'gemini').attach('g2');
      final seen = _Seen(s);
      await s.send('Next');
      await seen.untilStatus(ExecutionStatus.finished);
      r.expectPlayed();
      expect([for (final m in seen.messages) m.text], ['Earlier', 'Next', 'New reply.']);
      expect(seen.calls, isEmpty);
    });

    test('a reopened OpenCode session counts only what it spent since, and says which MCP servers it lost', () async {
      final r = rig(['opencode/usage_reopen.jsonl']);
      _stored(
        r,
        'o1',
        'ses_e5ad81ff1ffeGaamwMA9ctbrrE',
        mcp: ['github'],
        events: [
          UsageReport.of(id: 'old-usage', input: 0, output: 0, costMicros: 400000, onPlan: true).raw
            ..['acp_total'] = 0.40,
        ],
      );
      final s = await r.driver('acp:opencode', 'opencode').attach('o1');
      final seen = _Seen(s);
      await s.send('Hi');
      await seen.untilStatus(ExecutionStatus.finished);
      r.expectPlayed();
      final fresh = seen.all.whereType<UsageReport>().where((u) => u.id != 'old-usage').single;
      expect(fresh.costMicros, 30000);
      expect(seen.notices.single, contains('without your MCP servers github'));
      final meta = jsonDecode(File('${r.dataDir}/acp-sessions/o1/meta.json').readAsStringSync()) as Map;
      expect(meta['mcpServers'], ['github']);
    });

    test('attachBriefed: the reopened agent starts with the new token, not the old one, and none is stored', () async {
      final r = rig(['opencode/usage_reopen.jsonl']);
      _stored(r, 'o1', 'ses_e5ad81ff1ffeGaamwMA9ctbrrE', mcp: ['github']);
      final d = r.driver('acp:opencode', 'opencode');
      expect(d, isA<AttachesBriefed>());
      final s = await (d as AttachesBriefed).attachBriefed(
        'o1',
        DriverBriefing(
          mcpUrl: 'http://127.0.0.1:7001/mcp',
          mcpToken: 'tok-new',
          skillDir: '${tmp.path}/b/briefing/skills',
          sessionSkill: 'Session text.',
        ),
      );
      final seen = _Seen(s);
      await s.send('Hi');
      await seen.untilStatus(ExecutionStatus.finished);
      r.expectPlayed();
      final env = r.spawns.single.env;
      expect(env[tokenEnvVar], 'tok-new');
      expect(env['OPENCODE_CONFIG_CONTENT'], contains('127.0.0.1:7001'));
      expect(r.spawns.single.args.join(' '), isNot(contains('tok-new')));
      await s.close();
      for (final f in Directory(r.dataDir).listSync(recursive: true).whereType<File>()) {
        expect(f.readAsStringSync(), isNot(contains('tok-new')), reason: f.path);
      }
    });

    test('a reopen with an empty server list says nothing about lost servers and forgets them', () async {
      final r = rig(['opencode/usage_reopen.jsonl']);
      _stored(r, 'o1', 'ses_e5ad81ff1ffeGaamwMA9ctbrrE', mcp: ['charts']);
      // A child session reopens without a briefing, with the app's current (now empty) list.
      final s = await r.driver('acp:opencode', 'opencode').attachWithMcp('o1', const <String, Object?>{});
      final seen = _Seen(s);
      await s.send('Hi');
      await seen.untilStatus(ExecutionStatus.finished);
      r.expectPlayed();
      expect(seen.notices.where((n) => n.contains('without your MCP servers')), isEmpty);
      await s.close();
      final meta = jsonDecode(File('${r.dataDir}/acp-sessions/o1/meta.json').readAsStringSync()) as Map;
      expect(meta['mcpServers'], isEmpty);
    });

    test('attachBriefed with the user\'s MCP servers sends them in session/load; no secret is stored', () async {
      final r = rig(['opencode/reopen_mcp.jsonl']);
      _stored(r, 'o1', 'ses_e5ad81ff1ffeGaamwMA9ctbrrE', mcp: ['charts']);
      final s = await (r.driver('acp:opencode', 'opencode') as AttachesBriefed).attachBriefed(
        'o1',
        DriverBriefing(mcpUrl: 'http://127.0.0.1:7001/mcp', mcpToken: 'tok-new'),
        mcpConfig: {
          'charts': {
            'command': 'npx',
            'args': ['-y', 'chart-mcp'],
            'env': {'KEY': 'secret-env'},
          },
        },
      );
      final seen = _Seen(s);
      await s.send('Hi');
      await seen.untilStatus(ExecutionStatus.finished);
      r.expectPlayed();
      expect(seen.notices.where((n) => n.contains('without your MCP servers')), isEmpty);
      await s.close();
      final meta = jsonDecode(File('${r.dataDir}/acp-sessions/o1/meta.json').readAsStringSync()) as Map;
      expect(meta['mcpServers'], ['charts']);
      for (final f in Directory(r.dataDir).listSync(recursive: true).whereType<File>()) {
        expect(f.readAsStringSync(), isNot(contains('secret-env')), reason: f.path);
        expect(f.readAsStringSync(), isNot(contains('tok-new')), reason: f.path);
      }
    });

    test('a command that ran without asking is shown with a notice; in Plan it stops the turn', () async {
      final r = rig(['opencode/unasked_plan.jsonl']);
      final s = await r.driver('acp:opencode', 'opencode').start(r.spec(mode: AgentMode.plan));
      final seen = _Seen(s);
      await s.send('Plan it.');
      await seen.untilStatus(ExecutionStatus.paused);
      r.expectPlayed();
      expect(
        seen.notices.single,
        'OpenCode ran "rm -rf build" without asking the app first, so its own settings allow it. '
        'Plan mode stopped the turn.',
      );
      expect(seen.results.single.text, isNot('Cancelled.'));
      await s.close();
    });

    test('a refusal without typed words adds nothing to the next prompt', () async {
      final r = rig(['gemini/deny_one_plain.jsonl']);
      final s = await r.driver('gemini', 'gemini').start(r.spec());
      final seen = _Seen(s);
      await s.send('Clean up.');
      await seen.untilStatus(ExecutionStatus.waitingForConfirmation);
      await s.respond(accept: false, reason: denialMessage(DenialKind.denied), callIds: [seen.calls.single.id]);
      await seen.untilStatus(ExecutionStatus.finished);
      await s.send('What next?');
      await r.channels.single.finished;
      await seen.until(() => seen.statuses.where((x) => x == ExecutionStatus.finished).length == 2);
      r.expectPlayed();
      await s.close();
    });

    test('two writers of one JSON file both land', () async {
      final path = '${tmp.path}/data/models.json';
      await Future.wait([
        writeJsonFile(path, {'a': 1}),
        writeJsonFile(path, {'a': 2}),
      ]);
      expect((await readJsonFile(path))?['a'], anyOf(1, 2));
    });
  });

  group('Gemini CLI (derived from its source)', () {
    test('a turn: its asking mode pinned, a shell call to approve once, its output, the reply', () async {
      final r = rig(['gemini/turn.jsonl']);
      final d = r.driver('gemini', 'gemini', args: const ['--acp']);
      final s = await d.start(r.spec(model: 'gemini-2.5-flash'));
      final seen = _Seen(s);
      expect(r.spawns.single.args, ['--acp', '--approval-mode', 'default']);
      expect([for (final m in await d.models()) m.id], ['auto-gemini-2.5', 'gemini-2.5-pro', 'gemini-2.5-flash']);
      await s.send('List the files.');
      await seen.untilStatus(ExecutionStatus.waitingForConfirmation);
      final call = seen.calls.single;
      expect((call.actionKind, call.summary), ('AcpExecuteAction', 'ls -la [current working directory] (List files)'));
      expect(autoDecidable(call), isFalse);
      // The reply streamed so far was flushed before the call.
      final before = seen.messages.last;
      expect((before.text, before.reasoning), ("I'll list them.", 'Looking around.'));
      await s.respond(accept: true, callIds: [call.id]);
      await seen.untilStatus(ExecutionStatus.finished);
      r.expectPlayed();
      final answer = r.channels.single.sent.firstWhere((m) => m['id'] == 0);
      expect(answer['result'], {
        'outcome': {'outcome': 'selected', 'optionId': 'proceed_once'},
      });
      expect((seen.results.single.actionId, seen.results.single.text), (call.id, 'a.txt\nb.txt'));
      expect(seen.messages.last.text, 'Two files. Done.');
      expect(seen.all.whereType<StreamDelta>().length, 4);
      await s.close();
    });

    test('one call refused with a reason: the run goes on, and the reason opens the next prompt', () async {
      final r = rig(['gemini/deny_one.jsonl']);
      final s = await r.driver('gemini', 'gemini').start(r.spec());
      final seen = _Seen(s);
      await s.send('Clean up.');
      await seen.untilStatus(ExecutionStatus.waitingForConfirmation);
      await s.respond(
        accept: false,
        reason: denialMessage(DenialKind.denied, reason: 'Not now.'),
        callIds: [seen.calls.single.id],
      );
      await seen.untilStatus(ExecutionStatus.finished);
      expect(seen.statuses, contains(ExecutionStatus.running));
      expect((seen.results.single.outcome, seen.results.length), (ToolOutcome.rejected, 1));
      await s.resume();
      await s.send('What next?');
      await r.channels.single.finished;
      await seen.until(() => seen.statuses.where((x) => x == ExecutionStatus.finished).length == 2);
      r.expectPlayed();
      await s.close();
    });

    test('refusing every call at once cancels the turn; resume passes the reason on', () async {
      final r = rig(['gemini/deny_all.jsonl']);
      final s = await r.driver('gemini', 'gemini').start(r.spec());
      final seen = _Seen(s);
      await s.send('Clean up.');
      await seen.untilStatus(ExecutionStatus.waitingForConfirmation);
      await s.respond(accept: false, reason: denialMessage(DenialKind.denied, reason: 'Stop that.'));
      await seen.untilStatus(ExecutionStatus.paused);
      await s.resume();
      await seen.untilStatus(ExecutionStatus.finished);
      r.expectPlayed();
      expect(
        _prompts(r.channels.single).last,
        'The app refused "rm -rf build [current working directory] (Clean up)": Stop that.',
      );
      await s.close();
    });

    test('interrupt answers what waits as cancelled and closes the open calls', () async {
      final r = rig(['gemini/interrupt.jsonl']);
      final s = await r.driver('gemini', 'gemini').start(r.spec());
      final seen = _Seen(s);
      await s.send('Look and clean.');
      await seen.untilStatus(ExecutionStatus.waitingForConfirmation);
      expect(seen.calls.map((c) => c.actionKind), ['ReadFileAction', 'AcpExecuteAction']);
      await s.interrupt();
      await seen.untilStatus(ExecutionStatus.paused);
      r.expectPlayed();
      expect(
        [for (final x in seen.results) (x.actionId, x.text)],
        [('tc-run_shell_command-3', 'Cancelled.'), ('tc-read_file-1', 'Cancelled.')],
      );
      await s.close();
    });

    test('a spent quota ends the turn as a usage limit', () async {
      final r = rig(['gemini/quota.jsonl']);
      final s = await r.driver('gemini', 'gemini').start(r.spec());
      final seen = _Seen(s);
      await s.send('Go on.');
      await seen.untilStatus(ExecutionStatus.error);
      r.expectPlayed();
      final limit = seen.all.map(usageLimitOf).nonNulls.single;
      expect(limit.message, startsWith('Gemini CLI: You have exhausted your capacity'));
      expect(limit.resetsAt, isNotNull);
      await s.close();
    });

    test('a message sent during a turn goes out after it', () async {
      final r = rig(['gemini/serial.jsonl']);
      final s = await r.driver('gemini', 'gemini').start(r.spec());
      final seen = _Seen(s);
      await s.send('one');
      await seen.untilStatus(ExecutionStatus.waitingForConfirmation);
      await s.send('two');
      await pumpEventQueue();
      expect(_prompts(r.channels.single), ['one']);
      await s.respond(accept: true);
      await r.channels.single.finished;
      await seen.until(() => seen.statuses.where((x) => x == ExecutionStatus.finished).length == 2);
      r.expectPlayed();
      expect(_prompts(r.channels.single), ['one', 'two']);
      await s.close();
    });

    test('an initialize that never comes back gives a sign-in hint (recorded)', () async {
      final r = rig(['gemini/initialize_hang.jsonl']);
      final d = r.driver('gemini', 'gemini', initTimeout: Duration.zero);
      await expectLater(
        d.start(r.spec()),
        throwsA(
          isA<HarnessError>().having(
            (e) => e.message,
            'message',
            "Gemini CLI didn't start. If it asks you to sign in, run `gemini` in a terminal once, then try again.",
          ),
        ),
      );
    });

    test('the briefing: our MCP server over the pipe, the session text in the first prompt only', () async {
      final r = rig(['gemini/briefing.jsonl']);
      final skills = Directory('${tmp.path}/brief/briefing/skills/review')..createSync(recursive: true);
      File('${skills.path}/SKILL.md').writeAsStringSync('---\nname: review\ndescription: Reviews a diff\n---\nBody\n');
      final skillDir = skills.parent.path;
      const token = 'tok-secret-123';
      final s = await r
          .driver('gemini', 'gemini', args: const ['--acp'])
          .start(
            r.spec(
              briefing: DriverBriefing(
                mcpUrl: 'http://127.0.0.1:7777/mcp',
                mcpToken: token,
                skillDir: skillDir,
                sessionSkill: 'You are in an EveryAI session.',
              ),
            ),
          );
      final seen = _Seen(s);
      final args = r.spawns.single.args;
      expect(args.where((a) => a == '--acp'), hasLength(1));
      expect(args.where((a) => a == '--include-directories'), hasLength(1));
      expect(args[args.indexOf('--include-directories') + 1], skillDir);
      expect(args.join(' '), isNot(contains(token)));
      expect(r.spawns.single.env.values.join(' '), isNot(contains(token)));
      await s.send('Hello');
      await seen.untilStatus(ExecutionStatus.finished);
      await s.send('Again');
      await r.channels.single.finished;
      await seen.until(() => seen.statuses.where((x) => x == ExecutionStatus.finished).length == 2);
      r.expectPlayed();
      final first = _prompts(r.channels.single).first;
      expect(first, startsWith('<everyai-session>\nYou are in an EveryAI session.'));
      expect(first, contains('- review: Reviews a diff (`$skillDir/review/SKILL.md`)'));
      expect(first, endsWith('</everyai-session>\n\nHello'));
      expect([for (final m in seen.messages.where((m) => m.fromUser)) m.text], ['Hello', 'Again']);
      await s.close();
      for (final f in Directory(r.dataDir).listSync(recursive: true).whereType<File>()) {
        expect(f.readAsStringSync(), isNot(contains(token)), reason: f.path);
      }
    });
  });

  test('Gemini counts as signed in with an API key; a cached personal Google sign-in no longer does', () async {
    final home = tmp.path;
    expect(await geminiSignedIn(home: home, env: const {'GEMINI_API_KEY': 'k'}), isTrue);
    expect(await geminiSignedIn(home: home, env: const {}), isFalse);
    Directory('$home/.gemini').createSync();
    File('$home/.gemini/settings.json').writeAsStringSync('{"security":{"auth":{"selectedType":"oauth-personal"}}}');
    expect(await geminiSignedIn(home: home, env: const {}), isFalse);
    File('$home/.gemini/oauth_creds.json').writeAsStringSync('{}');
    expect(await geminiSignedIn(home: home, env: const {}), isFalse);
    // With a Cloud project it may be a Code Assist licence: unknown.
    expect(await geminiSignedIn(home: home, env: const {'GOOGLE_CLOUD_PROJECT': 'p'}), isNull);
    expect(await geminiSignedIn(home: home, env: const {'GOOGLE_CLOUD_PROJECT_ID': 'p'}), isNull);
    // Gemini CLI also loads ~/.gemini/.env and ~/.env, as its auth docs suggest.
    File('$home/.gemini/.env').writeAsStringSync('# licence\nGOOGLE_CLOUD_PROJECT=my-proj\n');
    expect(await geminiSignedIn(home: home, env: const {}), isNull);
    File('$home/.gemini/.env').writeAsStringSync('GOOGLE_CLOUD_PROJECT=""\n');
    expect(await geminiSignedIn(home: home, env: const {}), isFalse);
    File('$home/.env').writeAsStringSync('export GEMINI_API_KEY=k\n');
    expect(await geminiSignedIn(home: home, env: const {}), isTrue);
    File('$home/.env').deleteSync();
    File('$home/.gemini/settings.json').writeAsStringSync('{"security":{"auth":{"selectedType":"vertex-ai"}}}');
    expect(await geminiSignedIn(home: home, env: const {}), isNull);
  });

  group('other ACP agents', () {
    test('goose is moved off its auto mode, which never asks, before the first prompt', () async {
      final r = rig(['acp/goose_mode.jsonl']);
      final d = r.driver('goose', 'goose');
      final s = await d.start(r.spec());
      final seen = _Seen(s);
      expect(r.spawns.single.args, ['acp']);
      expect(r.spawns.single.env['GOOSE_MODE'], 'approve');
      await s.send('go');
      await seen.untilStatus(ExecutionStatus.finished);
      r.expectPlayed();
      final methods = [for (final m in r.channels.single.sent) m['method']];
      expect(methods.indexOf('session/set_mode'), lessThan(methods.indexOf('session/prompt')));
      await s.close();
    });

    test('Kiro has Autopilot turned off before the first prompt, and again when it turns it back on', () async {
      final r = rig(['acp/kiro_autopilot.jsonl']);
      final s = await r.driver('kiro', 'kiro-cli').start(r.spec());
      final seen = _Seen(s);
      expect(r.spawns.single.args, ['acp', '--agent-engine=v3', '--auth-method=cli']);
      await s.send('go');
      await seen.untilStatus(ExecutionStatus.finished);
      await seen.until(
        () => r.channels.single.sent.where((m) => m['method'] == 'session/set_config_option').length == 2,
      );
      r.expectPlayed();
      final methods = [for (final m in r.channels.single.sent) m['method']];
      expect(methods.indexOf('session/set_config_option'), lessThan(methods.indexOf('session/prompt')));
      expect(seen.notices, isEmpty);
      await s.close();
    });

    test('Kiro refuses a project whose .kiro folder has its own agents or MCP servers', () async {
      final r = rig(const []);
      expect(await acpProfileOf('kiro-cli').preflight(r.work), isNull);
      Directory('${r.work}/.kiro/settings').createSync(recursive: true);
      File('${r.work}/.kiro/settings/mcp.json').writeAsStringSync('{}');
      expect(await acpProfileOf('kiro-cli').preflight(r.work), contains('.kiro folder can let Kiro CLI act'));
      Directory('${r.work}/.kiro/agents').createSync();
      expect(await acpProfileOf('kiro-cli').preflight(r.work), contains('(agents/, settings/mcp.json)'));
    });

    test('a same-named program (pressly goose, AWS Copilot) shows as a problem, not a ready agent', () async {
      final goose = File('${tmp.path}/goose')..writeAsStringSync('#!/bin/sh\necho "goose version: v3.26.0"\n');
      await Process.run('chmod', ['+x', goose.path]);
      AcpDriver driver(String cmd) =>
          AcpDriver(id: cmd, label: cmd, command: cmd, which: (c) async => goose.path, signedIn: () async => null);
      expect((await driver('goose').detect()).problem, contains("not Block's goose"));
      expect((await driver('copilot').detect()).problem, contains('not GitHub Copilot CLI'));
      goose.writeAsStringSync('#!/bin/sh\necho "goose 1.9.3"\n');
      expect((await driver('goose').detect()).problem, isNull);
    });

    test("Copilot's allow-all environment variable from the user's shell is turned off", () async {
      expect(acpProfileOf('copilot').env(null)['COPILOT_ALLOW_ALL'], 'false');
    });

    test('an Antigravity CLI before 1.5.0 shows the version problem; it needs consent', () async {
      final agy = File('${tmp.path}/agy')..writeAsStringSync('#!/bin/sh\necho "agy 1.4.11"\n');
      await Process.run('chmod', ['+x', agy.path]);
      AcpDriver driver() => AcpDriver(
        id: 'antigravity',
        label: 'Antigravity CLI',
        command: 'agy',
        which: (c) async => agy.path,
        signedIn: () async => false,
      );
      expect(driver().info.needsConsent, isTrue);
      final old = await driver().detect();
      expect((old.installed, old.version), (true, 'agy 1.4.11'));
      expect(old.problem, 'Antigravity CLI 1.4.11 is too old: update to 1.5.0 or later.');
      agy.writeAsStringSync('#!/bin/sh\necho "agy 1.5.0"\n');
      expect((await driver().detect()).problem, startsWith('Not signed in. Run `agy` in a terminal'));
    });

    test('Qwen Code refuses a project whose .qwen folder could let it act unasked', () async {
      final r = rig(const []);
      Directory('${r.work}/.qwen/policies').createSync(recursive: true);
      expect(acpProfileOf('qwen').preflight(r.work), completion(contains('.qwen folder can let Qwen Code act')));
      expect(await acpProfileOf('gemini').preflight(r.work), isNull);
    });

    test('no allow-once option: refused, with a notice', () async {
      final r = rig(['acp/always_only.jsonl']);
      final d = r.driver('acp:dsh', 'dsh');
      final s = await d.start(r.spec());
      final seen = _Seen(s);
      await s.send('go');
      await seen.untilStatus(ExecutionStatus.waitingForConfirmation);
      expect(seen.calls.single.actionKind, 'AcpOtherAction');
      await s.respond(accept: true, callIds: [seen.calls.single.id]);
      await seen.untilStatus(ExecutionStatus.finished);
      r.expectPlayed();
      expect(seen.notices.single, 'dsh only offered to always allow "Deploy", so it was refused.');
      await s.close();
    });

    test('without HTTP MCP our server stays out of session/new; the first prompt still carries the briefing', () async {
      final r = rig(['acp/briefing_no_http.jsonl']);
      final s = await r
          .driver('acp:dsh', 'dsh')
          .start(
            r.spec(
              briefing: DriverBriefing(
                mcpUrl: 'http://127.0.0.1:7777/mcp',
                mcpToken: 't',
                skillDir: '${tmp.path}/none',
                sessionSkill: 'Session text.',
              ),
            ),
          );
      final seen = _Seen(s);
      await s.send('Hi');
      await seen.untilStatus(ExecutionStatus.finished);
      r.expectPlayed();
      expect(_prompts(r.channels.single).single, '<everyai-session>\nSession text.\n</everyai-session>\n\nHi');
      await s.close();
    });

    test("OpenCode's briefing goes in its inline config with the permission rules", () async {
      final r = rig(['opencode/handshake.jsonl']);
      final s = await r
          .driver('acp:opencode', 'opencode')
          .start(
            r.spec(
              mode: AgentMode.plan,
              briefing: DriverBriefing(
                mcpUrl: 'http://127.0.0.1:7777/mcp',
                mcpToken: 'tok',
                skillDir: '${tmp.path}/b/briefing/skills',
                sessionSkill: 'Session text.',
              ),
            ),
          );
      r.expectPlayed();
      final config = jsonDecode(r.spawns.single.env['OPENCODE_CONFIG_CONTENT']!) as Map<String, Object?>;
      expect(((config['mcp']! as Map)['servers']! as Map).keys, ['everyai']);
      expect(config['permission'], isA<Map<String, Object?>>());
      expect(r.spawns.single.args, ['acp']);
      await s.close();
    });
  });
  group('Cursor CLI (derived from its ACP doc)', () {
    test(
      'the handshake: `acp`, Plan pinned to its plan mode, our server in session/new and no .cursor/mcp.json',
      () async {
        final r = rig(['cursor/handshake.jsonl']);
        final s = await r
            .driver('cursor', 'cursor-agent', args: const ['--force'])
            .start(r.spec(mode: AgentMode.plan, briefing: _cursorBrief(_Host())));
        await r.channels.single.finished;
        r.expectPlayed();
        expect(r.spawns.single.args, ['acp']);
        expect(Directory('${r.work}/.cursor').existsSync(), isFalse);
        await s.close();
      },
    );

    test('`agent` is found when `cursor-agent` is not on PATH', () async {
      final r = rig(['cursor/load_unknown.jsonl']);
      _stored(r, 'c0', 'cur-old');
      final d = r.driver('cursor', 'cursor-agent', which: (c) async => c == 'agent' ? '/opt/cursor/agent' : null);
      final s = await d.attach('c0');
      final seen = _Seen(s);
      await s.send('Hello');
      await seen.untilStatus(ExecutionStatus.finished);
      expect(r.spawns.single.executable, '/opt/cursor/agent');
      // session/load answered "Session not found": a fresh session, and the user is told.
      r.expectPlayed();
      expect(seen.notices.single, contains("couldn't reopen its conversation, so it starts fresh"));
    });

    Future<(_Rig, HarnessSession, _Seen, _Host)> asking(String script) async {
      final r = rig([script]);
      final host = _Host();
      final s = await r.driver('cursor', 'cursor-agent').start(r.spec(briefing: _cursorBrief(host)));
      final seen = _Seen(s);
      await s.send('go');
      await seen.until(() => host.calls.isNotEmpty);
      return (r, s, seen, host);
    }

    test('cursor/ask_question is our question card; the picks go back as option ids', () async {
      final (r, s, seen, host) = await asking('cursor/ask.jsonl');
      final row = seen.calls.single;
      expect(
        (row.toolName, row.actionKind, hostToolOf(row)),
        ('everyai__ask_user_question', 'MCPToolAction', askUserQuestionTool),
      );
      final call = host.calls.single;
      expect((call.name, call.id), (askUserQuestionTool, row.id));
      expect(call.args, {
        'questions': [
          {
            'question': 'Which database?',
            'header': 'Setup',
            'multi_select': false,
            'options': [
              {'label': 'Postgres', 'description': ''},
              {'label': 'SQLite', 'description': ''},
            ],
          },
          {
            'question': 'Which extras?',
            'header': '',
            'multi_select': true,
            'options': [
              {'label': 'Auth', 'description': ''},
              {'label': 'Billing', 'description': ''},
              {'label': 'Search', 'description': ''},
            ],
          },
        ],
      });
      for (final e in call.args.entries) {
        expect(row.action[e.key], e.value);
      }
      // Waiting on a card isn't waiting on an approval.
      expect(seen.status, ExecutionStatus.running);
      final questions = Question.listFrom(call.args);
      final answers = [
        const QuestionAnswer(selected: {0}),
        const QuestionAnswer(selected: {0, 2}),
      ];
      host.answer(answersReason(questions, answers));
      await seen.untilStatus(ExecutionStatus.finished);
      r.expectPlayed();
      expect(_replyTo(r.channels.single, 'q1'), {
        'outcome': {
          'outcome': 'answered',
          'answers': [
            {
              'questionId': 'db',
              'selectedOptionIds': ['pg'],
            },
            {
              'questionId': 'extras',
              'selectedOptionIds': ['auth', 'search'],
            },
          ],
        },
      });
      // Cursor's own tool_call for the same id added no second row.
      expect(seen.calls, hasLength(1));
      final card = _transcript(seen.all).items.whereType<QuestionItem>().single;
      expect(card.answers, answers);
      await s.close();
    });

    test(
      'an Other answer or a reply in chat goes back as skipped with the words; a given-up card as cancelled',
      () async {
        final questions = Question.listFrom(_askArgs());
        final other = answersReason(questions, [
          const QuestionAnswer(selected: {1}),
          const QuestionAnswer(other: 'Only logging'),
        ]);
        for (final (text, isError, want) in [
          (
            other,
            false,
            {
              'outcome': {'outcome': 'skipped', 'reason': other},
            },
          ),
          (
            repliedInChat,
            false,
            {
              'outcome': {'outcome': 'skipped', 'reason': repliedInChat},
            },
          ),
          (
            'Error: no longer waiting.',
            true,
            {
              'outcome': {'outcome': 'cancelled'},
            },
          ),
        ]) {
          final (r, s, seen, host) = await asking('cursor/ask.jsonl');
          host.answer(text, isError: isError);
          await seen.untilStatus(ExecutionStatus.finished);
          r.expectPlayed();
          expect(_replyTo(r.channels.single, 'q1'), want, reason: text);
          expect(seen.results.single.text, text);
          await s.close();
        }
      },
    );

    test(
      'the _cursor/ spelling is handled; over 4 questions are skipped with a note; unknown requests cancelled',
      () async {
        final r = rig(['cursor/ask_misc.jsonl']);
        final host = _Host();
        final s = await r.driver('cursor', 'cursor-agent').start(r.spec(briefing: _cursorBrief(host)));
        final seen = _Seen(s);
        await s.send('go');
        await seen.untilStatus(ExecutionStatus.finished);
        r.expectPlayed();
        expect(host.calls, isEmpty);
        expect(seen.calls, isEmpty);
        await s.close();
      },
    );

    test('without a briefing questions are skipped and plans cancelled, and nothing waits', () async {
      final r = rig(['cursor/no_host.jsonl']);
      final s = await r.driver('cursor', 'cursor-agent').start(r.spec());
      final seen = _Seen(s);
      await s.send('go');
      await seen.untilStatus(ExecutionStatus.finished);
      r.expectPlayed();
      expect(seen.calls, isEmpty);
      await s.close();
    });

    test('cursor/create_plan is our plan card: approved is accepted, changes are rejected with the words', () async {
      final revise = '$planRevisionLead Use a stateful widget.';
      for (final (text, want) in [
        (
          planApprovedReason,
          {
            'outcome': {'outcome': 'accepted'},
          },
        ),
        (
          revise,
          {
            'outcome': {'outcome': 'rejected', 'reason': revise},
          },
        ),
      ]) {
        final (r, s, seen, host) = await asking('cursor/plan.jsonl');
        final row = seen.calls.single;
        expect((row.toolName, hostToolOf(row)), ('everyai__present_plan', presentPlanTool));
        expect(host.calls.single.args, {
          'title': 'Add a counter',
          'summary': 'A counter with tests.',
          'steps': [
            {'title': 'Write the widget'},
            {'title': 'Add a test'},
          ],
          'body': '## Steps\n\nBuild it, then test it.',
        });
        final plan = _transcript(seen.all).items.whereType<PlanProposal>().single;
        expect(plan.markdown, contains('Build it, then test it.'));
        expect(plan.steps.map((st) => st.title), ['Write the widget', 'Add a test']);
        host.answer(text);
        await seen.untilStatus(ExecutionStatus.finished);
        r.expectPlayed();
        expect(_replyTo(r.channels.single, 'p1'), want);
        final settled = _transcript(seen.all).items.whereType<PlanProposal>().single;
        expect(settled.verdict, text == planApprovedReason ? PlanVerdict.approved : PlanVerdict.revised);
        await s.close();
      }
    });

    test('Stop while a plan waits: the card is given up, Cursor gets cancelled, the row is Cancelled', () async {
      final (r, s, seen, host) = await asking('cursor/plan_stop.jsonl');
      await s.interrupt();
      expect(await host.calls.single.ended, HostEnd.cancelled);
      await seen.untilStatus(ExecutionStatus.paused);
      r.expectPlayed();
      expect(seen.results.single.text, 'Cancelled.');
      expect(seen.results.single.actionId, seen.calls.single.id);
      await s.close();
    });

    test('closing the session, or the agent exiting, gives up a waiting card', () async {
      final (_, s, _, host) = await asking('cursor/plan.jsonl');
      await s.close();
      expect(await host.calls.single.ended, HostEnd.sessionClosed);

      final (_, s2, seen2, host2) = await asking('cursor/ask_eof.jsonl');
      expect(await host2.calls.single.ended, HostEnd.clientGone);
      await seen2.until(() => seen2.results.isNotEmpty);
      expect(seen2.results.single.text, 'Cancelled.');
      await s2.close();
    });

    test('cursor/update_todos is the task list (replace or merge by id); cursor/task a subagent row', () async {
      final r = rig(['cursor/todos_task.jsonl']);
      final s = await r.driver('cursor', 'cursor-agent').start(r.spec());
      final seen = _Seen(s);
      await s.send('go');
      await seen.untilStatus(ExecutionStatus.finished);
      r.expectPlayed();
      final lists = [
        for (final c in seen.calls)
          if (c.actionKind == 'TaskTrackerAction') c,
      ];
      expect({for (final c in lists) c.toolName}, {'acp:update_todos'});
      List<Object?> tasks(ActionCall c) => c.action['task_list']! as List<Object?>;
      expect(tasks(lists[0]), [
        {'title': 'Read the code', 'status': 'todo', 'notes': ''},
        {'title': 'Fix the bug', 'status': 'in_progress', 'notes': ''},
      ]);
      expect(tasks(lists[1]), [
        {'title': 'Read the code', 'status': 'done', 'notes': ''},
        {'title': 'Fix the bug', 'status': 'in_progress', 'notes': ''},
        {'title': 'Write docs', 'status': 'done', 'notes': 'cancelled'},
      ]);
      // The request form replaces too, and is acked.
      expect(tasks(lists[2]), [
        {'title': 'Ship it', 'status': 'todo', 'notes': ''},
      ]);
      final task = seen.calls.singleWhere((c) => c.actionKind == 'TaskAction');
      expect((task.toolName, task.str('description'), task.str('agent')), ('acp:task', 'Explore the repo', 'explore'));
      expect(seen.results.singleWhere((x) => x.actionId == task.id).text, 'Done in 4.2 s.');
      // Its tool_call for the same id added no row.
      expect(seen.calls.where((c) => c.toolCallId == 'task-1'), hasLength(1));
      final items = _transcript(seen.all).items;
      expect(items.whereType<SubagentItem>(), hasLength(1));
      expect(items.whereType<PlanItem>().last.tasks.single.title, 'Ship it');
      await s.close();
    });

    test('a subagent still running when the user stops closes as Cancelled', () async {
      final r = rig(['cursor/task_stop.jsonl']);
      final s = await r.driver('cursor', 'cursor-agent').start(r.spec());
      final seen = _Seen(s);
      await s.send('go');
      await seen.until(() => seen.calls.isNotEmpty);
      expect(seen.calls.single.str('agent'), 'reviewer');
      await s.interrupt();
      await seen.untilStatus(ExecutionStatus.paused);
      r.expectPlayed();
      expect(seen.results.single.text, 'Cancelled.');
      await s.close();
    });

    test("to-dos Cursor replays while loading a conversation aren't shown again", () async {
      final r = rig(['cursor/load_replay.jsonl']);
      _stored(r, 'c1', 'cur-old');
      final s = await r.driver('cursor', 'cursor-agent').attach('c1');
      final seen = _Seen(s);
      await s.send('Next');
      await seen.untilStatus(ExecutionStatus.finished);
      r.expectPlayed();
      expect(seen.calls, isEmpty);
      await s.close();
    });

    test("Cursor's tool_call before its question request: that row closes, the card has its own id", () async {
      final (r, s, seen, host) = await asking('cursor/ask_tool_first.jsonl');
      final (step, card) = (seen.calls.first, seen.calls.last);
      expect(seen.calls, hasLength(2));
      expect(step.id, isNot(card.id));
      expect(host.calls.single.id, card.id);
      expect(seen.results.single, isA<ToolResult>().having((x) => x.actionId, 'actionId', step.id));
      host.answer(
        answersReason(Question.listFrom(host.calls.single.args), const [
          QuestionAnswer(selected: {0}),
        ]),
      );
      await seen.untilStatus(ExecutionStatus.finished);
      r.expectPlayed();
      expect({for (final x in seen.results) x.actionId}, {step.id, card.id});
      expect({for (final x in seen.results) x.id}, hasLength(2));
      final items = _transcript(seen.all).items;
      expect(items.whereType<QuestionItem>().single.answers, isNotNull);
      final keys = [for (final i in items) i.key];
      expect(keys.toSet(), hasLength(keys.length));
      final steps = [
        for (final i in items.whereType<StepItem>()) i.step,
        for (final g in items.whereType<ExploreGroup>()) ...g.steps,
      ];
      expect(steps, isNotEmpty);
      expect(steps.every((st) => st.done), isTrue);
      await s.close();
    });

    test(
      'a subagent whose only end is its tool_call_update closes; one shown first as a step becomes a subagent row',
      () async {
        final r = rig(['cursor/task_update_end.jsonl']);
        final s = await r.driver('cursor', 'cursor-agent').start(r.spec());
        final seen = _Seen(s);
        await s.send('go');
        await seen.untilStatus(ExecutionStatus.finished);
        r.expectPlayed();
        final tasks = seen.calls.where((c) => c.actionKind == 'TaskAction').toList();
        expect([for (final t in tasks) t.toolCallId], ['task-1', 'ex-1']);
        String? endOf(ActionCall c) => seen.results.where((x) => x.actionId == c.id).singleOrNull?.text;
        expect([for (final t in tasks) endOf(t)], ['Done.', 'Failed.']);
        // The step Cursor showed for ex-1 first is closed too.
        expect(seen.calls.every((c) => endOf(c) != null), isTrue);
        expect(_transcript(seen.all).items.whereType<SubagentItem>(), hasLength(2));
        await s.close();
      },
    );

    test('to-dos replayed while loading are kept: a merge after the reopen changes the whole list', () async {
      final r = rig(['cursor/load_merge.jsonl']);
      _stored(r, 'c1', 'cur-old');
      final s = await r.driver('cursor', 'cursor-agent').attach('c1');
      final seen = _Seen(s);
      await s.send('Next');
      await seen.untilStatus(ExecutionStatus.finished);
      r.expectPlayed();
      expect(seen.calls.single.action['task_list'], [
        {'title': 'Old', 'status': 'todo', 'notes': ''},
        {'title': 'Older', 'status': 'done', 'notes': ''},
      ]);
      await s.close();
    });

    test('Cursor refuses a project whose .cursor folder allows tools or has hooks', () async {
      final r = rig(const []);
      final p = acpProfileOf('cursor-agent');
      Directory('${r.work}/.cursor').createSync();
      File('${r.work}/.cursor/cli.json').writeAsStringSync('{"permissions":{"allow":[],"deny":["Shell(rm)"]}}');
      expect(await p.preflight(r.work), isNull);
      File('${r.work}/.cursor/cli.json').writeAsStringSync('{"permissions":{"allow":["Shell(*)"]}}');
      expect(await p.preflight(r.work), contains('(cli.json "permissions.allow")'));
      File('${r.work}/.cursor/hooks.json').writeAsStringSync('{}');
      expect(await p.preflight(r.work), contains('.cursor folder can let Cursor CLI act'));
      expect(await p.preflight(r.work), contains('hooks.json'));
      expect(acpCommand('cursor-agent', const ['--trust', '--approve-mcps', '--model', 'x']).args, [
        'acp',
        '--model',
        'x',
      ]);
    });

    test("another program named `agent` isn't taken for Cursor CLI", () async {
      final agent = File('${tmp.path}/agent')..writeAsStringSync('#!/bin/sh\necho "agent 0.3.1"\n');
      await Process.run('chmod', ['+x', agent.path]);
      AcpDriver driver() => AcpDriver(
        id: 'cursor',
        label: 'Cursor CLI',
        command: 'cursor-agent',
        which: (c) async => c == 'agent' ? agent.path : null,
        signedIn: () async => null,
      );
      expect((await driver().detect()).problem, contains('not Cursor CLI'));
      agent.writeAsStringSync('#!/bin/sh\necho "2026.10.22-3f1c2ab"\n');
      expect((await driver().detect()).problem, isNull);
    });

    test('signed in: a key in the environment; the keychain entry by exit code only', () async {
      final p = acpProfileOf('cursor-agent');
      expect(await p.signedIn('/x/cursor-agent', env: const {'CURSOR_API_KEY': 'k'}), isTrue);
      expect(await p.signedIn('/x/cursor-agent', env: const {'CURSOR_AUTH_TOKEN': 't'}), isTrue);
      expect([cursorSignedInFrom(0), cursorSignedInFrom(44), cursorSignedInFrom(1)], [true, false, null]);
    });
  });
}
