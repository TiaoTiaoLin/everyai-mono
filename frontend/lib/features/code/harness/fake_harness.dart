import 'dart:async';
import 'dart:convert';

import '../domain/agent_mode.dart';
import '../domain/rewind.dart';
import '../domain/subagents.dart';
import 'events.dart';
import 'harness.dart';

/// Replays scripted agent turns, for building and testing the Code UI without
/// the agent server. Each user message plays the next turn; actions wait for
/// [respond] the way the server's AlwaysConfirm policy does; the
/// `ask_user_question` and `run_subagent` client tools end the turn until the answer
/// or the reports arrive. Subagent conversations play [subagentTurns].
final class FakeHarness implements Harness {
  FakeHarness({
    List<List<Map<String, Object?>>>? turns,
    List<List<Map<String, Object?>>>? subagentTurns,
    this.step = const Duration(milliseconds: 350),
  }) : turns = turns ?? demoTurns,
       subagentTurns = subagentTurns ?? demoSubagentTurns;

  final List<List<Map<String, Object?>>> turns;
  final List<List<Map<String, Object?>>> subagentTurns;
  final Duration step;
  int _ids = 0;

  /// `model@effort` of each `switchLlm` on any of its sessions.
  final switched = <String>[];

  /// The head of each `rewindTo` on any of its sessions.
  final rewinds = <String?>[];

  @override
  Future<HarnessSession> start(SessionSpec spec) async {
    final s = FakeSession(this, 'fake-${++_ids}', spec.mode, spec.subagent ? subagentTurns : turns);
    if (spec.initialMessage case final text?) unawaited(s.send(text, run: spec.runInitial));
    return s;
  }

  @override
  Future<HarnessSession> attach(String conversationId) async => FakeSession(this, conversationId, AgentMode.ask, turns);

  @override
  Future<Map<String, ExecutionStatus>> statuses(List<String> conversationIds) async => const {};
}

final class FakeSession implements HarnessSession {
  FakeSession(this._h, this.id, this._mode, this._turns);

  final FakeHarness _h;
  final List<List<Map<String, Object?>>> _turns;
  @override
  final String id;
  AgentMode _mode;

  final _events = StreamController<HarnessEvent>.broadcast();
  final _history = <HarnessEvent>[];
  int _turn = 0;
  int _seq = 0;

  /// The conversation's head: the parent of the next event, as on the server.
  String? _leaf;
  Completer<bool>? _approval;
  bool _interrupted = false;
  bool _running = false;
  final _queue = <String>[];

  /// History first, then live events (like `resend_mode=all`).
  @override
  Stream<HarnessEvent> get events async* {
    yield* Stream.fromIterable(List.of(_history));
    yield* _events.stream;
  }

  HarnessEvent _emit(Map<String, Object?> json) {
    final delta = json['kind'] == 'StreamingDeltaEvent';
    final event = HarnessEvent.decode({'id': delta ? null : 'e${++_seq}', if (!delta) 'parent_id': _leaf, ...json});
    if (event is! StreamDelta) {
      _history.add(event);
      if (!isBranchArtifact(event)) _leaf = event.id;
    }
    if (!_events.isClosed) _events.add(event);
    return event;
  }

  void _status(ExecutionStatus s) =>
      _emit({'kind': 'ConversationStateUpdateEvent', 'key': 'execution_status', 'value': s.wire});

