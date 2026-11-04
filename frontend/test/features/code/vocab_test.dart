import 'dart:io';

import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/compaction.dart' show userTextOf;
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/drivers/acp/acp_driver.dart';
import 'package:every_ai/features/code/drivers/acp/acp_mapping.dart';
import 'package:every_ai/features/code/drivers/briefing/recipes.dart' as recipes;
import 'package:every_ai/features/code/drivers/claude/claude_wire.dart' show claudeAction;
import 'package:every_ai/features/code/drivers/codex/codex_mapping.dart';
import 'package:every_ai/features/code/drivers/driver_events.dart';
import 'package:every_ai/features/code/drivers/opencode/opencode_events.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:every_ai/features/code/ui/transcript/transcript_items.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

Widget _host(Widget child) => m.MaterialApp(
  home: EveryThemeScope(
    theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light),
    child: m.Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

ActionCall _claude(String id, String tool, Map<String, Object?> input) {
  final a = claudeAction(tool, input);
  return actionEvent(id: id, toolName: tool, kind: a.kind, args: a.args);
}

List<TranscriptItem> _fold(Iterable<HarnessEvent> events) {
  final b = TranscriptBuilder();
  events.forEach(b.add);
  return b.snapshot.items;
}

void main() {
  group('tool names', () {
    test('outside calls keep the harness name and are marked native; ours are not', () {
      final bash = _claude('a', 'Bash', {'command': 'ls'});
      expect(bash.toolName, 'Bash');
      expect(bash.native, isTrue);
      expect(bash.nativeName, 'Bash');
      expect(actionEvent(id: 'b', toolName: 'acp:edit', kind: 'FileEditorAction').nativeName, 'edit');
      expect(_claude('c', 'Read', {'file_path': '/x'}).nativeName, 'Read');
      final ours = HarnessEvent.decode({
        'kind': 'ActionEvent',
        'id': 'd',
        'tool_name': 'terminal',
        'tool_call_id': 'd',
        'action': {'kind': 'TerminalAction', 'command': 'ls'},
      }) as ActionCall;
      expect(ours.native, isFalse);
      expect(ours.nativeName, '');
    });

    testWidgets('the row shows the native name before our title, and only for outside calls', (tester) async {
      final outside = _claude('a', 'Bash', {'command': 'git status'});
      final ours = HarnessEvent.decode({
        'kind': 'ActionEvent',
        'id': 'd',
        'tool_name': 'terminal',
        'tool_call_id': 'd',
        'action': {'kind': 'TerminalAction', 'command': 'git log'},
      }) as ActionCall;
      late BuildContext ctx;
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (c) {
              ctx = c;
              return const SizedBox();
            },
          ),
        ),
      );
      expect(stepTitleSpan(ctx, outside, const TextStyle()).toPlainText(), startsWith('Bash  '));
      expect(stepTitleSpan(ctx, ours, const TextStyle()).toPlainText(), isNot(contains('terminal')));
      expect(
        approvalTitle(actionEvent(id: 'x', toolName: 'acp:update_todos', kind: 'AcpToolAction')),
        'Allow update_todos?',
      );
    });
  });

  group('todos', () {
    PlanItem plan(ActionCall c) => _fold([c]).whereType<PlanItem>().single;

    test('Claude TodoWrite keeps status and the in-progress wording', () {
      final item = plan(
        _claude('t', 'TodoWrite', {
          'todos': [
            {'content': 'Run tests', 'status': 'in_progress', 'activeForm': 'Running tests'},
            {'content': 'Ship', 'status': 'pending'},
          ],
        }),
      );
      expect(item.tasks.map((t) => t.status), ['in_progress', 'todo']);
      expect(item.tasks.first.active, 'Running tests');
    });

    test('OpenCode todowrite is no longer dropped: statuses, priority and the cancelled note', () {
      final events = OpenCodeMapper(workingDir: '/w').history([
        {
          'id': 'm1',
          'type': 'assistant',
          'content': [
            {
              'type': 'tool',
              'id': 'call_1',
              'name': 'todowrite',
              'state': {
                'status': 'completed',
                'input': {
                  'todos': [
                    {'content': 'A', 'status': 'completed', 'priority': 'high'},
                    {'content': 'B', 'status': 'in_progress', 'priority': 'medium'},
                    {'content': 'C', 'status': 'cancelled', 'priority': 'low'},
                    {'content': 'D', 'status': 'pending', 'priority': 'low'},
                  ],
                },
                'content': <Object?>[],
              },
            },
          ],
        },
      ]);
      final call = events.whereType<ActionCall>().single;
      expect(call.toolName, 'todowrite');
      final item = plan(call);
      expect(item.tasks.map((t) => t.status), ['done', 'in_progress', 'done', 'todo']);
      expect(item.tasks.map((t) => t.priority), ['high', 'medium', 'low', 'low']);
      expect(item.tasks[2].notes, 'cancelled');
    });

    test('ACP plan entries keep priority', () {
      final (call, _) = acpPlanEvents([
        {'content': 'A', 'status': 'pending', 'priority': 'high'},
      ], id: 'p');
      expect(plan(call).tasks.single.priority, 'high');
    });

    test('Codex update_plan keeps its name and statuses', () {
      final call = planCall('u', {
        'plan': [
          {'step': 'One', 'status': 'inProgress'},
          {'step': 'Two', 'status': 'completed'},
        ],
      });
      expect(call.toolName, 'update_plan');
      expect(plan(call).tasks.map((t) => t.status), ['in_progress', 'done']);
    });

    testWidgets('the plan shows priority, notes and the in-progress wording', (tester) async {
      await tester.pumpWidget(
        _host(
          const PlanView(
            tasks: [
              PlanTask('Run tests', 'in_progress', '', 'high', 'Running tests'),
              PlanTask('Old', 'done', 'cancelled'),
            ],
          ),
        ),
      );
      expect(find.text('Running tests'), findsOneWidget);
      expect(find.text('high'), findsOneWidget);
      expect(find.text('cancelled'), findsOneWidget);
    });
  });

  group('plan text', () {
    test('Claude ExitPlanMode, Codex plan items and Grok plans become a plan card that never waits', () {
      final claude = _claude('e', 'ExitPlanMode', {'plan': '# Plan\n1. Do it'});
      final (codex, codexResult) = planTextEvents('c', toolName: 'plan', body: 'Steps');
      for (final call in [claude, codex]) {
        final item = _fold([call]).whereType<PlanProposal>().single;
        expect(item.shown, isTrue);
        expect(item.body, isNotEmpty);
      }
      final b = TranscriptBuilder()
        ..add(codex)
        ..add(codexResult);
      expect(b.snapshot.openPlan, isNull);
      expect(b.snapshot.status, isNot(ExecutionStatus.waitingForConfirmation));
      expect(_fold(<HarnessEvent>[claude]).whereType<PlanProposal>().single.body, '# Plan\n1. Do it');
    });
  });

  group('thinking', () {
    test('reasoning stays on the message as sent', () {
      final reasoning = agentMessage('r', '', reasoning: 'Thinking it over');
      final item = _fold([reasoning]).whereType<AgentText>().single;
      expect(item.reasoning, 'Thinking it over');
    });
  });

  group('briefing row', () {
    test('the notice carries its detail through the lead timeline', () {
      final event = leadNoticeEvent(const NoticeItem('briefing-0', briefingNotice, detail: 'the exact text'));
      final item = _fold([event]).whereType<NoticeItem>().single;
      expect(item.message, briefingNotice);
      expect(item.detail, 'the exact text');
    });

    test('a briefing block is a row, never a user message', () {
      final (block, rest) = splitSessionBlock('<everyai-session>\nbrief\n</everyai-session>\n\nfix it');
      expect(block, 'brief');
      expect(rest, 'fix it');
      expect(splitSessionBlock('plain'), (null, 'plain'));
      expect(userTextOf('<everyai-session>\nbrief\n</everyai-session>\n\nfix it'), 'fix it');
      final user = HarnessEvent.decode({
        'kind': 'MessageEvent',
        'id': 'u',
        'source': 'user',
        'llm_message': {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': '<everyai-session>\nbrief\n</everyai-session>\n\nfix it'},
          ],
        },
      });
      final items = _fold([user]);
      expect(items.whereType<NoticeItem>().single.detail, 'brief');
      expect(items.whereType<UserTurn>().single.text, 'fix it');
    });

    test('an ACP agent without a skill route is shown the text it was sent, skills list included', () async {
      final dir = Directory.systemTemp.createTempSync('briefing');
      addTearDown(() => dir.deleteSync(recursive: true));
      final skills = Directory('${dir.path}/skills/demo')..createSync(recursive: true);
      File('${skills.path}/SKILL.md').writeAsStringSync('---\nname: demo\ndescription: Does a demo\n---\nBody\n');
      final b = DriverBriefing(
        mcpUrl: 'http://127.0.0.1:1/mcp',
        mcpToken: 'tok',
        skillDir: '${dir.path}/skills',
        sessionSkill: 'SESSION TEXT',
      );
      final shown = await AcpDriver(id: 'gemini', label: 'Gemini', command: 'gemini').briefingText(b);
      final sent = recipes
          .gemini(
            (mcpUrl: Uri.parse(b.mcpUrl), mcpToken: 'tok', skillDir: b.skillDir!, sessionText: 'SESSION TEXT'),
            skills: [(name: 'demo', description: 'Does a demo')],
          )
          .firstPrompt;
      expect(shown, sent);
      expect(shown, contains('demo'));
    });
  });
}
