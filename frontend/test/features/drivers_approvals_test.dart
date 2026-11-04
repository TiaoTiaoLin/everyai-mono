import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/domain/rewind.dart';
import 'package:every_ai/features/code/drivers/driver.dart';
import 'package:every_ai/features/code/drivers/driver_events.dart';
import 'package:every_ai/features/code/drivers/driver_registry.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:every_ai/features/code/permissions_providers.dart';
import 'package:every_ai/features/models/domain/model_catalog.dart';
import 'package:every_ai/features/models/models_providers.dart';
import 'package:every_ai/features/usage/usage_totals.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:flutter_test/flutter_test.dart';

class _FixedCatalog extends CatalogController {
  @override
  ModelCatalog build() => builtInCatalog;
}

/// The first value of [p] that meets [cond], now or when it changes.
Future<T> _when<T>(ProviderContainer c, ProviderListenable<T> p, bool Function(T) cond) {
  final done = Completer<T>();
  final sub = c.listen<T>(p, (_, v) {
    if (cond(v) && !done.isCompleted) done.complete(v);
  }, fireImmediately: true);
  return done.future.whenComplete(sub.close);
}

/// An outside driver's session: the test plays its events and reads the
/// answers it got.
final class _Session implements HarnessSession {
  final _events = StreamController<HarnessEvent>.broadcast();
  final answers = <({bool accept, String? reason})>[];
  var _answered = Completer<({bool accept, String? reason})>();

  /// The next answer the controller gives.
  Future<({bool accept, String? reason})> get nextAnswer => _answered.future;
  final steered = <String>[];
  var _seq = 0;

  @override
  String get id => 'c1';
  @override
  Stream<HarnessEvent> get events => _events.stream;

  /// The agent asks to run [kind] [args] through its tool [tool].
  void ask(String tool, String kind, Map<String, Object?> args) {
    _events
      ..add(actionEvent(id: 'a${++_seq}', toolName: tool, kind: kind, args: args))
      ..add(stateEvent('s$_seq', ExecutionStatus.waitingForConfirmation));
  }

  void add(HarnessEvent e) => _events.add(e);

  @override
  Future<void> respond({required bool accept, String? reason, List<String>? callIds}) async {
    final a = (accept: accept, reason: reason);
    answers.add(a);
    if (!_answered.isCompleted) _answered.complete(a);
  }

  void forgetAnswers() {
    answers.clear();
    _answered = Completer();
  }

  @override
  Future<void> send(String text, {bool run = true, List<String> images = const []}) async => steered.add(text);
  @override
  Future<void> interrupt() async => steered.add('(interrupt)');
  @override
  Future<void> pause() async {}
  @override
  Future<void> resume() async {}
  @override
  Future<void> setMode(AgentMode mode, {bool holdClientTools = false}) async {}
  @override
  Future<void> switchLlm(SessionSpec spec) async {}
  @override
  Future<void> rewindTo(String? head) async {}
  @override
  Future<void> close() => _events.close();
}

/// [_Session] for a driver that takes one answer per call and runs each
/// call once it is allowed (OpenCode).
final class _PerCallSession extends _Session implements PerCallApprovals {
  final answeredIds = <List<String>?>[];

  @override
  Future<void> respond({required bool accept, String? reason, List<String>? callIds}) {
    answeredIds.add(callIds);
    return super.respond(accept: accept, reason: reason, callIds: callIds);
  }
}

final class _TestDriver implements HarnessDriver {
  _TestDriver(this.id, this.session, {this.caps = const {DriverCap.approvals}});
  final String id;
  final _Session session;
  @override
  final Set<DriverCap> caps;

  @override
  DriverInfo get info => DriverInfo(id: id, label: 'Test CLI');
  @override
  Future<DriverStatus> detect() async => const DriverStatus(installed: true);
  @override
  Future<List<DriverModel>> models() async => const [];
  @override
  Future<HarnessSession> start(SessionSpec spec) async => session;
  @override
  Future<HarnessSession> attach(String conversationId) async => session;
  @override
  Future<Map<String, ExecutionStatus>> statuses(List<String> conversationIds) async => const {};
}