  @override
  Future<void> send(String text, {bool run = true, List<String> images = const []}) async {
    _emit({
      'kind': 'MessageEvent',
      'source': 'user',
      'llm_message': {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': text},
        ],
      },
    });
    if (_running) {
      _queue.add(text);
      return;
    }
    if (run) unawaited(_play());
  }

  Future<void> _play() async {
    if (_turn >= _turns.length) {
      _emit(_agentSays('That is everything in this demo session.'));
      _status(ExecutionStatus.finished);
      return;
    }
    _running = true;
    _interrupted = false;
    _status(ExecutionStatus.running);
    final script = _turns[_turn++];
    var endedByQuestion = false;
    for (final raw in script) {
      if (_interrupted) break;
      await Future<void>.delayed(_h.step);
      if (raw['kind'] == 'ActionEvent') {
        final call = _emit(raw) as ActionCall;
        if (_mode != AgentMode.fullAuto && _mode != AgentMode.bypass) {
          _status(ExecutionStatus.waitingForConfirmation);
          final ok = await (_approval = Completer<bool>()).future;
          _approval = null;
          if (!ok) {
            _emit({
              'kind': 'UserRejectObservation',
              'action_id': call.id,
              'tool_name': call.toolName,
              'tool_call_id': call.toolCallId,
              'rejection_reason': 'Rejected by the user',
            });
            _status(ExecutionStatus.idle);
            break;
          }
          _status(ExecutionStatus.running);
        }
        if (call.toolName == askUserQuestionTool || call.toolName == taskTool) {
          _emit({
            'kind': 'ObservationEvent',
            'action_id': call.id,
            'tool_name': call.toolName,
            'tool_call_id': call.toolCallId,
            'observation': {'kind': 'ClientToolObservation', 'content': <Object?>[]},
          });
          endedByQuestion = true;
          break;
        }
        continue;
      }
      if (raw['kind'] == 'ObservationEvent') {
        // Observations answer the most recent action.
        final action = _history.whereType<ActionCall>().last;
        _emit({...raw, 'action_id': action.id, 'tool_call_id': action.toolCallId, 'tool_name': action.toolName});
        continue;
      }
      if (raw['kind'] == 'MessageEvent' && raw['stream'] == true) {
        final text = HarnessEvent.contentText(raw['llm_message']! as Map<String, Object?>);
        for (final word in text.split(' ')) {
          if (_interrupted) break;
          _emit({'kind': 'StreamingDeltaEvent', 'content': '$word '});
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
      }
      _emit(raw);
    }
    _running = false;
    _status(endedByQuestion || _interrupted ? ExecutionStatus.idle : ExecutionStatus.finished);
    if (_queue.isNotEmpty) {
      _queue.removeAt(0);
      unawaited(_play());
    }
  }

  @override
  Future<void> respond({required bool accept, String? reason, List<String>? callIds}) async =>
      _approval?.complete(accept);

  @override
  Future<void> interrupt() async {
    _interrupted = true;
    _approval?.complete(false);
  }

  @override
  Future<void> pause() => interrupt();

  @override
  Future<void> resume() async {
    if (!_running) unawaited(_play());
  }

  @override
  Future<void> setMode(AgentMode mode, {bool holdClientTools = false}) async => _mode = mode;

  /// Recorded on the harness; the script plays the same either way.
  @override
  Future<void> switchLlm(SessionSpec spec) async => _h.switched.add('${spec.model}@${spec.effort ?? ''}');

  /// Like the server's `navigate`; the script carries on after the turns that are left.
  @override
  Future<void> rewindTo(String? head) async {
    final kept = rewound(_history, head);
    _history
      ..clear()
      ..addAll(kept);
    _leaf = head;
    _turn = kept.whereType<ChatMessage>().where((m) => m.fromUser).length.clamp(0, _turns.length);
    _h.rewinds.add(head);
  }

  @override
  Future<void> close() => _events.close();
}

Map<String, Object?> _agentSays(String text, {bool stream = false}) => {
  'kind': 'MessageEvent',
  'source': 'agent',
  'stream': stream,
  'llm_message': {
    'role': 'assistant',
    'content': [
      {'type': 'text', 'text': text},
    ],
  },
};

