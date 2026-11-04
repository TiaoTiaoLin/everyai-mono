import 'dart:convert';

import 'package:every_ai/features/code/drivers/acp/acp_agents.dart';
import 'package:every_ai/features/code/drivers/acp/acp_xai.dart';
import 'package:every_ai/features/code/drivers/json_rpc.dart';
import 'package:flutter_test/flutter_test.dart';

// Payloads adapted from T3 Code's xaiAcpExtension.test.ts (MIT, @ 8b44f42b),
// not recorded from a real `grok agent stdio`: unverified.

void main() {
  test('x.ai methods by either prefix; others are null', () {
    expect(xaiMethod('x.ai/task_completed'), 'task_completed');
    expect(xaiMethod('_x.ai/session/prompt_complete'), 'session/prompt_complete');
    expect(xaiMethod('session/update'), isNull);
    expect(xaiMethod('_cursor/task'), isNull);
    expect(xaiMethod('x.ai/'), isNull);
  });

  group('background tasks', () {
    test('the id: the snapshot first, then task_id, then tool_call_id; none is null', () {
      Map<String, Object?> n(Map<String, Object?> u) => {'sessionId': 's', 'update': u};
      expect(xaiTask(n({'tool_call_id': 'call-1', 'task_id': 'task-1'}), completed: false)?.id, 'task-1');
      expect(xaiTask(n({'tool_call_id': 'call-1'}), completed: false)?.id, 'call-1');
      expect(
        xaiTask(
          n({
            'task_id': 'task-1',
            'task_snapshot': {'task_id': 'snap-1'},
          }),
          completed: true,
        )?.id,
        'snap-1',
      );
      expect(xaiTask(n({'sessionUpdate': 'task_completed'}), completed: true), isNull);
      expect(xaiTask(const {}, completed: true), isNull);
    });

    test('a non-zero exit fails; a monitor is named by its description', () {
      final failed = xaiTask({
        'update': {
          'sessionUpdate': 'task_completed',
          'task_snapshot': {'task_id': 't', 'command': 'npm test', 'exit_code': 1, 'output': 'boom'},
        },
      }, completed: true)!;
      expect((failed.status, failed.label, failed.monitor, failed.output), ('failed', 'npm test', false, 'boom'));
      expect(xaiTaskResultText(failed), 'boom');
      final monitor = xaiTask({
        'update': {
          'task_snapshot': {
            'task_id': 't2',
            'command': 'for i in 1 2 3; do echo tick; done',
            'display_command': '[monitor] Watch three tick echoes',
            'exit_code': 0,
            'kind': 'monitor',
          },
        },
      }, completed: true)!;
      expect((monitor.status, monitor.label, monitor.monitor), ('completed', 'Watch three tick echoes', true));
      expect(xaiTaskCall(monitor, id: 'xbg-t2').summary, 'Watching: Watch three tick echoes');
      final started = xaiTask({
        'update': {'task_id': 't3', 'monitor_description': 'Logs', 'description': 'other'},
      }, completed: false)!;
      expect((started.status, started.label, started.monitor), ('running', 'Logs', true));
      expect(
        xaiTaskResultText(
          xaiTask({
            'update': {
              'task_snapshot': {'task_id': 't', 'exit_code': 2},
            },
          }, completed: true)!,
        ),
        'Failed (exit code 2).',
      );
    });
  });

  test('subagent_finished: completed reports its output, failed and cancelled their error', () {
    XaiSubagentDone? f(Map<String, Object?> u) => xaiSubagentDone({
      'sessionId': 'root',
      'update': {'sessionUpdate': 'subagent_finished', 'child_session_id': 'child', ...u},
    });
    expect(f({'status': 'completed', 'output': 'SUBAGENT_DONE'}), (
      child: 'child',
      status: 'completed',
      result: 'SUBAGENT_DONE',
    ));
    expect(f({'status': 'failed', 'error': 'tool crashed'})?.result, 'tool crashed');
    expect(f({'status': 'cancelled', 'error': 'interrupted'})?.status, 'cancelled');
    expect(f({'status': 'failed', 'output': 'partial'})?.result, isNull);
    expect(f({'status': 'timed_out'}), isNull);
    expect(f({'status': 'completed', 'child_session_id': null}), isNull);
  });

  group('subagents', () {
    test('a spawn is known by its title, variant or subagent type', () {
      expect(xaiIsSpawn({'title': 'Task'}), isTrue);
      expect(xaiIsSpawn({'title': 'spawn_subagent'}), isTrue);
      expect(
        xaiIsSpawn({
          'title': 'x',
          'rawInput': {'variant': 'Task'},
        }),
        isTrue,
      );
      expect(
        xaiIsSpawn({
          'title': 'x',
          'rawInput': {'subagent_type': 'generalPurpose'},
        }),
        isTrue,
      );
      expect(
        xaiIsSpawn({
          'title': 'Read file',
          'rawInput': {'path': 'a'},
        }),
        isFalse,
      );
    });

    test('a background ack and the child id; the report loses its id line', () {
      const id = '019f0220-e192-7c41-9e9d-b406bc3459c8';
      const done = 'Server audit complete.\n\nAgent ID: $id (resume supported)';
      expect(xaiChildId(done), id);
      expect(xaiAsyncAck(done), isFalse);
      expect(xaiReport(done), 'Server audit complete.');
      const ack = 'Subagent started in background.\nsubagent_id: $id\nUse get_command_or_subagent_output.';
      expect(xaiAsyncAck(ack), isTrue);
      expect(xaiChildId(ack), id);
      expect(xaiChildId('no id here'), isNull);
      final call = {
        'toolCallId': 'task-1',
        'title': 'Task',
        'rawInput': {'description': 'Explore', 'prompt': 'Audit apps/server.', 'subagent_type': 'generalPurpose'},
        'rawOutput': {'type': 'Text', 'text': done},
      };
      expect(xaiOutputText(call), done);
      final row = xaiSpawnCall(call, id: 'tc-task-1');
      expect(row.actionKind, 'TaskAction');
      expect(
        (row.action['description'], row.action['prompt'], row.action['agent']),
        ('Explore', 'Audit apps/server.', 'generalPurpose'),
      );
      expect(
        xaiOutputText({
          'rawOutput': {'output': utf8.encode('bytes')},
        }),
        'bytes',
      );
    });
  });

  test('prompt completion: the direct method and turn_completed; wakes and nameless turns ignored', () {
    expect(xaiPromptDone('session/prompt_complete', {'sessionId': 's', 'promptId': 'p1', 'stopReason': 'end_turn'}), (
      sessionId: 's',
      promptId: 'p1',
      stopReason: 'end_turn',
      agentResult: null,
    ));
    expect(xaiPromptDone('session/prompt_complete', {'sessionId': 's', 'stopReason': 'end_turn'})?.promptId, isNull);
    expect(
      xaiPromptDone('session_notification', {
        'sessionId': 's',
        'update': {'sessionUpdate': 'turn_completed', 'prompt_id': 'p2', 'stop_reason': 'rate_limit'},
      })?.stopReason,
      'rate_limit',
    );
    expect(
      xaiPromptDone('session/update', {
        'update': {'sessionUpdate': 'turn_completed'},
      }),
      isNull,
    );
    expect(xaiPromptDone('session/prompt_complete', {'promptId': 'task-completed-abc'}), isNull);
    expect(
      xaiPromptDone('session_notification', {
        'update': {'sessionUpdate': 'subagent_finished', 'prompt_id': 'p'},
      }),
      isNull,
    );
    expect(xaiPromptDone('task_completed', const {}), isNull);
  });

  test('redaction: env and header values, secret-named strings; names kept; input untouched', () {
    final input = <String, Object?>{
      'servers': [
        {
          'name': 'github',
          'command': 'npx',
          'env': {
            'GITHUB_TOKEN': 'ghp-secret',
            'NESTED': {'x': 'sk-deep'},
          },
          'headers': [
            {'name': 'Authorization', 'value': 'Bearer sk-secret'},
          ],
          'apiKey': 'sk-key',
          'token': 'tok-1',
          'tokens': 3,
        },
      ],
    };
    final before = jsonEncode(input);
    final out = jsonEncode(xaiRedacted(input));
    for (final secret in ['ghp-secret', 'sk-deep', 'sk-secret', 'sk-key', 'tok-1']) {
      expect(out, isNot(contains(secret)));
    }
    final server = ((xaiRedacted(input)! as Map)['servers'] as List).single as Map;
    expect(server['env'], {
      'GITHUB_TOKEN': '<redacted>',
      'NESTED': {'x': '<redacted>'},
    });
    expect(server['headers'], [
      {'name': 'Authorization', 'value': '<redacted>'},
    ]);
    expect((server['name'], server['command'], server['tokens']), ('github', 'npx', 3));
    expect(jsonEncode(input), before);
  });

  test('a no-terminal exit, on macOS and Linux', () {
    expect(isNoTtyExit('Error: Device not configured (os error 6)'), isTrue);
    expect(isNoTtyExit('Stopped: Error: Device not configured (os error 6)'), isTrue);
    expect(isNoTtyExit('Error: No such device or address (os error 6)'), isTrue);
    expect(isNoTtyExit('Error: No such file or directory (os error 2)'), isFalse);
    expect(isNoTtyExit('os error 60'), isFalse);
    expect(isNoTtyExit(''), isFalse);
  });

  test('grok models: logged in, logged out, or unknown', () {
    expect(parseGrokModelsLogin('You are logged in as a@b.c\nModels:\n- grok-build (default)'), isTrue);
    expect(parseGrokModelsLogin('You are not logged in. Run grok login.'), isFalse);
    expect(parseGrokModelsLogin('Not authenticated'), isFalse);
    expect(parseGrokModelsLogin('Models:\n- grok-build'), isNull);
  });

  test("Grok's usage-limit code", () {
    expect(xaiUsageLimit(const JsonRpcError(-32003, 'limit')), isTrue);
    expect(xaiUsageLimit(const JsonRpcError(-32603, 'internal')), isFalse);
  });

  group('profile', () {
    test('the asking flags go before agent stdio; the skip-approval flags and allow rules are dropped', () {
      const pinned = ['--permission-mode', 'default', '--no-auto-update', 'agent', 'stdio'];
      expect(acpCommand('grok', const []).args, pinned);
      expect(acpCommand('grok agent stdio --yolo', const []).args, pinned);
      expect(
        acpCommand('/opt/bin/grok', const [
          '--permission-mode',
          'bypassPermissions',
          'agent',
          '--always-approve',
          '--allow',
          'Bash(*)',
          '--dangerously-skip-permissions',
          'stdio',
        ]).args,
        pinned,
      );
      final p = acpCommand('grok', const []).profile;
      expect((p.agent, p.ttyFallback, p.needsConsent), (AcpAgent.grok, true, false));
      expect(p.initializeMeta, {'clientType': 'extension'});
      expect(p.cancelMeta, {'cancelTrigger': 'ctrl_c'});
    });

    test('authenticate with the API key when one is set, else the cached sign-in; other agents none', () async {
      final grok = acpCommand('grok', const []).profile;
      expect(await grok.authMethod(() async => {'XAI_API_KEY': 'xai-1'}), 'xai.api_key');
      expect(await grok.authMethod(() async => {'XAI_API_KEY': ' '}), 'cached_token');
      var read = false;
      expect(
        await acpCommand('gemini', const []).profile.authMethod(() async {
          read = true;
          return const {};
        }),
        isNull,
      );
      expect(read, isFalse);
    });

    test('signed in with XAI_API_KEY, by its presence only', () async {
      expect(await acpCommand('grok', const []).profile.signedIn('/x/grok', env: {'XAI_API_KEY': 'k'}), isTrue);
    });
  });
}