void main() {
  late AppDatabase db;
  late Directory tmp;
  late _Session session;
  late ProviderContainer container;

  /// A session on [harness] in [mode], connected, with the agent's events
  /// played by the test.
  Future<CodeSessionController> open(AgentMode mode, {String harness = 'test', List<String> deny = const []}) async {
    final prefs = await Preferences.load(db);
    prefs['code.projects'] = jsonEncode([CodeProject(id: 'p1', name: 'P', path: tmp.path).toJson()]);
    prefs['code.sessions'] = jsonEncode([
      CodeSessionInfo(
        id: 's1',
        projectId: 'p1',
        title: 't',
        conversationId: 'c1',
        model: 'm',
        mode: mode,
        workingDir: tmp.path,
        createdAt: DateTime(2026),
        harness: harness,
      ).toJson(),
    ]);
    if (deny.isNotEmpty) {
      prefs[CodePermissions.key] = jsonEncode({
        'global': {'allow': <String>[], 'deny': deny},
      });
    }
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        preferencesProvider.overrideWithValue(prefs),
        modelCatalogProvider.overrideWith(_FixedCatalog.new),
        codeUsageProvider.overrideWithBuild((ref, n) async => UsageTotals.zero),
        driverRegistryProvider.overrideWithValue(
          DriverRegistry({
            everyaiHarnessName: _TestDriver(everyaiHarnessName, session, caps: const {DriverCap.rewind}),
            'test': _TestDriver('test', session),
          }),
        ),
      ],
    );
    container.listen(codeSessionProvider('s1'), (_, _) {});
    await _when(container, codeSessionProvider('s1').select((s) => s.connected), (bool c) => c);
    return container.read(codeSessionProvider('s1').notifier);
  }

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    tmp = await Directory.systemTemp.createTemp('drivers-approvals');
    session = _Session();
  });

  tearDown(() async {
    container.dispose();
    await db.close();
    await tmp.delete(recursive: true);
  });

  Future<({bool accept, String? reason})> answered() async {
    final a = await session.nextAnswer;
    await pumpEventQueue();
    expect(session.answers, hasLength(1));
    return a;
  }

  test('the safety floor holds for an outside driver in Full auto', () async {
    await open(AgentMode.fullAuto);
    session.ask('Bash', 'TerminalAction', {'command': 'rm -rf ~'});
    final a = await answered();
    expect(a.accept, isFalse);
    expect(a.reason, contains(floorReason('rm -rf ~')!));
  });

  test('Plan mode refuses an outside driver\'s changes', () async {
    await open(AgentMode.plan);
    session.ask('Bash', 'TerminalAction', {'command': 'npm install'});
    final a = await answered();
    expect((a.accept, a.reason), (false, AgentMode.planRefusal));
  });

  test('Ask mode runs reads at once and leaves the rest to the user', () async {
    await open(AgentMode.ask);
    session.ask('Bash', 'TerminalAction', {'command': 'ls'});
    expect((await answered()).accept, isTrue);
    session.forgetAnswers();
    session.add(resultEvent(id: 'r1', actionId: 'a1', toolName: 'Bash', text: 'README.md'));
    session.ask('Bash', 'TerminalAction', {'command': 'git push'});
    await _when(
      container,
      codeSessionProvider('s1').select((s) => s.transcript.pending),
      (List<ActionCall> p) => p.isNotEmpty,
    );
    await pumpEventQueue();
    expect(session.answers, isEmpty);
  });

  test('a deny rule matches an outside driver\'s command', () async {
    await open(AgentMode.fullAuto, deny: ['git push *']);
    session.ask('Bash', 'TerminalAction', {'command': 'git push origin main'});
    final a = await answered();
    expect(a.accept, isFalse);
    expect(a.reason, contains('git push *'));
  });

  test('a tool of the driver\'s own is never approved on its own, even in Full auto', () async {
    await open(AgentMode.fullAuto);
    session.ask('Task', 'ClaudeTaskAction', {'prompt': 'look around'});
    await _when(
      container,
      codeSessionProvider('s1').select((s) => s.transcript.pending),
      (List<ActionCall> p) => p.isNotEmpty,
    );
    await pumpEventQueue();
    expect(session.answers, isEmpty);
  });

  test('on the EveryAI harness the same kind still runs in Full auto', () async {
    await open(AgentMode.fullAuto, harness: everyaiHarnessName);
    session.ask('Task', 'ClaudeTaskAction', {'prompt': 'look around'});
    expect((await answered()).accept, isTrue);
  });

  test('a driver without rewind refuses before anything is stopped', () async {
    final controller = await open(AgentMode.ask);
    session.add(
      HarnessEvent.decode({
        'kind': 'MessageEvent',
        'id': 'm1',
        'source': 'user',
        'llm_message': {'role': 'user', 'content': 'hi'},
      }),
    );
    await _when(
      container,
      codeSessionProvider('s1').select((s) => s.transcript.items),
      (List<Object> i) => i.isNotEmpty,
    );
    final out = await controller.rewind(1);
    expect(out.kind, RewindKind.failed);
    expect(out.message, contains("Test CLI can't go back"));
    expect(session.steered, isEmpty);
  });

  test('a mid-run message on a driver without steering interrupts and is sent again', () async {
    final controller = await open(AgentMode.ask);
    await controller.steer('use tabs');
    expect(session.steered.first, '(interrupt)');
    expect(session.steered.last, contains('use tabs'));
  });

  test('a call allowed and still running is not asked about again when the next call asks', () async {
    final perCall = session = _PerCallSession();
    final controller = await open(AgentMode.ask);
    perCall.ask('shell', 'TerminalAction', {'command': 'npm install'});
    await _when(
      container,
      codeSessionProvider('s1').select((s) => s.transcript.pending),
      (List<ActionCall> p) => p.length == 1,
    );
    await controller.approve(ApprovalScope.once, ['a1']);
    // a1 runs; while it does, a2 asks.
    perCall
      ..add(stateEvent('r1', ExecutionStatus.running))
      ..ask('shell', 'TerminalAction', {'command': 'git push'});
    final s = await _when(
      container,
      codeSessionProvider('s1').select((s) => s),
      (CodeSessionState s) => s.transcript.pending.length == 2,
    );
    await pumpEventQueue();
    expect(s.transcript.pending.map((c) => c.id), ['a1', 'a2']);
    expect(container.read(codeSessionProvider('s1')).decided, {'a1': true});
    // Deny all refuses only a2, the one still undecided.
    await controller.deny('no');
    expect(container.read(codeSessionProvider('s1')).decided, {'a1': true, 'a2': false});
    // A result settles its own answer; the rest go when the run ends.
    perCall.add(resultEvent(id: 'r2', actionId: 'a1', toolName: 'shell', text: 'ok'));
    await pumpEventQueue();
    expect(container.read(codeSessionProvider('s1')).decided, {'a2': false});
    perCall.add(stateEvent('e', ExecutionStatus.idle));
    await pumpEventQueue();
    expect(container.read(codeSessionProvider('s1')).decided, isEmpty);
    expect(perCall.answeredIds, [
      ['a1'],
      null,
    ]);
  });
}
