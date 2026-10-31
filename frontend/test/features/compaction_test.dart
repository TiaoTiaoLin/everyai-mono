import 'dart:convert';
import 'dart:io';

import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/domain/compaction.dart';
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:every_ai/features/code/harness/openhands_harness.dart';
import 'package:every_ai/features/code/harness/summarizer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

var _ids = 0;

ChatMessage _user(String text) => ChatMessage(id: 'u${_ids++}', raw: const {}, fromUser: true, text: text);
ChatMessage _agent(String text) => ChatMessage(id: 'a${_ids++}', raw: const {}, fromUser: false, text: text);

(ActionCall, ToolResult) _run(String command, String output) {
  final id = 'c${_ids++}';
  return (
    ActionCall(
      id: id,
      raw: const {},
      toolName: 'terminal',
      toolCallId: 't$id',
      action: {'kind': 'TerminalAction', 'command': command},
    ),
    ToolResult(
      id: 'r$id',
      raw: const {},
      actionId: id,
      toolName: 'terminal',
      observation: {
        'content': [
          {'type': 'text', 'text': output},
        ],
      },
      outcome: ToolOutcome.ok,
    ),
  );
}

List<HarnessEvent> _turn(String ask, List<(String, String)> runs, String reply) => [
  _user(ask),
  for (final (cmd, out) in runs)
    ...switch (_run(cmd, out)) {
      (final call, final result) => [call, result],
    },
  _agent(reply),
];

const _summary = '''## Objective
- Add a counter.

## Important details
- none

## Work state
### Done
- lib/counter.dart written
### In progress
- none
### Blocked
- none

## Next move
1. Run the tests.

## Relevant files
- lib/counter.dart: the counter''';

