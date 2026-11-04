import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/code_settings_providers.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/domain/questions.dart';
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/drivers/driver.dart';
import 'package:every_ai/features/code/drivers/driver_events.dart';
import 'package:every_ai/features/code/drivers/driver_registry.dart';
import 'package:every_ai/features/code/gateway_key.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:every_ai/features/code/host/host.dart';
import 'package:every_ai/features/code/host/host_providers.dart';
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

/// An outside agent's session: the test plays its events and reads what it was sent and answered.
final class _Session implements HarnessSession {
  final _events = StreamController<HarnessEvent>.broadcast();
  final answers = <({bool accept, String? reason})>[];
  final sent = <String>[];

  @override
  String get id => 'c1';
  @override
  Stream<HarnessEvent> get events => _events.stream;

  void add(HarnessEvent e) => _events.add(e);

  @override
  Future<void> respond({required bool accept, String? reason, List<String>? callIds}) async =>
      answers.add((accept: accept, reason: reason));
  @override
  Future<void> send(String text, {bool run = true, List<String> images = const []}) async => sent.add(text);
  @override
  Future<void> interrupt() async {}
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
  Future<void> close() async {}
}

final class _Driver implements HarnessDriver, AttachesBriefed {
  _Driver(this.id, this.session, {this.needsConsent = false});
  final String id;
  final _Session session;
  final bool needsConsent;
  final specs = <SessionSpec>[];
  final reopened = <DriverBriefing>[];

  @override
  DriverInfo get info => DriverInfo(id: id, label: 'Test CLI', needsConsent: needsConsent);
  @override
  Set<DriverCap> get caps => const {DriverCap.approvals};
  @override
  Future<DriverStatus> detect() async => const DriverStatus(installed: true);
  @override
  Future<List<DriverModel>> models() async => const [];
  @override
  Future<HarnessSession> start(SessionSpec spec) async {
    specs.add(spec);
    return session;
  }

  @override
  Future<HarnessSession> attach(String conversationId) async => session;
  @override
  Future<HarnessSession> attachBriefed(String conversationId, DriverBriefing briefing) async {
    reopened.add(briefing);
    return session;
  }

  @override
  Future<Map<String, ExecutionStatus>> statuses(List<String> conversationIds) async => const {};
}

/// The MCP host: records tokens and hands the test each session's tools.
final class _Host implements HostServer {
  final minted = <String>[];
  final revoked = <String>[];
  final revokedSessions = <String>[];
  final tools = <String, HostTools>{};
  var touchOk = true;
  var _n = 0;

  @override
  Future<HostToken> mint(String sessionId, HostTools tools, {bool bugFix = false}) async {
    minted.add(sessionId);
    this.tools[sessionId] = tools;
    return (url: Uri.parse('http://127.0.0.1:9/mcp'), token: 'tok${++_n}');
  }

  @override
  bool touch(String token) => touchOk;
  @override
  Future<void> revoke(String token) async => revoked.add(token);
  @override
  Future<void> revokeSession(String sessionId) async => revokedSessions.add(sessionId);
  @override
  Future<void> stop() async {}
}

const _questions = {
  'questions': [
    {
      'question': 'Which database?',
      'header': 'Database',
      'options': [
        {'label': 'SQLite', 'description': 'One file'},
        {'label': 'Postgres', 'description': 'A server'},
      ],
    },
  ],
};

const _plan = {
  'title': 'Dark mode',
  'summary': 'Add a dark theme.',
  'steps': ['Add colours', 'Wire the switch'],
};

