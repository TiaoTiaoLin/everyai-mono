import 'dart:convert';
import 'dart:io';

import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/drivers/acp/acp_driver.dart';
import 'package:every_ai/features/code/drivers/acp/acp_files.dart';
import 'package:every_ai/features/code/drivers/driver_policy.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/harness.dart';
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

  AcpDriver driver(String id, String command, {List<String> args = const [], Duration? initTimeout}) => AcpDriver(
    id: id,
    label: switch (command) {
      'gemini' => 'Gemini CLI',
      'opencode' => 'OpenCode',
      _ => command,
    },
    command: command,
    args: args,
    which: (c) async => '/usr/local/bin/$c',
    dataDir: () async => dataDir,
    initTimeout: initTimeout ?? const Duration(seconds: 60),
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
      await s.respond(accept: false, reason: 'Not now.', callIds: [seen.calls.single.id]);
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
      await s.respond(accept: false, reason: 'Stop that.');
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

  test('Gemini counts as signed in with an API key, or with its cached Google sign-in', () async {
    final home = tmp.path;
    expect(await geminiSignedIn(home: home, env: const {'GEMINI_API_KEY': 'k'}), isTrue);
    expect(await geminiSignedIn(home: home, env: const {}), isFalse);
    Directory('$home/.gemini').createSync();
    File('$home/.gemini/settings.json').writeAsStringSync('{"security":{"auth":{"selectedType":"oauth-personal"}}}');
    expect(await geminiSignedIn(home: home, env: const {}), isFalse);
    File('$home/.gemini/oauth_creds.json').writeAsStringSync('{}');
    expect(await geminiSignedIn(home: home, env: const {}), isTrue);
    File('$home/.gemini/settings.json').writeAsStringSync('{"security":{"auth":{"selectedType":"vertex-ai"}}}');
    expect(await geminiSignedIn(home: home, env: const {}), isNull);
  });

  group('other ACP agents', () {
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
}
