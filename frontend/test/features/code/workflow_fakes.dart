// Fakes for the workflow engine: a bridge the test plays the script on, a
// launcher whose children answer from a callback, and timers fired by hand.

import 'dart:async';

import 'package:every_ai/features/code/workflows/workflow_bridge.dart';
import 'package:every_ai/features/code/workflows/workflow_engine.dart';

/// The script side of a run: [agent] calls as a script would, [finish] ends it.
final class FakeBridge implements WorkflowBridge {
  final _requests = StreamController<Map<String, Object?>>();
  final _output = StreamController<String>();
  final _exit = Completer<int>();
  final _waiting = <Object?, Completer<Object?>>{};
  var _id = 0;
  var killed = false;

  @override
  Stream<Map<String, Object?>> get requests => _requests.stream;
  @override
  Stream<String> get output => _output.stream;
  @override
  Future<int> get exit => _exit.future;

  /// agent(prompt, opts) as the script calls it: the reply, or the error thrown.
  Future<Object?> agent(String prompt, [Map<String, Object?> opts = const {}]) {
    final id = ++_id;
    final c = _waiting[id] = Completer<Object?>();
    _requests.add({
      'id': id,
      'fn': 'agent',
      'args': {...opts, 'prompt': prompt},
    });
    return c.future;
  }

  void note(String fn, Map<String, Object?> args) => _requests.add({'fn': fn, 'args': args});

  @override
  void reply(Object? id, {Object? result, String? error}) {
    final c = _waiting.remove(id);
    if (c == null || c.isCompleted) return;
    error != null ? c.completeError(error) : c.complete(result);
  }

  /// The script returned [result] and exited.
  void finish(Object? result) {
    note('done', {'result': result});
    _end(0);
  }

  void _end(int code) {
    if (_exit.isCompleted) return;
    unawaited(_requests.close());
    unawaited(_output.close());
    _exit.complete(code);
  }

  @override
  void kill() {
    killed = true;
    _end(137);
  }
}

/// Children that reply with [reply] (turn 1 is the brief, 2 a repair).
final class FakeLauncher implements AgentLauncher {
  final started = <({String prompt, String key, String brief, String childId})>[];
  final watched = <String>[];
  final followUps = <(String, String)>[];
  final stopped = <String>[];
  final finished = <(String, bool)>[];
  final _calls = <String, WorkflowAgentCall>{};
  final _turns = <String, int>{};
  var _n = 0;
  var _active = 0;
  var maxActive = 0;

  String Function(WorkflowAgentCall call, int turn) reply = (call, turn) => 'ok:${call.prompt}';

  /// Holds a child's turn until the future completes.
  Future<void> Function(WorkflowAgentCall call)? gate;

  /// What the child has cost EveryAI (null: an outside harness).
  int? Function(WorkflowAgentCall call) spent = (call) => null;

  /// Calls the journal knew before this launcher existed, by child id.
  final known = <String, WorkflowAgentCall>{};

  @override
  Future<WorkflowChild> start(WorkflowAgentCall call) async {
    final id = 'child-${++_n}-${call.prompt}';
    _calls[id] = call;
    started.add((prompt: call.prompt, key: call.key, brief: call.brief, childId: id));
    return (childId: id, harness: call.harness ?? 'lead', model: call.model ?? 'm', note: null);
  }

  Future<WorkflowAgentResult> _turn(String childId) async {
    final call = _calls[childId] ?? WorkflowAgentCall(key: '', prompt: childId.split('-').last, label: '', phase: '');
    final turn = _turns[childId] = (_turns[childId] ?? 0) + 1;
    _active++;
    if (_active > maxActive) maxActive = _active;
    try {
      await gate?.call(call);
      return (text: reply(call, turn), error: null, spentMicros: spent(call));
    } on Object catch (e) {
      return (text: '', error: '$e', spentMicros: spent(call));
    } finally {
      _active--;
    }
  }

  @override
  Future<WorkflowAgentResult> watch(String childId) {
    watched.add(childId);
    return _turn(childId);
  }

  @override
  Future<WorkflowAgentResult> followUp(String childId, String text) {
    followUps.add((childId, text));
    return _turn(childId);
  }

  @override
  Future<String?> finish(String childId, {required bool ok}) async {
    finished.add((childId, ok));
    return null;
  }

  @override
  void stop(String childId) => stopped.add(childId);
}

/// Timers that fire only when the test says so.
final class FakeTimers {
  final durations = <Duration>[];
  final _callbacks = <void Function()>[];

  Timer call(Duration d, void Function() cb) {
    durations.add(d);
    _callbacks.add(cb);
    return _FakeTimer();
  }

  void fire() {
    for (final cb in [..._callbacks]) {
      cb();
    }
  }
}

final class _FakeTimer implements Timer {
  @override
  void cancel() {}
  @override
  bool get isActive => false;
  @override
  int get tick => 0;
}
