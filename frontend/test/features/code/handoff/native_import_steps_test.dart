import 'dart:convert';

import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/drivers/driver_events.dart' show stateEvent;
import 'package:every_ai/features/code/handoff/handoff.dart';
import 'package:every_ai/features/code/handoff/native/import_steps.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:flutter_test/flutter_test.dart';

import 'native_source.dart';

String _show(ImportStep s) => switch (s) {
  UserStep(:final text, :final ours) => '${ours ? 'note' : 'user'}: ${text.split('\n').first}',
  AgentStep(:final text) => 'agent: $text',
  CallStep(:final kind, :final result, :final finished) => 'call $kind${finished ? '' : ' (unfinished)'}: $result',
};

/// The characters [steps] write: every text, call argument and result.
int _size(List<ImportStep> steps) => steps.fold(
  0,
  (n, s) =>
      n +
      switch (s) {
        UserStep(:final text) || AgentStep(:final text) => text.length,
        CallStep(:final args, :final result) => jsonEncode(args).length + result.length,
      },
);

void main() {
  test('both stints, oldest first, between the lead note and the handoff facts', () {
    final steps = importSteps(source(), into: 'Codex')!;
    expect(steps.map(_show), [
      'note: This conversation was led by EveryAI, Claude Code until now and was moved into Codex. Earlier tool calls '
          "use Codex's tool names where one matches; the others are written as text. The last request was stopped "
          'by a usage limit before it was done: the calls made for it so far are the last ones in this history.',
      'user: Please create hello.txt containing the word PINEAPPLE.',
      'call FileEditorAction: File created successfully at: /work/repo/hello.txt',
      'agent: Created hello.txt with PINEAPPLE.',
      'user: Now make bye.txt containing MANGO, then commit both files.',
      'call TerminalAction: (no output)',
      'call TerminalAction (unfinished): $notFinishedResult',
      'note: <everyai-handoff from="claude-code" kind="full">',
    ]);
    final create = steps[2] as CallStep;
    expect(create.args, {'command': 'create', 'path': '/work/repo/hello.txt', 'file_text': 'PINEAPPLE\n'});
    expect(importedTurns(steps), 2);
  });

  test('the cut turn round-trips: its calls, no closing reply, an error result, then the facts with <cut-turn>', () {
    final s = source();
    final steps = importSteps(s, into: 'Codex')!;
    expect(s.handoff.cut, isNotNull);
    final last = steps.last as UserStep;
    // The facts keep the cut request but not what the history above holds: the cut calls and the latest turns.
    expect(last.text, contains('<cut-turn>'));
    expect(last.text, contains('Now make bye.txt containing MANGO'));
    expect(last.text, contains('(2 earlier calls left out to keep this short; the transcript file has them.)'));
    expect(last.text, isNot(contains('<recent-turns>')));
    expect(last.text, isNot(contains('echo MANGO')));
    expect(handoffMessage(s.handoff, fromName: 'Claude Code'), contains('echo MANGO'));
    expect((steps.first as UserStep).text, contains('the calls made for it so far are the last ones'));
    expect(carryOnMessage('Claude Code', cut: true), contains('<cut-turn> above'));
    final before = steps[steps.length - 2] as CallStep;
    expect((before.finished, before.isError, before.result), (false, true, notFinishedResult));
    expect(steps.whereType<AgentStep>().map((a) => a.text), ['Created hello.txt with PINEAPPLE.']);
  });

  test('mode and handoff notes are stripped, carry-ons and harness notes dropped', () {
    final earlier = handoffMessage(handoffOf(stints(), to: 'everyai'));
    final steps = importSteps(
      source(
        from: [
          (lead: 'EveryAI', conversationId: 'c', events: everyaiStint()),
          (
            lead: 'Codex',
            conversationId: 'x',
            events: [
              user('u5', '$earlier\n\nAlso add a README.'),
              user('u6', carryOnMessage('EveryAI')),
              user(
                'u7',
                modeNote(AgentMode.plan, '<everyai-phase flow="max" phase="research" run="r">\nGo.\n</everyai-phase>'),
              ),
              agent('a5', 'README added.'),
            ],
          ),
        ],
      ),
      into: 'OpenCode',
    )!;
    final users = [
      for (final s in steps)
        if (s case UserStep(ours: false, :final text)) text,
    ];
    expect(users, ['Please create hello.txt containing the word PINEAPPLE.', 'Also add a README.']);
  });

  test('secrets: a .env read is withheld, a key in the user text redacted', () {
    final steps = importSteps(
      source(
        from: [
          (
            lead: 'EveryAI',
            conversationId: 'c',
            events: [
              user('u1', 'Use API_KEY=abcdef1234567890 for the client'),
              call('c1', 'terminal', {'kind': 'TerminalAction', 'command': 'cat .env'}),
              result('c1', 'OPENAI=whatever-value-123'),
              agent('a1', 'The token is sk-abcdefghijklmnopqrstuvwxyz'),
            ],
          ),
        ],
      ),
      into: 'Claude Code',
    )!;
    final all = steps.map(_show).join('\n');
    expect(all, contains('API_KEY=(redacted)'));
    expect(all, isNot(contains('abcdef1234567890')));
    expect(all, isNot(contains('whatever-value-123')));
    expect(all, isNot(contains('sk-abcdefghijklmnopqrstuvwxyz')));
  });

  test('caps: one result and one argument are cut, old turns give way with a note pointing at the transcript', () {
    final big = 'x' * (handoffTranscriptResultChars + 500);
    final turns = [
      for (var i = 0; i < 40; i++) ...[
        user('u$i', 'request $i'),
        call('c$i', 'file_editor', {
          'kind': 'FileEditorAction',
          'command': 'create',
          'path': '$cwd/f$i.txt',
          'file_text': 'y' * 9000,
        }),
        result('c$i', big),
        agent('a$i', 'done $i'),
        stateEvent('s$i', ExecutionStatus.finished),
      ],
    ];
    final steps = importSteps(source(from: [(lead: 'EveryAI', conversationId: 'c', events: turns)]), into: 'Codex')!;
    final calls = steps.whereType<CallStep>().toList();
    expect(calls.first.result.length, lessThan(handoffTranscriptResultChars + 100));
    expect(calls.first.str('file_text').length, lessThan(nativeImportArgChars + 100));
    expect(_size(steps), lessThan(nativeImportMaxChars));
    final dropped = 40 - importedTurns(steps);
    expect(dropped, greaterThan(0));
    expect(
      (steps[1] as UserStep).text,
      '($dropped earlier turns are left out to keep this short; the whole conversation is in .everyai/handoffs/x.md.)',
    );
    expect(steps.whereType<UserStep>().where((s) => !s.ours).last.text, 'request 39');
  });

  test('one long request: the oldest results give way, then the oldest calls; the request and newest calls stay', () {
    final events = [
      user('u', 'Fix every failing test.'),
      for (var i = 0; i < 200; i++) ...[
        agent('a$i', 'Step $i.'),
        call('c$i', 'terminal', {'kind': 'TerminalAction', 'command': 'run test $i ${'w' * 3000}'}),
        result('c$i', '${'z' * 7000} $i'),
      ],
    ];
    final steps = importSteps(source(from: [(lead: 'EveryAI', conversationId: 'c', events: events)]), into: 'Codex')!;
    expect(_size(steps), lessThan(nativeImportMaxChars));
    expect(importedTurns(steps), 1);
    expect(steps[1], isA<UserStep>().having((s) => s.text, 'text', 'Fix every failing test.'));
    final calls = steps.whereType<CallStep>().toList();
    expect(calls.last.str('command'), startsWith('run test 199 '));
    expect(calls.last.result, endsWith(' 199'));
    expect(
      calls.first.result,
      '(result left out to keep this short; the whole conversation is in .everyai/handoffs/x.md.)',
    );
    // Results gave way first: some calls still stand with no result, the rest are one note.
    final left = 200 - calls.length;
    expect(left, greaterThan(0));
    expect(steps[2], isA<AgentStep>().having((s) => s.text, 'text', startsWith('($left earlier calls are left out')));
    expect(steps.whereType<AgentStep>().where((s) => s.text.contains('left out')), hasLength(1));
  });

  test('a request too big alone: null, so the facts handoff is used', () {
    final steps = importSteps(
      source(
        from: [
          (lead: 'EveryAI', conversationId: 'c', events: [user('u', 'q' * (nativeImportMaxChars + 1))]),
        ],
      ),
      into: 'Codex',
    );
    expect(steps, isNull);
  });

  test('nothing the user asked: null', () {
    expect(
      importSteps(
        source(
          from: [
            (lead: 'EveryAI', conversationId: 'c', events: [agent('a', 'hi'), stateEvent('s', ExecutionStatus.idle)]),
          ],
        ),
        into: 'Codex',
      ),
      isNull,
    );
  });
}