Map<String, Object?> _action(String tool, Map<String, Object?> action, {String thought = '', String? args}) => {
  'kind': 'ActionEvent',
  'tool_name': tool,
  'tool_call_id': 'call_${tool}_${action.hashCode.toUnsigned(20)}',
  'thought': [
    if (thought.isNotEmpty) {'type': 'text', 'text': thought},
  ],
  'action': action,
  'tool_call': {'id': 'c', 'name': tool, 'arguments': args ?? jsonEncode(action), 'origin': 'completion'},
  'llm_response_id': 'r',
};

Map<String, Object?> _observation(Map<String, Object?> observation) => {
  'kind': 'ObservationEvent',
  'observation': observation,
};

Map<String, Object?> _text(String s) => {'type': 'text', 'text': s};

/// A small, realistic session: explore, plan, ask, edit, test, delegate.
final demoTurns = <List<Map<String, Object?>>>[
  [
    _action('file_editor', {
      'kind': 'FileEditorAction',
      'command': 'view',
      'path': 'lib/counter.dart',
    }, thought: "I'll look at the counter first."),
    _observation({
      'kind': 'FileEditorObservation',
      'command': 'view',
      'path': 'lib/counter.dart',
      'content': [_text('class Counter {\n  int value = 0;\n  void increment() => value++;\n}')],
    }),
    _action('terminal', {'kind': 'TerminalAction', 'command': 'grep -rn "Counter(" lib test'}),
    _observation({
      'kind': 'TerminalObservation',
      'command': 'grep -rn "Counter(" lib test',
      'exit_code': 0,
      'content': [
        _text('lib/main.dart:12:  final counter = Counter();\ntest/counter_test.dart:5:    final c = Counter();'),
      ],
    }),
    _action('task_tracker', {
      'kind': 'TaskTrackerAction',
      'command': 'plan',
      'task_list': [
        {'title': 'Add decrement() that stops at zero', 'status': 'in_progress'},
        {'title': 'Cover it with a test', 'status': 'todo'},
        {'title': 'Run the test suite', 'status': 'todo'},
      ],
    }),
    _observation({
      'kind': 'TaskTrackerObservation',
      'content': [_text('Plan updated.')],
    }),
    _action(
      askUserQuestionTool,
      {},
      args: jsonEncode({
        'questions': [
          {
            'header': 'Floor',
            'question': 'What should decrement() do at zero?',
            'options': [
              {'label': 'Stay at zero', 'description': 'Ignore the call'},
              {'label': 'Throw', 'description': 'StateError when already zero'},
              {'label': 'Go negative', 'description': 'No floor at all'},
            ],
          },
          {
            'header': 'Extras',
            'question': 'Which extras should I add while I am here?',
            'multi_select': true,
            'options': [
              {'label': 'reset()', 'description': 'Set the value back to zero'},
              {'label': 'toString()', 'description': 'Readable debug output'},
              {'label': 'Doc comments', 'description': 'Document the public API'},
            ],
          },
        ],
      }),
    ),
  ],
  [
    _agentSays('Got it. Making the change now.'),
    _action('file_editor', {
      'kind': 'FileEditorAction',
      'command': 'str_replace',
      'path': 'lib/counter.dart',
      'old_str': '  void increment() => value++;',
      'new_str': '  void increment() => value++;\n\n  /// Decreases [value], never below zero.\n  void decrement() {\n    if (value > 0) value--;\n  }\n\n  void reset() => value = 0;',
    }, thought: 'Adding decrement() with a zero floor, plus reset().'),
    _observation({
      'kind': 'FileEditorObservation',
      'command': 'str_replace',
      'path': 'lib/counter.dart',
      'old_content': 'class Counter {\n  int value = 0;\n  void increment() => value++;\n}\n',
      'new_content': 'class Counter {\n  int value = 0;\n  void increment() => value++;\n\n  /// Decreases [value], never below zero.\n  void decrement() {\n    if (value > 0) value--;\n  }\n\n  void reset() => value = 0;\n}\n',
    }),
    _action(
      taskTool,
      {},
      thought: 'A subagent can write the tests while I review the change.',
      args: jsonEncode({
        'description': 'Write Counter tests',
        'prompt':
            'Add tests for Counter.decrement() and Counter.reset() to test/counter_test.dart: decrement lowers the '
            'value, stops at zero, and reset() sets it back to zero. Run the file with flutter test and report the '
            'tests you added and the result.',
      }),
    ),
  ],
  [
    _action('terminal', {'kind': 'TerminalAction', 'command': 'flutter test test/counter_test.dart'}),
    _observation({
      'kind': 'TerminalObservation',
      'command': 'flutter test test/counter_test.dart',
      'exit_code': 0,
      'content': [_text('00:01 +4: All tests passed!')],
    }),
    _action('task_tracker', {
      'kind': 'TaskTrackerAction',
      'command': 'plan',
      'task_list': [
        {'title': 'Add decrement() that stops at zero', 'status': 'done'},
        {'title': 'Cover it with a test', 'status': 'done'},
        {'title': 'Run the test suite', 'status': 'done'},
      ],
    }),
    _observation({
      'kind': 'TaskTrackerObservation',
      'content': [_text('Plan updated.')],
    }),
    _agentSays(
      '`Counter` now has `decrement()`, which stops at zero, and `reset()`. A subagent added three tests, '
      'and `flutter test` passes (4 tests).',
      stream: true,
    ),
  ],
];