void main() {
  // The app-quit listener needs a binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late Directory tmp;
  late Directory project;
  late _Session session;
  late _Host host;
  late ProviderContainer container;
  late Map<String, _Driver> drivers;
  var calls = 0;

  ProviderContainer make(Preferences prefs) => ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      preferencesProvider.overrideWithValue(prefs),
      modelCatalogProvider.overrideWith(_FixedCatalog.new),
      codeUsageProvider.overrideWithBuild((ref, n) async => UsageTotals.zero),
      driverRegistryProvider.overrideWithValue(DriverRegistry({...drivers})),
      hostServerProvider.overrideWithValue(host),
      driverDataDirProvider.overrideWithValue(() async => '${tmp.path}/data'),
      // An outside CLI runs on the user's own account: no EveryAI key is minted for it.
      gatewayKeysProvider.overrideWith((ref) => throw StateError('no gateway key for outside agents')),
    ],
  );

  Future<CodeSessionInfo> start({String harness = 'test', AgentMode mode = AgentMode.ask}) => container
      .read(codeSessionsProvider.notifier)
      .start(
        project: container.read(codeProjectsProvider).single,
        prompt: 'Add dark mode',
        model: '',
        mode: mode,
        harness: harness,
      );

  /// The session's controller, connected.
  Future<CodeSessionController> open(String id) async {
    container.listen(codeSessionProvider(id), (_, _) {});
    await _when(container, codeSessionProvider(id).select((s) => s.connected), (bool c) => c);
    return container.read(codeSessionProvider(id).notifier);
  }

  /// The agent calls host tool [name] for session [id].
  ({Future<HostResult> result, Completer<HostEnd> end}) hostCall(String id, String name, Map<String, Object?> args) {
    final end = Completer<HostEnd>();
    final result = host.tools[id]!.call(
      HostCall(id: 'h${++calls}', sessionId: id, name: name, args: args, ended: end.future),
    );
    return (result: result, end: end);
  }

  /// The agent's own row for its host call (Claude Code's naming), waiting for approval.
  void row(String id, String tool, Map<String, Object?> args) => session
    ..add(actionEvent(id: id, toolName: 'mcp__everyai__$tool', kind: 'MCPToolAction', args: args))
    ..add(stateEvent('$id-w', ExecutionStatus.waitingForConfirmation));

  CodeSessionState stateOf(String id) => container.read(codeSessionProvider(id));

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    tmp = await Directory.systemTemp.createTemp('code-lead');
    project = await Directory('${tmp.path}/project').create();
    session = _Session();
    host = _Host();
    drivers = {
      everyaiHarnessName: _Driver(everyaiHarnessName, session),
      'test': _Driver('test', session),
      'cli': _Driver('cli', session, needsConsent: true),
    };
    final prefs = await Preferences.load(db);
    prefs['code.projects'] = jsonEncode([CodeProject(id: 'p1', name: 'P', path: project.path).toJson()]);
    container = make(prefs);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
    await tmp.delete(recursive: true);
  });

  test('an outside session starts with its briefing and no gateway key', () async {
    final info = await start();
    final spec = drivers['test']!.specs.single;
    final b = spec.briefing!;
    expect((b.mcpUrl, b.mcpToken), ('http://127.0.0.1:9/mcp', 'tok1'));
    final root = '${tmp.path}/data/driver-sessions/${info.id}/briefing';
    expect(b.skillDir, '$root/skills');
    expect(File('$root/session.md').readAsStringSync(), b.sessionSkill);
    expect(b.sessionSkill, contains('# EveryAI session'));
    expect(b.sessionSkill, contains('`ask_user_question`'));
    expect(b.sessionSkill, isNot(contains('bug_check')));
    expect(spec.llmApiKey, isEmpty);
    expect(spec.phaseFlow, isNull);
    expect(spec.initialMessage, startsWith('<everyai-mode name="ask">'));
    expect(host.minted, [info.id]);
    expect(info.harness, 'test');
  });

  test('Max is stored as Thorough and Bug fix as Build for an outside lead', () async {
    final info = await container
        .read(codeSessionsProvider.notifier)
        .start(
          project: container.read(codeProjectsProvider).single,
          prompt: 'x',
          model: '',
          mode: AgentMode.ask,
          harness: 'test',
          tier: HarnessTier.max,
          harnessMode: HarnessMode.bugFix,
        );
    expect((info.tier, info.harnessMode), (HarnessTier.thorough, HarnessMode.build));
  });

  test('every message carries the mode note, in full after a switch', () async {
    final info = await start();
    final c = await open(info.id);
    await c.send('first');
    expect(session.sent.last, startsWith('<everyai-mode name="ask">'));
    expect(session.sent.last, endsWith('first'));
    await c.setMode(AgentMode.plan);
    await c.send('second');
    expect(session.sent.last, startsWith('<everyai-mode name="plan">${AgentMode.plan.instructions}'));
  });

  test('a host question shows as a card and the answer is the call\'s result', () async {
    final info = await start();
    final c = await open(info.id);
    row('a1', askUserQuestionTool, _questions);
    await pumpEventQueue();
    // Our own question tool runs without asking, even in Ask mode.
    expect(session.answers, [(accept: true, reason: null)]);
    session.add(stateEvent('r1', ExecutionStatus.running));
    final call = hostCall(info.id, askUserQuestionTool, _questions);
    await pumpEventQueue();
    final card = stateOf(info.id).transcript.openQuestion!;
    expect(card.call.id, 'a1');
    expect(stateOf(info.id).status, SessionStatus.needsInput);
    final answers = [
      const QuestionAnswer(selected: {1}),
    ];
    await c.answer(card, answers);
    final result = await call.result;
    expect(result, (text: answersReason(card.questions, answers), isError: false));
    expect(stateOf(info.id).transcript.openQuestion, isNull);
    // The agent reports the call's result: the card keeps its answers.
    session.add(resultEvent(id: 'o1', actionId: 'a1', toolName: 'mcp__everyai__ask_user_question', text: result.text));
    await pumpEventQueue();
    final settled = stateOf(info.id).transcript.items.whereType<QuestionItem>().single;
    expect(settled.answers!.single.selected, {1});
  });

  test('the host call may arrive before the agent\'s row', () async {
    final info = await start();
    final c = await open(info.id);
    final call = hostCall(info.id, askUserQuestionTool, _questions);
    await pumpEventQueue();
    row('a1', askUserQuestionTool, _questions);
    await pumpEventQueue();
    await c.answer(stateOf(info.id).transcript.openQuestion!, const [QuestionAnswer(other: 'MySQL')]);
    expect((await call.result).text, contains('MySQL'));
  });

  test('approving a host plan leaves Plan mode and keeps the plan with the project', () async {
    final info = await start(mode: AgentMode.plan);
    final c = await open(info.id);
    row('a1', presentPlanTool, _plan);
    final call = hostCall(info.id, presentPlanTool, _plan);
    await pumpEventQueue();
    expect(stateOf(info.id).transcript.openPlan, isNotNull);
    await c.startBuilding();
    expect((await call.result).text, startsWith(planApprovedReason));
    expect(stateOf(info.id).mode, AgentMode.autoEdit);
    expect(stateOf(info.id).transcript.openPlan, isNull);
    final saved = Directory('${project.path}/.everyai/plans').listSync().single as File;
    expect(saved.readAsStringSync(), startsWith('# Dark mode'));
  });

  test('a chat message while a card waits frees the call and goes out after the turn', () async {
    final info = await start();
    final c = await open(info.id);
    row('a1', askUserQuestionTool, _questions);
    await pumpEventQueue();
    session.add(stateEvent('r1', ExecutionStatus.running));
    final call = hostCall(info.id, askUserQuestionTool, _questions);
    await pumpEventQueue();
    await c.send('Use what you think is best');
    expect((await call.result).text, repliedInChat);
    expect(stateOf(info.id).queued, hasLength(1));
    session.add(stateEvent('f1', ExecutionStatus.finished));
    await pumpEventQueue();
    expect(session.sent.last, endsWith('Use what you think is best'));
  });

  test('a given-up call closes its card with the agent\'s error result', () async {
    final info = await start();
    await open(info.id);
    row('a1', askUserQuestionTool, _questions);
    final call = hostCall(info.id, askUserQuestionTool, _questions);
    await pumpEventQueue();
    call.end.complete(HostEnd.timedOut);
    expect((await call.result).isError, isTrue);
    session.add(
      resultEvent(
        id: 'o1',
        actionId: 'a1',
        toolName: 'mcp__everyai__ask_user_question',
        text: 'timed out',
        isError: true,
      ),
    );
    await pumpEventQueue();
    expect(stateOf(info.id).transcript.openQuestion, isNull);
    expect(stateOf(info.id).transcript.items.whereType<QuestionItem>().single.answers, isEmpty);
  });

  test('Stop gives up the waiting calls', () async {
    final info = await start();
    final c = await open(info.id);
    row('a1', askUserQuestionTool, _questions);
    final call = hostCall(info.id, askUserQuestionTool, _questions);
    await pumpEventQueue();
    await c.stop();
    expect((await call.result).isError, isTrue);
  });

  test('memory and saved plans run in the session folder; bug_check is for Bug fix', () async {
    final info = await start();
    await open(info.id);
    final added = await hostCall(info.id, 'memory', {'action': 'add', 'text': '- Run make test', 'reason': 'r'}).result;
    expect(added.isError, isFalse);
    expect(File('${project.path}/.everyai/memory.md').readAsStringSync(), '- Run make test\n');
    expect((await hostCall(info.id, savedPlansTool, const {}).result).text, 'No saved plans yet.');
    await Directory('${project.path}/.everyai/plans').create(recursive: true);
    File('${project.path}/.everyai/plans/2026-11-04-dark.md').writeAsStringSync('# Dark\n\nSteps');
    expect((await hostCall(info.id, savedPlansTool, const {}).result).text, '- 2026-11-04-dark.md: Dark');
    expect((await hostCall(info.id, savedPlansTool, {'name': '2026-11-04-dark.md'}).result).text, '# Dark\n\nSteps');
    expect((await hostCall(info.id, savedPlansTool, {'name': '../memory.md'}).result).isError, isTrue);
    final bug = await hostCall(info.id, 'bug_check', const {}).result;
    expect(bug.isError, isTrue);
    expect(bug.text, contains('Bug fix'));
  });

  test('an expired token gets a note at the next turn', () async {
    final info = await start();
    final c = await open(info.id);
    host.touchOk = false;
    await c.send('go on');
    expect(stateOf(info.id).transcript.items.whereType<NoticeItem>().single.message, hostToolsExpired);
  });

  test('deleting the session ends its token and its briefing', () async {
    final info = await start();
    final root = Directory('${tmp.path}/data/driver-sessions/${info.id}/briefing');
    expect(root.existsSync(), isTrue);
    await container.read(codeSessionsProvider.notifier).remove(info.id);
    expect(host.revokedSessions, [info.id]);
    expect(root.existsSync(), isFalse);
  });

  test('a CLI that needs consent starts only once the user turned it on', () async {
    await expectLater(start(harness: 'cli'), throwsA(isA<HarnessError>()));
    expect(host.minted, isEmpty);
    expect(drivers['cli']!.specs, isEmpty);
    container.read(codeSettingsProvider.notifier).setOwnCli('cli', true);
    final info = await start(harness: 'cli');
    expect(host.minted, [info.id]);
  });

  test('a reopened session gets a fresh briefing', () async {
    final info = await start();
    final prefs = container.read(preferencesProvider);
    container.dispose();
    container = make(prefs);
    await open(info.id);
    final again = drivers['test']!.reopened.single;
    expect(again.mcpToken, 'tok2');
    expect(again.sessionSkill, contains('# EveryAI session'));
  });

  test('an EveryAI session still asks for the gateway key and gets no host token', () async {
    final prefs = container.read(preferencesProvider);
    container.dispose();
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        preferencesProvider.overrideWithValue(prefs),
        modelCatalogProvider.overrideWith(_FixedCatalog.new),
        driverRegistryProvider.overrideWithValue(DriverRegistry({...drivers})),
        hostServerProvider.overrideWithValue(host),
        gatewayKeysProvider.overrideWith((ref) => throw StateError('no key in tests')),
      ],
    );
    await expectLater(start(harness: everyaiHarnessName), throwsA(anything));
    expect(host.minted, isEmpty);
  });
}