void main() {
  group('planCompaction', () {
    test('keeps the newest whole turns and summarizes the rest', () {
      final events = [
        ..._turn('first ask', [('ls', 'a\nb')], 'did one'),
        const StateChange(id: 's', raw: {}, executionStatus: ExecutionStatus.idle, key: 'execution_status'),
        ..._turn('second ask', [('cat a', 'x' * 100)], 'did two'),
        ..._turn('third ask', [('dart test', 'ok')], 'did three'),
      ];
      final plan = planCompaction(events, budget: const CompactionBudget(tail: 200))!;
      expect((plan.tail.first as ChatMessage).text, 'third ask');
      expect((plan.head.first as ChatMessage).text, 'first ask');
      expect(plan.head.whereType<StateChange>(), isEmpty);
      expect(renderTail(plan), contains('[tool call terminal]\n{"command":"dart test"}'));
    });

    test('a single long turn keeps its newest steps', () {
      final events = _turn('one ask', [for (var i = 0; i < 20; i++) ('step $i', 'o' * 200)], 'done');
      final plan = planCompaction(events, budget: const CompactionBudget(tail: 1500))!;
      expect(plan.head.first, isA<ChatMessage>());
      expect(plan.tail.first, isNot(isA<ToolResult>()), reason: 'a call is never split from its result');
      expect(plan.tail.last, isA<ChatMessage>());
    });

    test('a short conversation still summarizes its first turn', () {
      final events = [..._turn('a', [], 'b'), ..._turn('c', [], 'd')];
      final plan = planCompaction(events)!;
      expect(plan.head, hasLength(2));
      expect(plan.tail, hasLength(2));
    });

    test('nothing to compact', () {
      expect(planCompaction(const []), isNull);
      expect(
        planCompaction([const StateChange(id: 's', raw: {}, executionStatus: ExecutionStatus.idle, key: '')]),
        isNull,
      );
    });

    test('merges the previous summary and the turns it kept', () {
      final first = modeNote(AgentMode.ask, continuationMessage(summary: _summary, recent: '[user]\nold ask'));
      final events = [_user(first), ..._turn('next', [], 'ok'), ..._turn('later', [], 'fine')];
      final plan = planCompaction(events)!;
      expect(plan.previousSummary, _summary);
      expect(plan.carried, '[user]\nold ask');
      expect((plan.head.first as ChatMessage).text, 'next');
      final request = summaryRequest(plan, focus: 'the test names');
      final user = request.last['content']! as String;
      expect(user, contains('<previous-summary>\n$_summary'));
      expect(user, contains('[turns kept from before the previous summary]\n[user]\nold ask'));
      expect(user, contains('keep this in particular: the test names'));
      for (final h in summarySections) {
        expect(user, contains('## $h'));
      }
    });
  });

  group('pruning', () {
    test('clears old tool output and cuts the newer output short', () {
      final events = [
        ..._turn('a', [('old', 'OLD' * 400)], 'x'),
        ..._turn('b', [('new', 'NEW' * 400)], 'y'),
        ..._turn('c', [], 'z'),
      ];
      final plan = planCompaction(events, budget: const CompactionBudget(tail: 20))!;
      final text = prunedHead(plan, budget: const CompactionBudget(protectedOutput: 1000, outputCap: 1000));
      expect(text, contains('[result of terminal]\n$clearedOutput'));
      expect(text, contains('NEWNEW'));
      expect(text, isNot(contains('OLDOLD')));
      expect(text, contains('characters cut'));
      // Mode and context notes are not the user's words.
      expect(text, isNot(contains('everyai-mode')));
    });

    test('drops the oldest part past the input budget', () {
      final events = [for (var i = 0; i < 30; i++) ..._turn('ask $i ${'w' * 100}', [], 'ok')];
      final plan = planCompaction(events, budget: const CompactionBudget(tail: 10))!;
      final text = prunedHead(plan, budget: const CompactionBudget(input: 500));
      expect(text, startsWith('[earlier steps omitted]'));
      expect(text.length, lessThan(560));
      expect(text, contains('ask 28'));
    });
  });

  group('summary', () {
    test('cleanSummary unwraps fences and rejects non-summaries', () {
      expect(cleanSummary('```markdown\n$_summary\n```'), _summary);
      expect(cleanSummary('  $_summary  '), _summary);
      expect(cleanSummary(''), isNull);
      expect(cleanSummary('I will continue the task now.'), isNull);
    });

    test('the continuation message round-trips and shows as a notice', () {
      final text = continuationMessage(summary: _summary, recent: '[user]\nkeep me');
      expect(splitCompacted(text), (summary: _summary, recent: '[user]\nkeep me'));
      expect(text, isNot(contains('Carry on')));
      expect(continuationMessage(summary: _summary, recent: '', resume: true), contains('Carry on'));
      expect(splitCompacted('hello'), isNull);

      final b = TranscriptBuilder()..add(_user(modeNote(AgentMode.plan, text)));
      final t = b.snapshot;
      expect(t.items.single, isA<NoticeItem>());
      final notice = t.items.single as NoticeItem;
      expect(notice.message, contextCompactedNotice);
      expect(notice.detail, _summary);
      expect(t.notedMode, AgentMode.plan);
      expect(t.items.whereType<UserTurn>(), isEmpty);
    });

    test('the gateway summarizer calls chat/completions billed to the session', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final seen = <String, Object?>{};
      server.listen((req) async {
        seen['path'] = req.uri.path;
        seen['auth'] = req.headers.value('authorization');
        seen['session'] = req.headers.value('x-everyai-session');
        seen['body'] = jsonDecode(await utf8.decodeStream(req));
        req.response.write(
          jsonEncode({
            'choices': [
              {
                'message': {'role': 'assistant', 'content': _summary},
              },
            ],
          }),
        );
        await req.response.close();
      });
      addTearDown(() => server.close(force: true));
      final summarize = gatewaySummarizer(
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        apiKey: 'sk-eai-test',
        sessionTag: 'session-1',
      );
      expect(
        await summarize([
          {'role': 'user', 'content': 'hi'},
        ]),
        _summary,
      );
      expect(seen['path'], '/v1/chat/completions');
      expect(seen['auth'], 'Bearer sk-eai-test');
      expect(seen['session'], 'session-1');
      expect((seen['body']! as Map)['model'], compactionModel);
    });
  });

  test('a continuation conversation starts without running the agent', () async {
    Map<String, Object?>? created;
    final client = MockClient((req) async {
      if (req.method == 'POST' && req.url.path == '/api/conversations') {
        created = jsonDecode(req.body) as Map<String, Object?>;
        return http.Response(jsonEncode({'id': 'conv-2'}), 200);
      }
      return http.Response('{"detail":"Not Found"}', 404);
    });
    final h = OpenHandsHarness(baseUrl: Uri.parse('http://127.0.0.1:1/'), sessionApiKey: 'k', client: client);
    await expectLater(
      h.start(
        const SessionSpec(
          workingDir: '/w',
          model: 'm',
          mode: AgentMode.ask,
          llmBaseUrl: 'http://x/v1',
          llmApiKey: 'k',
          sessionTag: 's',
          initialMessage: 'summary',
          runInitial: false,
        ),
      ),
      throwsA(isA<HarnessError>()),
    );
    expect((created!['initial_message']! as Map)['run'], false);
  });

  test('session info keeps the conversations it was compacted from', () {
    final info = CodeSessionInfo(
      id: 's',
      projectId: 'p',
      title: 't',
      conversationId: 'c1',
      model: 'm',
      mode: AgentMode.ask,
      workingDir: '/w',
      createdAt: DateTime(2026),
    );
    final moved = info.copyWith(conversationId: 'c2', compactedFrom: ['c1']);
    final back = CodeSessionInfo.fromJson(jsonDecode(jsonEncode(moved.toJson())) as Map<String, Object?>);
    expect(back.conversationId, 'c2');
    expect(back.compactedFrom, ['c1']);
    expect(CodeSessionInfo.fromJson(info.toJson()).compactedFrom, isEmpty);
  });

  group('clearOldToolOutput', () {
    List<Map<String, Object?>> history(int steps, {int size = 30000}) => [
      {'role': 'system', 'content': 'rules'},
      {'role': 'user', 'content': 'do it'},
      for (var i = 0; i < steps; i++) ...[
        {
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'id': 'c$i',
              'type': 'function',
              'function': {'name': i.isEven ? 'read' : 'bash', 'arguments': '{}'},
            },
          ],
        },
        {'role': 'tool', 'tool_call_id': 'c$i', 'content': 'x' * size},
      ],
    ];

    test('clears the oldest output down to the target, never the newest three steps', () {
      final messages = history(10);
      // 7 old results of 30K characters: about 52K tokens, over 40K.
      expect(clearOldToolOutput(messages), 5);
      final tools = messages.where((m) => m['role'] == 'tool').map((m) => m['content']! as String).toList();
      expect(tools.take(5), everyElement(startsWith('[output cleared to save context')));
      expect(tools[0], contains('re-run read'));
      expect(tools[1], contains('re-run bash'));
      expect(tools.skip(5), everyElement(hasLength(30000)));
      // Under the trigger now: nothing changes again (the cached prefix holds).
      expect(clearOldToolOutput(messages), 0);
    });

    test('outputs the work still needs are cleared last', () {
      final messages = history(10);
      expect(oldToolOutputs(messages).map((o) => o.callId), ['c0', 'c1', 'c2', 'c3', 'c4', 'c5', 'c6']);
      expect(clearOldToolOutput(messages, needed: {'c0', 'c2'}), 5);
      final tools = messages.where((m) => m['role'] == 'tool').map((m) => m['content']! as String).toList();
      expect(tools[0], hasLength(30000));
      expect(tools[2], hasLength(30000));
      for (final i in [1, 3, 4, 5, 6]) {
        expect(tools[i], startsWith('[output cleared'));
      }
      final q = neededQuestions(oldToolOutputs(history(10)).take(2).toList(), 'Fix the login bug');
      expect(q.questions.map((x) => x['id']), ['o0', 'o1']);
      expect(q.text, startsWith('<work-in-progress>\nFix the login bug'));
      expect(q.text, contains('<output n="1" tool="bash">'));
    });

    test('leaves the history alone under the trigger', () {
      final messages = history(8);
      final before = jsonEncode(messages);
      expect(clearOldToolOutput(messages), 0);
      expect(jsonEncode(messages), before);
    });
  });

  test('the continuation message carries the plan, todos, files and skills before the recent turns', () {
    final m = continuationMessage(
      summary: '## Objective\nx',
      recent: '[user]\nhi',
      plan: '# Plan',
      todos: '- [ ] one',
      files: '<file path="a">a</file>',
      skills: '<skill path="s">s</skill>',
    );
    final order = ['<summary>', '<approved-plan>', '<todos>', '<files>', '<skills>', '<recent-turns>'];
    final at = [for (final t in order) m.indexOf(t)];
    expect(at, everyElement(greaterThanOrEqualTo(0)));
    expect([...at]..sort(), at);
    expect(splitCompacted(m)?.summary, '## Objective\nx');
    expect(continuationMessage(summary: 's', recent: ''), isNot(contains('<todos>')));
  });
}