/// The demo's subagent: reads the test file, adds tests, runs them, reports.
final demoSubagentTurns = <List<Map<String, Object?>>>[
  [
    _action('file_editor', {
      'kind': 'FileEditorAction',
      'command': 'view',
      'path': 'test/counter_test.dart',
    }, thought: 'Reading the existing tests first.'),
    _observation({
      'kind': 'FileEditorObservation',
      'command': 'view',
      'path': 'test/counter_test.dart',
      'content': [
        _text("test('increments', () {\n  final c = Counter();\n  c.increment();\n  expect(c.value, 1);\n});"),
      ],
    }),
    _action('file_editor', {
      'kind': 'FileEditorAction',
      'command': 'str_replace',
      'path': 'test/counter_test.dart',
      'old_str': '  expect(c.value, 1);\n});',
      'new_str':
          "  expect(c.value, 1);\n});\n\ntest('decrements', () {\n  final c = Counter()..increment()..decrement();\n  "
          "expect(c.value, 0);\n});\n\ntest('stops at zero', () {\n  final c = Counter()..decrement();\n  "
          "expect(c.value, 0);\n});\n\ntest('resets', () {\n  final c = Counter()..increment()..reset();\n  "
          'expect(c.value, 0);\n});',
    }),
    _observation({
      'kind': 'FileEditorObservation',
      'command': 'str_replace',
      'path': 'test/counter_test.dart',
      'old_content': "test('increments', () {\n  final c = Counter();\n  c.increment();\n  expect(c.value, 1);\n});\n",
      'new_content':
          "test('increments', () {\n  final c = Counter();\n  c.increment();\n  expect(c.value, 1);\n});\n\n"
          "test('decrements', () {\n  final c = Counter()..increment()..decrement();\n  expect(c.value, 0);\n});\n\n"
          "test('stops at zero', () {\n  final c = Counter()..decrement();\n  expect(c.value, 0);\n});\n\n"
          "test('resets', () {\n  final c = Counter()..increment()..reset();\n  expect(c.value, 0);\n});\n",
    }),
    _action('terminal', {'kind': 'TerminalAction', 'command': 'flutter test test/counter_test.dart'}),
    _observation({
      'kind': 'TerminalObservation',
      'command': 'flutter test test/counter_test.dart',
      'exit_code': 0,
      'content': [_text('00:01 +4: All tests passed!')],
    }),
    _agentSays(
      'Added three tests to test/counter_test.dart: decrements, stops at zero, and resets. '
      '`flutter test test/counter_test.dart` passes (4 tests).',
    ),
  ],
];
