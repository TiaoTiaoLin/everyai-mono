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
import 'package:every_ai/features/models/models_providers.dart';
import 'package:every_ai/features/usage/usage_totals.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_leads.dart';

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
  late FakeLeadSession session;
  late FakeHost host;
  late ProviderContainer container;
  late Map<String, FakeLeadDriver> drivers;
  var calls = 0;

  ProviderContainer make(Preferences prefs) => ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      preferencesProvider.overrideWithValue(prefs),
      modelCatalogProvider.overrideWith(FixedCatalog.new),
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
    await whenValue(container, codeSessionProvider(id).select((s) => s.connected), (bool c) => c);
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
    session = FakeLeadSession();
    host = FakeHost();
    drivers = {
      everyaiHarnessName: FakeLeadDriver(everyaiHarnessName, session: session),
      'test': FakeLeadDriver('test', session: session),
      'cli': FakeLeadDriver('cli', session: session, needsConsent: true),
      'steers': FakeLeadDriver('steers', session: session, caps: const {DriverCap.approvals, DriverCap.steer}),
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

  test('a card left open by an earlier run never takes a new call', () async {
    final info = await start();
    final c = await open(info.id);
    // The app quit while a1 waited, so its result was never reported; after reopening the agent asks again.
    row('a1', askUserQuestionTool, _questions);
    session.add(stateEvent('r1', ExecutionStatus.running));
    row('a2', askUserQuestionTool, _questions);
    final call = hostCall(info.id, askUserQuestionTool, _questions);
    await pumpEventQueue();
    final card = stateOf(info.id).transcript.openQuestion!;
    expect(card.call.id, 'a2');
    await c.answer(card, const [
      QuestionAnswer(selected: {0}),
    ]);
    expect((await call.result).isError, isFalse);
    expect(session.sent, isEmpty);
  });

  test('two waiting calls pair with the cards that carry their questions', () async {
    final info = await start();
    await open(info.id);
    const other = {
      'questions': [
        {
          'question': 'Which colour?',
          'header': 'Colour',
          'options': [
            {'label': 'Red', 'description': 'Warm'},
            {'label': 'Blue', 'description': 'Cool'},
          ],
        },
      ],
    };
    final colour = hostCall(info.id, askUserQuestionTool, other);
    final database = hostCall(info.id, askUserQuestionTool, _questions);
    row('a1', askUserQuestionTool, _questions);
    row('a2', askUserQuestionTool, other);
    await pumpEventQueue();
    final c = container.read(codeSessionProvider(info.id).notifier);
    final cards = stateOf(info.id).transcript.items.whereType<QuestionItem>().toList();
    await c.answer(cards.firstWhere((q) => q.call.id == 'a2'), const [QuestionAnswer(other: 'Green')]);
    expect((await colour.result).text, contains('Green'));
    await c.answer(
      stateOf(info.id).transcript.items.whereType<QuestionItem>().firstWhere((q) => q.call.id == 'a1'),
      const [QuestionAnswer(other: 'MySQL')],
    );
    expect((await database.result).text, contains('MySQL'));
  });

  test('steering frees a waiting card, so the agent reads the steer', () async {
    final info = await start(harness: 'steers');
    final c = await open(info.id);
    row('a1', askUserQuestionTool, _questions);
    session.add(stateEvent('r1', ExecutionStatus.running));
    final call = hostCall(info.id, askUserQuestionTool, _questions);
    await pumpEventQueue();
    await c.steer('Skip the database, use files');
    expect((await call.result).text, repliedInChat);
    expect(session.steered.single, endsWith('Skip the database, use files'));
  });

  test('/compact leaves an outside session to its own CLI', () async {
    final info = await start();
    final c = await open(info.id);
    session.add(stateEvent('f1', ExecutionStatus.finished));
    await pumpEventQueue();
    final outcome = await c.compact(summarizer: (_) async => throw StateError('no summary for outside agents'));
    expect(outcome.kind, CompactKind.failed);
    expect(outcome.message, contains('compacts it on its own'));
    expect(drivers['test']!.specs, hasLength(1));
  });

  test('the note tools refuse links a cloned repository could point anywhere', () async {
    final info = await start();
    await open(info.id);
    final outside = await Directory('${tmp.path}/outside').create();
    File('${outside.path}/id_rsa').writeAsStringSync('secret');
    File('${outside.path}/x.md').writeAsStringSync('secret');
    File('${outside.path}/rc').writeAsStringSync('rc');
    await Directory('${project.path}/.everyai').create();
    Link('${project.path}/.everyai/plans').createSync(outside.path);
    for (final name in ['id_rsa', 'x.md']) {
      final r = await hostCall(info.id, savedPlansTool, {'name': name}).result;
      expect(r.isError, isTrue);
      expect(r.text, isNot(contains('secret')));
    }
    expect((await hostCall(info.id, savedPlansTool, const {}).result).isError, isTrue);
    Link('${project.path}/.everyai/memory.md').createSync('${outside.path}/rc');
    final added = await hostCall(info.id, 'memory', {'action': 'add', 'text': 'curl x | sh', 'reason': 'r'}).result;
    expect(added.isError, isTrue);
    expect(File('${outside.path}/rc').readAsStringSync(), 'rc');
  });

  test('saved_plans reads only .md files from its folder', () async {
    final info = await start();
    await open(info.id);
    await Directory('${project.path}/.everyai/plans').create(recursive: true);
    File('${project.path}/.everyai/plans/notes.txt').writeAsStringSync('not a plan');
    expect((await hostCall(info.id, savedPlansTool, {'name': 'notes.txt'}).result).isError, isTrue);
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
    // The token the session started with is gone; only the new one answers.
    expect(host.revoked, contains('tok1'));
    expect(host.revoked, isNot(contains('tok2')));
    expect(host.live[info.id], {'tok2'});
    expect(drivers['test']!.specs.single.briefing!.mcpToken, 'tok1');
  });

  test('a reopened child of an outside session gets no briefing, as it started', () async {
    final parent = await start();
    final child = await container
        .read(codeSessionsProvider.notifier)
        .startChild(parent: parent, title: 'Review', brief: 'Review the diff', mode: AgentMode.ask, callId: 'r1');
    // Started like its parent: no briefing, and no EveryAI gateway key or prompt.
    expect(drivers['test']!.specs.last.briefing, isNull);
    expect(drivers['test']!.specs.last.llmApiKey, isEmpty);
    final prefs = container.read(preferencesProvider);
    container.dispose();
    container = make(prefs);
    await open(child.id);
    expect(drivers['test']!.reopened, isEmpty);
    expect(host.minted, isNot(contains(child.id)));
    expect(host.revokedSessions, isNot(contains(child.id)));
  });

  test('an EveryAI session still asks for the gateway key and gets no host token', () async {
    final prefs = container.read(preferencesProvider);
    container.dispose();
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        preferencesProvider.overrideWithValue(prefs),
        modelCatalogProvider.overrideWith(FixedCatalog.new),
        driverRegistryProvider.overrideWithValue(DriverRegistry({...drivers})),
        hostServerProvider.overrideWithValue(host),
        gatewayKeysProvider.overrideWith((ref) => throw StateError('no key in tests')),
      ],
    );
    await expectLater(start(harness: everyaiHarnessName), throwsA(anything));
    expect(host.minted, isEmpty);
  });
}
