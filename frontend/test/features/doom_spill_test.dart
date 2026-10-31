import 'package:every_ai/features/code/domain/doom_loop.dart';
import 'package:every_ai/features/code/domain/questions.dart';
import 'package:every_ai/features/code/domain/spill.dart';
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/settings/agent_prompt.dart';
import 'package:flutter_test/flutter_test.dart';

ActionCall call(String id, String command, {String tool = 'terminal', String kind = 'TerminalAction'}) =>
    ActionCall(id: id, raw: const {}, toolName: tool, toolCallId: 'tc-$id', action: {'kind': kind, 'command': command});

ToolResult result(String text, {String id = 'r1'}) => ToolResult(
  id: id,
  raw: const {},
  actionId: 'a1',
  toolCallId: 'tc-a1',
  toolName: 'terminal',
  observation: {
    'content': [
      {'type': 'text', 'text': text},
    ],
  },
  outcome: ToolOutcome.ok,
);

void main() {
  group('DoomLoopDetector', () {
    test('fires on the third identical call in a row, once', () {
      final d = DoomLoopDetector();
      expect(d.add(call('1', 'flutter test')), isFalse);
      expect(d.add(call('2', 'flutter  test ')), isFalse);
      expect(d.add(call('3', 'flutter test')), isTrue);
      expect(d.looped?.id, '3');
      expect(d.add(call('4', 'flutter test')), isFalse);
    });

    test('a different step in between breaks the run', () {
      final d = DoomLoopDetector();
      d.add(call('1', 'ls'));
      d.add(call('2', 'ls'));
      d.add(call('3', 'pwd'));
      expect(d.add(call('4', 'ls')), isFalse);
    });

    test('a replayed call counts once, and the user speaking resets', () {
      final d = DoomLoopDetector();
      d.add(call('1', 'ls'));
      d.add(call('1', 'ls'));
      d.add(call('2', 'ls'));
      d.reset();
      expect(d.add(call('3', 'ls')), isFalse);
    });

    test('client tools and thinking never count', () {
      final d = DoomLoopDetector();
      for (var i = 0; i < 5; i++) {
        expect(d.add(call('t$i', '', kind: 'ThinkAction', tool: 'think')), isFalse);
      }
    });

    test('names the step', () {
      expect(loopedStep(call('1', 'dart   test\n--reporter=compact')), 'dart test --reporter=compact');
    });
  });

  group('local question card', () {
    test('settles without a tool call', () {
      final b = TranscriptBuilder();
      final card = call('doom-1', '', tool: 'ask_user_question', kind: '');
      b.addLocalQuestion(card, const [
        Question(question: 'q', options: [QuestionOption('a', '')]),
      ]);
      expect(b.snapshot.openQuestion, isNotNull);
      expect(b.snapshot.held, isEmpty);
      b.settleLocal('doom-1', [
        const QuestionAnswer(selected: {0}),
      ]);
      expect(b.snapshot.openQuestion, isNull);
    });
  });

  group('spill', () {
    test('short output is left alone', () {
      expect(spillOf(result(List.generate(100, (i) => 'line $i').join('\n'))), isNull);
    });

    test('over 2,000 lines is previewed', () {
      final text = List.generate(3000, (i) => 'l$i').join('\n');
      final s = spillOf(result(text))!;
      expect(s.lines, 3000);
      final p = spillPreview(s, '.everyai/spill/x.txt');
      expect(p, contains('l0\n'));
      expect(p, contains('l2999'));
      expect(p, isNot(contains('l1500\n')));
      expect(p, contains('.everyai/spill/x.txt'));
      expect(p.split('\n').length, lessThan(100));
    });

    test('over 50 KB in few lines is previewed within bounds', () {
      final s = spillOf(result('x' * 80000))!;
      expect(s.bytes, 80000);
      expect(spillPreview(s, 'p').length, lessThan(14000));
    });

    test('withPreview swaps the text the transcript shows', () {
      final r = withPreview(result('big'), 'small');
      expect(r.text, 'small');
      expect(r.toolCallId, 'tc-a1');
    });

    test('file names are safe', () {
      expect(Spill.fileName('a/b:c'), 'a_b_c.txt');
    });

    test('the agent is told long output is saved to a file', () {
      expect(workingRules, contains('saved to a file automatically'));
    });
  });
}
