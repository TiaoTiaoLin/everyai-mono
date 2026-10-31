import 'dart:async';
import 'dart:convert';

import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/domain/questions.dart';
import 'package:every_ai/features/code/domain/subagents.dart';
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/fake_harness.dart';
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:every_ai/features/code/settings/agent_prompt.dart';
import 'package:flutter_test/flutter_test.dart';

ActionCall _call(Map<String, Object?> action, {String tool = 'terminal'}) =>
    HarnessEvent.decode({'kind': 'ActionEvent', 'id': 'a', 'tool_name': tool, 'action': action}) as ActionCall;

SessionSpec _spec(AgentMode mode, [String? first = 'Add decrement']) => SessionSpec(
  workingDir: '/tmp/x',
  model: 'anthropic/claude-haiku-5.5',
  mode: mode,
  llmBaseUrl: '',
  llmApiKey: '',
  sessionTag: 's',
  initialMessage: first,
);

/// One subscription feeding a builder; [until] waits for a condition.
final class _Feed {
  _Feed(HarnessSession s) {
    _sub = s.events.listen((e) {
      builder.add(e);
      _check();
    });
  }

  final builder = TranscriptBuilder();
  late final StreamSubscription<HarnessEvent> _sub;
  bool Function(Transcript)? _cond;
  Completer<Transcript>? _done;

  void _check() {
    final cond = _cond;
    if (cond != null && cond(builder.snapshot)) {
      _cond = null;
      _done!.complete(builder.snapshot);
    }
  }

  Future<Transcript> until(bool Function(Transcript) cond) {
    _cond = cond;
    _done = Completer();
    _check();
    return _done!.future.timeout(const Duration(seconds: 5));
  }

  Future<void> cancel() => _sub.cancel();
}

