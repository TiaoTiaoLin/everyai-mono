import 'package:every_ai/features/code/drivers/acp/acp_agents.dart';
import 'package:every_ai/features/code/drivers/acp/acp_mapping.dart';
import 'package:every_ai/features/code/drivers/driver_policy.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:flutter_test/flutter_test.dart';

ActionCall _call(Map<String, Object?> call, {Set<String> servers = const {}, List<Object?> options = const []}) =>
    acpActionEvent({'toolCallId': 'c1', ...call}, id: 'tc-c1', mcpServers: servers, options: options);

void main() {
  group('tool calls', () {
    test('a command with its text is a TerminalAction the rules can judge', () {
      final c = _call({
        'kind': 'execute',
        'title': 'bash',
        'rawInput': {'command': 'ls -la', 'description': 'List'},
      });
      expect(
        (c.actionKind, c.str('command'), c.toolName, c.summary),
        ('TerminalAction', 'ls -la', 'acp:execute', 'bash'),
      );
      expect(autoDecidable(c), isTrue);
    });

    test("Gemini's shell call has only a title, so it keeps a kind of its own", () {
      final c = _call({'kind': 'execute', 'title': 'rm -rf build [current working directory] (Clean up)'});
      expect(c.actionKind, 'AcpExecuteAction');
      expect(c.summary, startsWith('rm -rf build'));
      expect(c.str('command'), isEmpty);
      expect(autoDecidable(c), isFalse);
    });

    test('an edit with a diff names its file and shows only the changed lines', () {
      final old = [for (var i = 0; i < 50; i++) 'line $i'].join('\n');
      final c = _call({
        'kind': 'edit',
        'title': 'Edit a.dart',
        'content': [
          {'type': 'diff', 'path': '/w/a.dart', 'oldText': old, 'newText': old.replaceFirst('line 20', 'LINE 20')},
        ],
        'locations': [
          {'path': '/w/a.dart'},
        ],
      });
      expect((c.actionKind, c.str('command'), c.str('path')), ('FileEditorAction', 'str_replace', '/w/a.dart'));
      expect(c.str('old_str').split('\n'), [
        'line 17',
        'line 18',
        'line 19',
        'line 20',
        'line 21',
        'line 22',
        'line 23',
      ]);
      expect(c.str('new_str'), contains('LINE 20'));
      expect(autoDecidable(c), isTrue);
    });

    test('a new file is a create; a path from the input counts too', () {
      final created = _call({
        'kind': 'edit',
        'content': [
          {'type': 'diff', 'path': '/w/new.txt', 'oldText': null, 'newText': 'hi'},
        ],
      });
      expect((created.str('command'), created.str('file_text')), ('create', 'hi'));
      final fromInput = _call({
        'kind': 'edit',
        'rawInput': {'filePath': '/w/b.ts', 'oldString': 'a', 'newString': 'b'},
      });
      expect((fromInput.actionKind, fromInput.str('path')), ('FileEditorAction', '/w/b.ts'));
    });

    test('a patch over several files lists them all; one without paths asks', () {
      final c = _call({
        'kind': 'edit',
        'locations': [
          {'path': '/w/a'},
          {'path': '/w/b'},
        ],
      });
      expect(c.actionKind, 'ApplyPatchAction');
      expect(c.action['paths'], ['/w/a', '/w/b']);
      expect(autoDecidable(c), isTrue);
      expect(_call({'kind': 'edit', 'title': 'Something'}).actionKind, 'AcpEditAction');
    });

    test('deletes and moves are edits of their paths', () {
      final del = _call({
        'kind': 'delete',
        'locations': [
          {'path': '/w/a'},
        ],
      });
      expect((del.actionKind, del.str('patch_op'), del.str('path')), ('EditAction', 'delete', '/w/a'));
      final move = _call({
        'kind': 'move',
        'locations': [
          {'path': '/w/a'},
          {'path': '/w/b'},
        ],
      });
      expect(move.action['paths'], ['/w/a', '/w/b']);
    });

    test('reads, searches and fetches', () {
      final read = _call({
        'kind': 'read',
        'locations': [
          {'path': '/w/a.txt', 'line': 3},
        ],
      });
      expect((read.actionKind, read.str('path')), ('ReadFileAction', '/w/a.txt'));
      final search = _call({
        'kind': 'search',
        'rawInput': {'pattern': 'TODO', 'path': '/w'},
      });
      expect((search.actionKind, search.str('pattern'), search.str('path')), ('GrepAction', 'TODO', '/w'));
      final fetch = _call({
        'kind': 'fetch',
        'rawInput': {'url': 'https://example.com'},
      });
      expect((fetch.actionKind, fetch.str('url')), ('WebFetchAction', 'https://example.com'));
      expect(_call({'kind': 'read', 'title': 'many files'}).actionKind, 'AcpReadAction');
    });

    test('other kinds keep their own, which always ask', () {
      for (final (kind, ours) in [
        ('think', 'AcpThinkAction'),
        ('switch_mode', 'AcpSwitchModeAction'),
        ('other', 'AcpOtherAction'),
      ]) {
        final c = _call({'kind': kind, 'name': 'task'});
        expect(c.actionKind, ours);
        expect(c.toolName, 'acp:task');
        expect(autoDecidable(c), isFalse);
      }
    });
  });

  group('MCP calls', () {
    test("OpenCode's everyai_<tool> name is our host tool, with its arguments", () {
      final c = _call(
        {
          'kind': 'other',
          'title': 'everyai_ask_user_question',
          'rawInput': {
            'questions': [
              {'question': 'Which?'},
            ],
          },
        },
        servers: {'everyai'},
      );
      expect(
        (c.actionKind, c.toolName, c.str('server'), c.str('tool')),
        ('MCPToolAction', 'everyai__ask_user_question', 'everyai', 'ask_user_question'),
      );
      expect(c.action['questions'], isA<List<Object?>>());
    });

    test("Gemini's options name the server and tool; the title holds the arguments", () {
      final c = _call(
        {'kind': 'other', 'title': '{"plan":"Do it"}'},
        options: [
          {'optionId': 'proceed_always_server', 'name': 'Always Allow everyai', 'kind': 'allow_always'},
          {'optionId': 'proceed_always_tool', 'name': 'Always Allow present_plan', 'kind': 'allow_always'},
          {'optionId': 'proceed_once', 'name': 'Allow', 'kind': 'allow_once'},
        ],
      );
      expect((c.toolName, c.str('plan')), ('everyai__present_plan', 'Do it'));
    });

    test("another server's tool keeps its server; an unknown prefix isn't MCP", () {
      final c = _call({'kind': 'other', 'name': 'github_search_issues'}, servers: {'github', 'everyai'});
      expect((c.actionKind, c.toolName, c.str('server')), ('MCPToolAction', 'github__search_issues', 'github'));
      expect(_call({'kind': 'other', 'name': 'jira_find'}, servers: {'github'}).actionKind, 'AcpOtherAction');
    });
  });

  group('calls over time', () {
    test('updates merge into the call; a finished one gives its result', () {
      var call = mergeToolCall(const {}, {
        'sessionUpdate': 'tool_call',
        'toolCallId': 'c1',
        'status': 'pending',
        'kind': 'execute',
        'title': 'bash',
      });
      call = mergeToolCall(call, {
        'sessionUpdate': 'tool_call_update',
        'toolCallId': 'c1',
        'status': 'in_progress',
        'rawInput': {'command': 'make'},
        'title': null,
      });
      final a = acpActionEvent(call, id: 'tc-c1');
      expect((a.actionKind, a.str('command'), a.summary), ('TerminalAction', 'make', 'bash'));
      call = mergeToolCall(call, {
        'status': 'failed',
        'content': [
          {
            'type': 'content',
            'content': {'type': 'text', 'text': 'boom'},
          },
          {'type': 'terminal', 'terminalId': 't'},
        ],
      });
      final r = acpResultEvent(call, id: 'tr-c1', actionId: a.id, toolName: a.toolName);
      expect((r.outcome, r.text), (ToolOutcome.error, "boom\n(output shown in the agent's terminal)"));
      expect(acpResultText({'rawOutput': 'plain'}), 'plain');
      expect(
        acpResultText({
          'rawOutput': {'output': 'out'},
        }),
        'out',
      );
    });

    test('a plan is a task list that never waits', () {
      final (call, result) = acpPlanEvents([
        {'content': 'Read', 'status': 'completed', 'priority': 'high'},
        {'content': 'Write', 'status': 'in_progress', 'priority': 'high'},
        {'content': 'Test', 'status': 'pending', 'priority': 'low'},
      ], id: 'p1');
      expect(call.actionKind, 'TaskTrackerAction');
      expect(
        [for (final t in call.action['task_list']! as List<Object?>) (t! as Map)['status']],
        ['done', 'in_progress', 'todo'],
      );
      expect((result.actionId, result.outcome), ('p1', ToolOutcome.ok));
      expect(autoDecidable(call), isTrue);
    });
  });

  group('usage', () {
    test("OpenCode's input leaves the cache out; another agent's doesn't", () {
      final oc = acpTurnUsage({
        'inputTokens': 100,
        'outputTokens': 10,
        'thoughtTokens': 5,
        'cachedReadTokens': 800,
        'cachedWriteTokens': 50,
        'totalTokens': 965,
      }, id: 'u1')!;
      expect((oc.input, oc.output, oc.cached, oc.onPlan), (950, 15, 800, true));
      final other = acpTurnUsage({
        'inputTokens': 900,
        'outputTokens': 10,
        'cachedReadTokens': 800,
        'totalTokens': 910,
      }, id: 'u2')!;
      expect((other.input, other.output, other.cached), (900, 10, 800));
      expect(acpTurnUsage(null, id: 'u3'), isNull);
    });

    test('usage_update moves the context ring and counts what was spent since the last one', () {
      final (first, total) = acpUsageUpdate({
        'used': 5000,
        'size': 200000,
        'cost': {'amount': 0.012, 'currency': 'USD'},
      }, id: 'a');
      expect((first.contextTokens, first.costMicros, total), (5000, 12000, 0.012));
      final (second, _) = acpUsageUpdate(
        {
          'used': 7000,
          'size': 200000,
          'cost': {'amount': 0.02, 'currency': 'USD'},
        },
        id: 'b',
        lastCost: total,
      );
      expect(second.costMicros, 8000);
      final (eur, kept) = acpUsageUpdate(
        {
          'used': 1,
          'size': 2,
          'cost': {'amount': 1, 'currency': 'EUR'},
        },
        id: 'c',
        lastCost: 0.02,
      );
      expect((eur.costMicros, kept), (null, 0.02));
    });
  });

  group('session offers', () {
    test('models from config options (efforts for the current one), else the older field', () {
      final fromConfig = acpModels({
        'configOptions': [
          {
            'id': 'model',
            'category': 'model',
            'currentValue': 'b',
            'options': [
              {'value': 'a', 'name': 'A'},
              {
                'group': 'g',
                'name': 'Group',
                'options': [
                  {'value': 'b', 'name': 'B'},
                ],
              },
            ],
          },
          {
            'id': 'effort',
            'category': 'thought_level',
            'currentValue': 'default',
            'options': [
              {'value': 'low', 'name': 'Low'},
              {'value': 'default', 'name': 'Default'},
            ],
          },
        ],
      });
      expect(
        [for (final m in fromConfig) (m.id, m.isDefault, m.efforts.join(','))],
        [('a', false, ''), ('b', true, 'low')],
      );
      final legacy = acpModels({
        'models': {
          'availableModels': [
            {'modelId': 'gemini-2.5-pro', 'name': 'Pro'},
          ],
          'currentModelId': 'gemini-2.5-pro',
        },
      });
      expect((legacy.single.label, legacy.single.isDefault), ('Pro', true));
    });

    test("pictures go as image blocks only when the agent reads them; the user's MCP servers map over", () {
      expect(acpPrompt('hi', images: ['data:image/png;base64,QUJD'], imagesOk: true).last, {
        'type': 'image',
        'mimeType': 'image/png',
        'data': 'QUJD',
      });
      expect(acpPrompt('hi', images: ['data:image/png;base64,QUJD']), hasLength(1));
      final servers = acpMcpServers({
        'fs': {
          'command': 'npx',
          'args': ['-y', 'server'],
          'env': {'KEY': 'v'},
        },
        'web': {'url': 'https://mcp.example/mcp', 'transport': 'http'},
      });
      expect(servers, [
        {
          'name': 'fs',
          'command': 'npx',
          'args': ['-y', 'server'],
          'env': [
            {'name': 'KEY', 'value': 'v'},
          ],
        },
      ]);
      expect(
        acpMcpServers({
          'web': {'url': 'https://mcp.example/mcp'},
        }, http: true).single['type'],
        'http',
      );
    });
  });

  group('profiles', () {
    test('Gemini pins its ACP flag and asking mode, whatever the command says', () {
      expect(acpCommand('gemini', ['--acp']).args, ['--acp', '--approval-mode', 'default']);
      expect(acpCommand('gemini', ['--yolo', '--approval-mode', 'yolo', '-m', 'x']).args, [
        '--acp',
        '--approval-mode',
        'default',
        '-m',
        'x',
      ]);
      expect(acpCommand('/opt/bin/gemini', ['--approval-mode=auto_edit']).args, [
        '--acp',
        '--approval-mode',
        'default',
      ]);
      expect(addArgs(['--acp', '--approval-mode', 'default'], ['--acp', '--include-directories', '/s']), [
        '--acp',
        '--approval-mode',
        'default',
        '--include-directories',
        '/s',
      ]);
    });

    test('a command with spaces is split into words; OpenCode gets its acp subcommand', () {
      final dsh = acpCommand('dsh --profile acp', const []);
      expect((dsh.executable, dsh.profile.agent), ('dsh', AcpAgent.generic));
      expect(dsh.args, ['--profile', 'acp']);
      final oc = acpCommand('opencode', const []);
      expect((oc.executable, oc.profile.agent), ('opencode', AcpAgent.openCode));
      expect(oc.args, ['acp']);
    });

    test("OpenCode's permission rules go into its inline config, next to the briefing's", () {
      final env = withOpenCodePermissions({'OPENCODE_CONFIG_CONTENT': '{"mcp":{"servers":{}}}', 'X': '1'});
      expect(env['X'], '1');
      expect(env['OPENCODE_CONFIG_CONTENT'], contains('"mcp"'));
      expect(env['OPENCODE_CONFIG_CONTENT'], contains('"permission":{"*":"ask"'));
    });
  });
}
