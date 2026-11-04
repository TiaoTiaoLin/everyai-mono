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
import 'package:flutter_test/flutter_test.dart';

class _FixedCatalog extends CatalogController {
  @override
  ModelCatalog build() => builtInCatalog;
}

Future<T> _until<T>(T Function() read, bool Function(T) cond) async {
  final end = DateTime.now().add(const Duration(seconds: 8));
  while (true) {
    final v = read();
    if (cond(v)) return v;
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met: $v');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// An outside driver's session: the test plays its events and reads the
/// answers it got.
final class _Session implements HarnessSession {
  final _events = StreamController<HarnessEvent>.broadcast();
  final answers = <({bool accept, String? reason})>[];
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
  Future<void> respond({required bool accept, String? reason, List<String>? callIds}) async =>
      answers.add((accept: accept, reason: reason));
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
    await _until(() => container.read(codeSessionProvider('s1')).connected, (c) => c);
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

  Future<({bool accept, String? reason})> answered() =>
      _until(() => session.answers, (a) => a.isNotEmpty).then((a) => a.single);

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
    session.answers.clear();
    session.add(resultEvent(id: 'r1', actionId: 'a1', toolName: 'Bash', text: 'README.md'));
    session.ask('Bash', 'TerminalAction', {'command': 'git push'});
    await _until(() => container.read(codeSessionProvider('s1')).transcript.pending, (p) => p.isNotEmpty);
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
    await _until(() => container.read(codeSessionProvider('s1')).transcript.pending, (p) => p.isNotEmpty);
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
    await _until(() => container.read(codeSessionProvider('s1')).transcript.items, (i) => i.isNotEmpty);
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
}