void main() {
  group('events', () {
    test('decodes OpenHands frames tolerantly', () {
      final e = HarnessEvent.decodeFrame(
        '{"kind":"ActionEvent","id":"1","tool_name":"terminal","tool_call_id":"t","thought":[{"type":"text","text":"Hm"}],'
        '"action":{"kind":"TerminalAction","command":"ls"},"security_risk":"LOW","extra":42}',
      );
      expect(e, isA<ActionCall>().having((a) => a.str('command'), 'command', 'ls').having((a) => a.thought, 't', 'Hm'));
      final s = HarnessEvent.decode({
        'kind': 'ConversationStateUpdateEvent',
        'key': 'full_state',
        'value': {'execution_status': 'waiting_for_confirmation'},
      });
      expect((s as StateChange).executionStatus, ExecutionStatus.waitingForConfirmation);
      expect(HarnessEvent.decode({'kind': 'TokenEvent'}), isA<UnknownEvent>());
    });

    test('client tool arguments come from tool_call', () {
      final e = HarnessEvent.decode({
        'kind': 'ActionEvent',
        'tool_name': askUserQuestionTool,
        'tool_call': {'arguments': '{"questions":[{"question":"Q?","options":["A","B"]}]}'},
      }) as ActionCall;
      final qs = Question.listFrom(e.action);
      expect(qs.single.options.map((o) => o.label), ['A', 'B']);
    });
  });

  group('questions', () {
    const qs = [
      Question(question: 'Floor?', options: [QuestionOption('Zero', ''), QuestionOption('Throw', '')]),
      Question(
        question: 'Extras?',
        multiSelect: true,
        options: [QuestionOption('reset()', ''), QuestionOption('toString()', ''), QuestionOption('Docs', '')],
      ),
    ];

    test('answers round-trip through the message', () {
      final answers = [
        const QuestionAnswer(selected: {0}),
        const QuestionAnswer(selected: {2, 0}, other: 'and a test'),
      ];
      final text = answersMessage(qs, answers);
      expect(text, contains('1. Floor? → Zero'));
      expect(text, contains('2. Extras? → reset(), Docs, and a test'));
      expect(parseAnswers(text, qs), answers);
      expect(parseAnswers('Just a message', qs), isNull);
    });
  });

  group('modes', () {
    final view = _call({'kind': 'FileEditorAction', 'command': 'view', 'path': 'a'}, tool: 'file_editor');
    final edit = _call({'kind': 'FileEditorAction', 'command': 'str_replace', 'path': 'a'}, tool: 'file_editor');
    final ls = _call({'kind': 'TerminalAction', 'command': 'ls -la'});
    final sneaky = _call({'kind': 'TerminalAction', 'command': 'ls; rm -rf build'});
    final runTests = _call({'kind': 'TerminalAction', 'command': 'flutter test'});
    final ask = _call({}, tool: askUserQuestionTool);

    test('read-only detection follows every part of a chained command', () {
      expect(AgentMode.isReadOnly(ls), isTrue);
      expect(AgentMode.isReadOnly(sneaky), isFalse);
      expect(
        AgentMode.isReadOnly(_call({'kind': 'TerminalAction', 'command': 'cat a.dart; git log -3 | head'})),
        isTrue,
      );
      expect(AgentMode.isReadOnly(_call({'kind': 'TerminalAction', 'command': 'ls', 'is_input': true})), isFalse);
      expect(AgentMode.isReadOnly(view), isTrue);
      expect(AgentMode.isReadOnly(edit), isFalse);
    });

    test('each mode approves what it should', () {
      expect([view, edit, runTests, ask].map(AgentMode.ask.autoApproves), [true, false, false, true]);
      expect([view, edit, runTests, ask].map(AgentMode.autoEdit.autoApproves), [true, true, false, true]);
      expect([view, edit, runTests, ask].map(AgentMode.plan.rejects), [false, true, true, false]);
      expect([view, edit, runTests, ask].every(AgentMode.fullAuto.autoApproves), isTrue);
      final plan = _call({}, tool: presentPlanTool);
      expect(AgentMode.plan.autoApproves(plan) && !AgentMode.plan.rejects(plan), isTrue);
    });

    test('mode notes wrap a message and come back off it', () {
      final sent = modeNote(AgentMode.plan, 'Add a signup form');
      expect(sent, startsWith('<everyai-mode name="plan">Mode: Plan.'));
      expect(splitModeNote(sent), (AgentMode.plan, 'Add a signup form'));
      expect(splitModeNote('plain'), (null, 'plain'));
      // Later messages carry a one-line reminder that is hidden the same way.
      final short = modeNote(AgentMode.plan, 'more', full: false, from: AgentMode.plan);
      expect(short, contains(AgentMode.plan.reminder));
      expect(short.length, lessThan(sent.length));
      expect(splitModeNote(short), (AgentMode.plan, 'more'));
      // Leaving Plan says so.
      final left = modeNote(AgentMode.autoEdit, 'go', from: AgentMode.plan);
      expect(left, contains('You have left Plan mode'));
      expect(modeNote(AgentMode.ask, 'x', from: AgentMode.autoEdit), isNot(contains('left Plan')));
      // Every note releases the restrictions of the ones before it.
      for (final m in AgentMode.values.where((m) => m != AgentMode.plan)) {
        expect(m.instructions, contains('no longer apply'));
      }
    });
  });

  group('mode notes and plans in the transcript', () {
    HarnessEvent user(String id, String text) => HarnessEvent.decode({
      'kind': 'MessageEvent',
      'id': id,
      'source': 'user',
      'llm_message': {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': text},
        ],
      },
    });
    HarnessEvent proposal() => HarnessEvent.decode({
      'kind': 'ActionEvent',
      'id': 'p1',
      'tool_name': presentPlanTool,
      'action': {
        'title': 'Signup form',
        'steps': [
          {
            'title': 'Add the form widget',
            'files': ['lib/signup.dart'],
          },
          'Write tests',
        ],
        'risks': ['Date parsing'],
      },
    });

    test('the noted mode is tracked and the note is hidden from the turn', () {
      final b = TranscriptBuilder()..add(user('u1', modeNote(AgentMode.plan, 'Plan a form')));
      final turn = b.snapshot.items.single as UserTurn;
      expect((turn.text, turn.mode), ('Plan a form', AgentMode.plan));
      expect(b.snapshot.notedMode, AgentMode.plan);
      b.add(user('u2', 'more detail'));
      expect(b.snapshot.notedMode, AgentMode.plan);
      // A reminder of the same mode is hidden and adds no mode chip.
      b.add(user('u3', modeNote(AgentMode.plan, 'again', full: false)));
      final again = b.snapshot.items.whereType<UserTurn>().last;
      expect((again.text, again.mode), ('again', null));
    });

    test('a plan proposal waits, then Start building approves it', () {
      final b = TranscriptBuilder()
        ..add(user('u1', modeNote(AgentMode.plan, 'Plan a form')))
        ..add(proposal());
      final plan = b.snapshot.openPlan!;
      expect(plan.steps.map((s) => s.title), ['Add the form widget', 'Write tests']);
      expect(plan.steps.first.files, ['lib/signup.dart']);
      expect(plan.markdown, contains('1. Add the form widget'));
      b.add(user('u2', modeNote(AgentMode.autoEdit, planApprovedMessage)));
      expect(b.snapshot.openPlan, isNull);
      expect(b.snapshot.items.whereType<PlanProposal>().single.verdict, PlanVerdict.approved);
      expect(b.snapshot.notedMode, AgentMode.autoEdit);
    });

    test('feedback sends the plan back', () {
      final b = TranscriptBuilder()
        ..add(proposal())
        ..add(user('u2', 'Use a stepper instead'));
      expect(b.snapshot.items.whereType<PlanProposal>().single.verdict, PlanVerdict.revised);
    });
  });

  group('transcript', () {
    test('the demo session folds into grouped items and a question card', () async {
      final harness = FakeHarness(step: Duration.zero);
      final s = await harness.start(_spec(AgentMode.fullAuto));
      final feed = _Feed(s);
      var t = await feed.until((Transcript x) => x.openQuestion != null && x.status == ExecutionStatus.idle);

      expect(t.items.first, isA<UserTurn>());
      final explore = t.items.whereType<ExploreGroup>().single;
      expect(explore.steps, hasLength(2));
      expect(explore.steps.every((s) => s.done), isTrue);
      expect(exploreSummary(explore.steps), '1 file, 1 search');
      expect(t.plan.first.status, 'in_progress');
      final card = t.openQuestion!;
      expect(card.questions.map((q) => q.multiSelect), [false, true]);

      await s.send(
        answersMessage(card.questions, const [
          QuestionAnswer(selected: {0}),
          QuestionAnswer(selected: {0, 2}),
        ]),
      );
      // The turn ends at the subagent call; the app brings the report back.
      t = await feed.until((Transcript x) => x.openSubagents.isNotEmpty && x.status == ExecutionStatus.idle);
      final sub = t.openSubagents.single;
      expect(sub.task.description, 'Write Counter tests');
      await s.send(
        subagentMessage({sub.step.call.id: const SubagentReport(SubagentStatus.completed, 'Added 3 tests.')}),
      );
      t = await feed.until((Transcript x) => x.status == ExecutionStatus.finished);

      // The answers attach to the card instead of showing as a user turn.
      expect(t.items.whereType<UserTurn>(), hasLength(1));
      final answered = t.items.whereType<QuestionItem>().single;
      expect(answered.answers![1].selected, {0, 2});
      final edit = t.items.whereType<StepItem>().first.step;
      expect(stepTitle(edit.call), 'Edited lib/counter.dart');
      expect(edit.result!.observation['new_content'], contains('decrement'));
      expect(t.items.whereType<SubagentItem>().single.report!.text, 'Added 3 tests.');
      expect(t.plan.every((p) => p.status == 'done'), isTrue);
      expect((t.items.last as AgentText).text, contains('passes'));
      // Consecutive plan updates don't pile up.
      expect(t.items.whereType<PlanItem>(), hasLength(2));
      await feed.cancel();
      await s.close();
    });

    test('ask mode waits for approval and a denial stops the turn', () async {
      final harness = FakeHarness(step: Duration.zero);
      final s = await harness.start(_spec(AgentMode.ask));
      final feed = _Feed(s);
      var t = await feed.until((Transcript x) => x.pending.isNotEmpty);
      expect(stepTitle(t.pending.single), 'Read lib/counter.dart');

      await s.respond(accept: true);
      t = await feed.until((Transcript x) => x.pending.isNotEmpty && x.pending.single.toolName == 'terminal');
      await s.respond(accept: false);
      t = await feed.until((Transcript x) => x.status == ExecutionStatus.idle);
      expect(t.pending, isEmpty);
      await feed.cancel();
      await s.close();
    });

    test('plan updates wait for approval too', () async {
      final harness = FakeHarness(step: Duration.zero, turns: [demoTurns.first.sublist(4)]);
      final s = await harness.start(_spec(AgentMode.ask));
      final feed = _Feed(s);
      final t = await feed.until((Transcript x) => x.pending.isNotEmpty);
      expect(t.pending.single.actionKind, 'TaskTrackerAction');
      expect(AgentMode.ask.autoApproves(t.pending.single), isTrue);
      await feed.cancel();
      await s.close();
    });

    test('a denial is recorded on the step', () async {
      final harness = FakeHarness(step: Duration.zero);
      final s = await harness.start(_spec(AgentMode.ask));
      final feed = _Feed(s);
      var t = await feed.until((Transcript x) => x.pending.isNotEmpty);
      await s.respond(accept: true);
      t = await feed.until((Transcript x) => x.pending.any((c) => c.actionKind == 'TerminalAction'));
      await s.respond(accept: false);
      t = await feed.until((Transcript x) => x.status == ExecutionStatus.idle);
      final grep = t.items.whereType<ExploreGroup>().single.steps.last;
      expect(grep.rejected, isTrue);
      expect(t.pending, isEmpty);
      await feed.cancel();
      await s.close();
    });
  });

  group('question cards', () {
    HarnessEvent msg(String id, String source, String text) => HarnessEvent.decode({
      'kind': 'MessageEvent',
      'id': id,
      'source': source,
      'llm_message': {
        'role': source == 'user' ? 'user' : 'assistant',
        'content': [
          {'type': 'text', 'text': text},
        ],
      },
    });
    HarnessEvent state(String id, String status) => HarnessEvent.decode({
      'kind': 'ConversationStateUpdateEvent',
      'id': id,
      'key': 'execution_status',
      'value': status,
    });
    final questions = [
      for (final h in ['Platform', 'Review', 'Validation', 'Address'])
        {
          'question': 'Which $h?',
          'header': h,
          'options': [
            {'label': '$h A', 'description': 'first'},
            {'label': '$h B', 'description': 'second'},
          ],
        },
    ];
    HarnessEvent ask() => HarnessEvent.decode({
      'kind': 'ActionEvent',
      'id': 'q1',
      'tool_name': askUserQuestionTool,
      'tool_call_id': 'tc1',
      'action': {'kind': 'ClientToolAction'},
      'tool_call': {
        'name': askUserQuestionTool,
        'arguments': jsonEncode({'questions': questions}),
      },
    });
    HarnessEvent ack() => HarnessEvent.decode({
      'kind': 'ObservationEvent',
      'id': 'o1',
      'action_id': 'q1',
      'tool_call_id': 'tc1',
      'tool_name': askUserQuestionTool,
      'observation': {
        'kind': 'ClientToolObservation',
        'content': [
          {'type': 'text', 'text': 'Tool call dispatched to client.'},
        ],
      },
    });

    // The shape of the user's sessions: the card, the SDK's ack, the agent's
    // "I've asked four questions above", then finished.
    TranscriptBuilder asked() => TranscriptBuilder()
      ..add(msg('u1', 'user', 'Plan a signup form and ask me questions'))
      ..add(state('s1', 'running'))
      ..add(ask())
      ..add(ack())
      ..add(msg('m1', 'agent', "I've asked four questions above. I'll wait for your answers."))
      ..add(state('s2', 'finished'));

    test('a card stays open after the agent keeps talking and the turn ends', () {
      final t = asked().snapshot;
      expect(t.items.last, isA<AgentText>());
      expect(t.openQuestion?.questions, hasLength(4));
      expect(t.openQuestion!.questions.map((q) => q.header), ['Platform', 'Review', 'Validation', 'Address']);
    });

    test('answers from the card attach to it', () {
      final b = asked();
      final card = b.snapshot.openQuestion!;
      b.add(
        msg(
          'u2',
          'user',
          answersMessage(card.questions, [
            for (final _ in card.questions) const QuestionAnswer(selected: {1}),
          ]),
        ),
      );
      final t = b.snapshot;
      expect(t.openQuestion, isNull);
      expect(t.items.whereType<UserTurn>(), hasLength(1));
      expect(t.items.whereType<QuestionItem>().single.answers!.map((a) => a.selected), everyElement({1}));
    });

    test('a reply in the user\'s own words settles the card', () {
      final b = asked()..add(msg('u2', 'user', 'Web page, show a summary, all required'));
      final t = b.snapshot;
      expect(t.openQuestion, isNull);
      expect(t.items.whereType<QuestionItem>().single.answers, isEmpty);
      expect(t.items.last, isA<UserTurn>());
    });

    group('held in the call', () {
      HarnessEvent reject(String actionId, String reason) => HarnessEvent.decode({
        'kind': 'UserRejectObservation',
        'id': 'r-$actionId',
        'action_id': actionId,
        'tool_name': askUserQuestionTool,
        'rejection_reason': reason,
      });
      TranscriptBuilder held() => TranscriptBuilder()
        ..add(msg('u1', 'user', 'Plan a signup form and ask me questions'))
        ..add(state('s1', 'running'))
        ..add(ask())
        ..add(state('s2', 'waiting_for_confirmation'));

      test('a held card is not an approval: it waits as held, not pending', () {
        final t = held().snapshot;
        expect(t.pending, isEmpty);
        expect(t.held.single.toolName, askUserQuestionTool);
        expect(t.openQuestion, isNotNull);
      });

      test('answers given as the rejection reason attach to the card', () {
        final b = held();
        final card = b.snapshot.openQuestion!;
        b
          ..add(
            reject(
              'q1',
              answersReason(card.questions, [
                for (final _ in card.questions) const QuestionAnswer(selected: {1}),
              ]),
            ),
          )
          ..add(state('s3', 'running'));
        final t = b.snapshot;
        expect(t.held, isEmpty);
        expect(t.openQuestion, isNull);
        expect(t.items.whereType<UserTurn>(), hasLength(1));
        expect(t.items.whereType<QuestionItem>().single.answers!.map((a) => a.selected), everyElement({1}));
      });

      test('replying in chat closes the card with no answers', () {
        final b = held()..add(reject('q1', repliedInChat));
        expect(b.snapshot.items.whereType<QuestionItem>().single.answers, isEmpty);
      });

      test('a held plan is approved or revised by the reason', () {
        HarnessEvent plan(String id) => HarnessEvent.decode({
          'kind': 'ActionEvent',
          'id': id,
          'tool_name': presentPlanTool,
          'action': {
            'title': 'Form',
            'steps': ['Build it'],
          },
        });
        final b = TranscriptBuilder()
          ..add(plan('p1'))
          ..add(state('s1', 'waiting_for_confirmation'));
        expect(b.snapshot.held.single.id, 'p1');
        expect(b.snapshot.pending, isEmpty);
        b
          ..add(reject('p1', '$planRevisionLead use a stepper'))
          ..add(plan('p2'))
          ..add(reject('p2', planApprovedReason));
        expect(b.snapshot.items.whereType<PlanProposal>().map((p) => p.verdict), [
          PlanVerdict.revised,
          PlanVerdict.approved,
        ]);
      });

      test('held sessions register tools and rules that wait in the call', () {
        String desc(List<Map<String, Object?>> specs, String name) =>
            specs.firstWhere((s) => s['name'] == name)['description']! as String;
        for (final name in [askUserQuestionTool, presentPlanTool]) {
          expect(desc(clientToolSpecs(), name), contains('end your turn'));
          expect(desc(clientToolSpecs(held: true), name), isNot(contains('end your turn')));
          expect(desc(clientToolSpecs(held: true), name), contains('result'));
        }
        expect(forHeldClientTools(workingRules), isNot(contains('end your turn')));
        expect(forHeldClientTools(workingRules), contains('as its result'));
        // The app answers every action itself, so the floor holds in Full auto too.
        for (final m in AgentMode.values) {
          expect(m.confirmationPolicy()['kind'], 'AlwaysConfirm');
        }
        expect(
          parseAnswers(
            answersReason([
              Question.listFrom({'questions': questions}).first,
            ], const []),
            const [],
          ),
          isNotNull,
        );
      });

      test('the session remembers whether it holds client tools', () {
        final info = CodeSessionInfo(
          id: 's',
          projectId: 'p',
          title: 't',
          conversationId: 'c',
          model: 'm',
          mode: AgentMode.plan,
          workingDir: '/w',
          createdAt: DateTime(2026),
          holdClientTools: true,
        );
        expect(CodeSessionInfo.fromJson(info.toJson()).holdClientTools, isTrue);
        expect(CodeSessionInfo.fromJson({...info.toJson()}..remove('hold_client_tools')).holdClientTools, isFalse);
        expect(info.copyWith(title: 'x').holdClientTools, isTrue);
      });
    });
  });
}
