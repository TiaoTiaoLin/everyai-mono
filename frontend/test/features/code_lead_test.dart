import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show max;

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/net/api_client.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/code_settings_providers.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/domain/git_commands.dart' show plainPrBody;
import 'package:every_ai/features/code/domain/goal.dart' show GoalStatus;
import 'package:every_ai/features/code/domain/local_ports.dart' show ListeningPort;
import 'package:every_ai/features/code/domain/no_spend.dart';
import 'package:every_ai/features/code/domain/permissions.dart' show DenialKind, denialMessage;
import 'package:every_ai/features/code/domain/questions.dart';
import 'package:every_ai/features/code/domain/session_commands.dart' show AsideKind;
import 'package:every_ai/features/code/git/git_models.dart' show SessionWorktree;
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/drivers/driver.dart';
import 'package:every_ai/features/code/drivers/acp/acp_mapping.dart' show agentMessageEvent, userMessageEvent;
import 'package:every_ai/features/code/drivers/driver_events.dart';
import 'package:every_ai/features/code/drivers/driver_registry.dart';
import 'package:every_ai/features/code/gateway_key.dart';
import 'package:every_ai/features/code/mcp_providers.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:every_ai/features/code/host/host.dart';
import 'package:every_ai/features/code/host/host_providers.dart';
import 'package:every_ai/features/code/host/host_screen.dart';
import 'package:every_ai/features/code/drivers/driver_process.dart' show DriverProcess;
import 'package:every_ai/features/code/host/host_script.dart' show hostScriptsAvailable;
import 'package:every_ai/features/models/models_providers.dart';
import 'package:every_ai/features/usage/usage_totals.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:every_ai/features/code/workflows/workflow_picker.dart' show WorkflowPick;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

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
  final reached = <String>[];
  // A test that wants the real key flow (minting recorded in [reached]) sets this.
  GatewayKeys? keys;
  late _FakeScreen screen;

  ProviderContainer make(Preferences prefs) => ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      preferencesProvider.overrideWithValue(prefs),
      modelCatalogProvider.overrideWith(FixedCatalog.new),
      codeUsageProvider.overrideWithBuild((ref, n) async => UsageTotals.zero),
      driverRegistryProvider.overrideWithValue(DriverRegistry({...drivers})),
      hostServerProvider.overrideWithValue(host),
      screenAccessProvider.overrideWith((ref) => screen.access),
      driverDataDirProvider.overrideWithValue(() async => '${tmp.path}/data'),
      // An outside CLI runs on the user's own account: no EveryAI key is minted for it.
      gatewayKeysProvider.overrideWith((ref) => keys ?? (throw StateError('no gateway key for outside agents'))),
      // Nothing an outside lead does reaches the backend or a side model (checked after each test).
      apiClientProvider.overrideWithValue(
        ApiClient(
          baseUrl: Uri.parse('http://backend/'),
          client: MockClient((req) async {
            reached.add('${req.method} ${req.url}');
            return http.Response('no network in this test', 599);
          }),
        ),
      ),
      codeSideModelProvider.overrideWithValue((messages) async {
        reached.add('side model');
        return '';
      }),
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
    screen = _FakeScreen();
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
    keys = null;
    CodeSessionController.liveAfter = const Duration(milliseconds: 1500);
    final sent = [...reached];
    reached.clear();
    expect(sent, isEmpty, reason: 'an outside lead reached the network or a side model');
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
    for (final tool in ['bug_check', 'check', 'diff_stats', 'goal_check', 'browser', 'screenshot', 'app_run']) {
      expect(b.sessionSkill, contains('`$tool`'));
    }
    expect(spec.llmApiKey, isEmpty);
    expect(spec.bugCheck, isFalse);
    expect(spec.initialMessage, startsWith('<everyai-mode name="ask">'));
    expect(host.minted, [info.id]);
    expect(info.harness, 'test');
  });

  test('an outside lead keeps its effort level and the Max workflow', () async {
    final info = await container
        .read(codeSessionsProvider.notifier)
        .start(
          project: container.read(codeProjectsProvider).single,
          prompt: 'x',
          model: '',
          mode: AgentMode.ask,
          harness: 'test',
          tier: HarnessTier.thorough,
          workflow: const WorkflowPick.max(),
        );
    expect((info.tier, info.workflow), (HarnessTier.thorough, 'max'));
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

  test('a host plan is approved before the agent takes the mode switch', () async {
    final info = await start(mode: AgentMode.plan);
    final c = await open(info.id);
    row('a1', presentPlanTool, _plan);
    final call = hostCall(info.id, presentPlanTool, _plan);
    await pumpEventQueue();
    // Like Cursor blocked on its plan request: the switch is taken only after the plan is answered.
    final gate = session.modeGate = Completer<void>();
    unawaited(call.result.then((_) => gate.complete()));
    await c.startBuilding();
    expect((await call.result).text, startsWith(planApprovedReason));
    expect(stateOf(info.id).mode, AgentMode.autoEdit);
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
    // The card is up once the agent's row is folded.
    await whenValue(
      container,
      codeSessionProvider(info.id).select((s) => s.transcript.openQuestion?.call.id),
      (String? id) => id == 'a1',
    );
    // Straight to the controller (no hop through the host's ready gate), so the call is waiting when Stop runs.
    final result = c.call(
      HostCall(
        id: 'h1',
        sessionId: info.id,
        name: askUserQuestionTool,
        args: _questions,
        ended: Completer<HostEnd>().future,
      ),
    );
    await c.stop();
    expect(await result, (text: denialMessage(DenialKind.cancelled), isError: true));
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

  group('EveryAI spends nothing on an outside lead', () {
    test('/btw is off, with the reason', () async {
      final info = await start();
      final c = await open(info.id);
      await c.askAside('Why SQLite?', summarizer: (_) async => fail('no model for /btw on an outside lead'));
      final aside = stateOf(info.id).asides.single;
      expect(aside.error, btwOff('Test CLI'));
    });

    test('/goal is kept for goal_check, with no judge model', () async {
      final info = await start();
      final c = await open(info.id);
      session.add(stateEvent('r0', ExecutionStatus.finished));
      await pumpEventQueue();
      expect(await c.setGoal('The tests pass'), isNull);
      expect(stateOf(info.id).goal?.note, goalByLeadNote);
      expect(session.sent.last, endsWith(goalLeadMessage('The tests pass')));
      // A finished turn asks no judge (the tearDown fails on a side-model call).
      session.add(agentMessageEvent('a1', 'Done.'));
      session.add(stateEvent('r1', ExecutionStatus.finished));
      await pumpEventQueue();
      final check = await hostCall(info.id, 'goal_check', const {}).result;
      expect(check.text, allOf(startsWith('Goal: The tests pass'), contains('<goal-check>'), contains('sub-agent')));
    });

    test('a goal set under the EveryAI lead is handed to an outside lead, with no judge', () async {
      final info = await start();
      final c = await open(info.id);
      session.add(stateEvent('r0', ExecutionStatus.finished));
      await pumpEventQueue();
      final sessions = container.read(codeSessionsProvider.notifier);
      sessions.update(sessions.byId(info.id)!.copyWith(harness: everyaiHarnessName));
      expect(await c.setGoal('The tests pass'), isNull);
      expect(stateOf(info.id).goal?.note, isNot(goalByLeadNote));
      // The lead moves to an outside CLI: the next event hands the goal over once.
      sessions.update(sessions.byId(info.id)!.copyWith(harness: 'test'));
      session.add(stateEvent('r1', ExecutionStatus.running));
      await pumpEventQueue();
      expect((stateOf(info.id).goal?.status, stateOf(info.id).goal?.note), (GoalStatus.active, goalByLeadNote));
      // Sent once the lead's turn ends (a message while it works waits in the queue).
      session.add(stateEvent('r2', ExecutionStatus.finished));
      await pumpEventQueue();
      expect(session.sent.where((m) => m.endsWith(goalLeadMessage('The tests pass'))), hasLength(1));
      expect(stateOf(info.id).goal?.status, GoalStatus.active);
    });

    test('/learn writes no skill from the session or a page', () async {
      final info = await start();
      final c = await open(info.id);
      session
        ..add(userMessageEvent('u1', 'Add dark mode'))
        ..add(agentMessageEvent('a1', 'Done.'));
      await whenValue(container, codeSessionProvider(info.id).select((s) => s.transcript.items.length), (n) => n > 1);
      await c.learn('');
      await c.learn('https://example.com/guide');
      expect([for (final a in stateOf(info.id).asides) a.error], [learnOff('Test CLI'), learnOff('Test CLI')]);
    });

    test('a commit message is the session title, with no side model', () async {
      Future<String> git(List<String> args) async {
        final r = await Process.run('git', ['-C', project.path, ...args]);
        if (r.exitCode != 0) fail('git ${args.join(' ')}: ${r.stderr}');
        return '${r.stdout}'.trim();
      }

      await git(['init', '-q', '-b', 'main']);
      await git(['config', 'user.name', 'Dev']);
      await git(['config', 'user.email', 'dev@example.com']);
      File('${project.path}/a.txt').writeAsStringSync('one\n');
      await git(['add', '-A']);
      await git(['commit', '-q', '-m', 'Initial']);
      final head = await git(['rev-parse', 'HEAD']);
      File('${project.path}/a.txt').writeAsStringSync('two\n');
      final prefs = container.read(preferencesProvider);
      prefs['code.sessions'] = jsonEncode([
        CodeSessionInfo(
          id: 's1',
          projectId: 'p1',
          title: 'Dark mode',
          conversationId: 'c1',
          model: '',
          mode: AgentMode.ask,
          workingDir: project.path,
          createdAt: DateTime(2026),
          harness: 'test',
          branch: 'main',
          worktree: SessionWorktree(
            repoRoot: project.path,
            path: project.path,
            branch: 'main',
            baseBranch: 'main',
            baseCommit: head,
          ),
        ).toJson(),
      ]);
      container.dispose();
      container = make(prefs);
      final c = await open('s1');
      await c.draftCommit('');
      final aside = stateOf('s1').asides.single;
      expect((aside.kind, aside.answer, aside.error), (AsideKind.commit, 'Dark mode', null));
      expect(plainPrBody(['Add the toggle', 'Add colours']), '- Add the toggle\n- Add colours');
    });

    test("an outside lead's own login error mints no gateway key and runs nothing again", () async {
      keys = GatewayKeys(
        store: _MemoryStore(),
        mint: () async {
          reached.add('POST v1/keys');
          return 'sk-eai-new';
        },
      );
      CodeSessionController.liveAfter = Duration.zero;
      final info = await start();
      await open(info.id);
      // Past the replay window: events are live.
      await pumpEventQueue();
      session
        ..add(const ConversationFailure(id: 'e1', raw: {}, message: 'Invalid API key · Please run /login'))
        ..add(const ConversationFailure(id: 'e2', raw: {}, message: 'unexpected status 401 Unauthorized'));
      await whenValue(
        container,
        codeSessionProvider(info.id).select((s) => s.transcript.items.whereType<NoticeItem>().length),
        (n) => n >= 2,
      );
      await pumpEventQueue();
      expect((session.resumes, session.llmSwitches), (0, 0));
    });

    test('approval cards ask the decider for no risk label', () async {
      final info = await start();
      expect(riskLabelDir(info), isNull);
      final own = CodeSessionInfo.fromJson({...info.toJson(), 'harness': everyaiHarnessName});
      expect(riskLabelDir(own), project.path);
    });
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

  test('memory and saved plans run in the session folder; bug_check checks its action', () async {
    final info = await start();
    await open(info.id);
    final added = await hostCall(info.id, 'memory', {'action': 'add', 'text': '- Run make test', 'reason': 'r'}).result;
    expect(added.isError, isFalse);
    expect(File('${project.path}/.everyai/memory.md').readAsStringSync(), '- Run make test\n');
    expect((await hostCall(info.id, savedPlansTool, const {}).result).text, 'No saved plans yet.');
    await Directory('${project.path}/.everyai/plans').create(recursive: true);
    File('${project.path}/.everyai/plans/2026-11-04-dark.md').writeAsStringSync('# Dark\n\nSteps');
    expect((await hostCall(info.id, savedPlansTool, const {}).result).text, '- 2026-11-04-dark.md: Dark');
    expect(
      (await hostCall(info.id, savedPlansTool, {'name': '2026-11-04-dark.md'}).result).text,
      '<untrusted-content source=".everyai/plans/2026-11-04-dark.md">\n# Dark\n\nSteps\n</untrusted-content>',
    );
    expect((await hostCall(info.id, savedPlansTool, {'name': '../memory.md'}).result).isError, isTrue);
    final bug = await hostCall(info.id, 'bug_check', const {}).result;
    expect(bug.isError, isTrue);
    expect(bug.text, contains('reproduced, verify or status'));
  });

  test('the checks answer an outside lead without a model, and run no command it has no approval for', () async {
    final info = await start();
    await open(info.id);
    expect((await hostCall(info.id, 'diff_stats', const {}).result).text, contains('not a git repository'));
    expect((await hostCall(info.id, 'goal_check', const {}).result).text, contains('No goal is set'));
    final check = await hostCall(info.id, 'check', {
      'files': ['notes.txt'],
    }).result;
    expect(check.isError, true);
    expect(check.text, contains('No test found for: notes.txt'));
    // Ask mode and no approved row of the agent's: whoever holds the token can't run a command through the app.
    final bug = await hostCall(info.id, 'bug_check', {'action': 'reproduced', 'command': 'touch ran'}).result;
    expect(bug.isError, true);
    expect(bug.text, contains('approval'));
    expect(File('${project.path}/ran').existsSync(), isFalse);
    final floor = await hostCall(info.id, 'bug_check', {'action': 'reproduced', 'command': 'rm -rf ~'}).result;
    expect(floor.text, contains('EveryAI never runs this'));
    if (hostScriptsAvailable) {
      final script = await hostCall(info.id, 'run_script', {
        'code': 'console.log(await decide("x", []).catch(e => e.message))',
      }).result;
      expect(script.text, contains('decide is off here'));
    }
  });

  test('a host command runs once per approval, never for an open row nobody approved', () async {
    final info = await start();
    final c = await open(info.id);
    const args = {'action': 'reproduced', 'command': 'touch ran'};
    final ran = File('${project.path}/ran');
    // Codex pre-approves MCP tools: its row is open and running, and the user was never asked.
    session
      ..add(actionEvent(id: 'x1', toolName: 'everyai__bug_check', kind: 'MCPToolAction', args: args))
      ..add(stateEvent('x1-r', ExecutionStatus.running));
    await pumpEventQueue();
    var r = await hostCall(info.id, 'bug_check', args).result;
    expect(r.isError, isTrue);
    expect(r.text, contains('approval'));
    expect(ran.existsSync(), isFalse);
    session.add(resultEvent(id: 'x1-o', actionId: 'x1', toolName: 'everyai__bug_check', text: r.text));
    // The same call asked about and approved by the user runs, once.
    row('a1', 'bug_check', args);
    await pumpEventQueue();
    await c.approve();
    session.add(stateEvent('a1-r', ExecutionStatus.running));
    await pumpEventQueue();
    r = await hostCall(info.id, 'bug_check', args).result;
    expect(ran.existsSync(), isTrue);
    ran.deleteSync();
    r = await hostCall(info.id, 'bug_check', args).result;
    expect(r.isError, isTrue);
    expect(r.text, contains('approval'));
    expect(ran.existsSync(), isFalse);
  });

  test('an expired token gets a note at the next turn', () async {
    final info = await start();
    final c = await open(info.id);
    host.touchOk = false;
    await c.send('go on');
    final notices = stateOf(info.id).transcript.items.whereType<NoticeItem>().toList();
    // The briefing row comes first, with the text the agent was sent.
    expect(notices.first.message, briefingNotice);
    expect(notices.first.detail, isNotEmpty);
    expect(notices.last.message, hostToolsExpired);
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
    // A fresh container (an app restart) still shows the briefing row, with the text just sent.
    final notice = stateOf(info.id).transcript.items.whereType<NoticeItem>().first;
    expect(notice.message, briefingNotice);
    expect(notice.detail, again.sessionSkill);
  });

  test('a reopened session passes the approved MCP servers, minus one named like the app host', () async {
    final info = await start();
    final mcp = container.read(codeMcpServersProvider.notifier);
    mcp.put(
      const McpServer(name: 'charts', command: 'npx', args: ['-y', 'chart-mcp'], env: {'KEY': 'secret'}).approve(),
    );
    mcp.put(const McpServer(name: 'everyai', command: 'node', args: ['x.js']).approve());
    final prefs = container.read(preferencesProvider);
    container.dispose();
    container = make(prefs);
    await open(info.id);
    expect(drivers['test']!.reopenedMcp.single.keys, ['charts']);
  });

  test("a session's MCP report reaches Settings: pins and the tools to review", () async {
    final mcp = container.read(codeMcpServersProvider.notifier);
    mcp.put(const McpServer(name: 'dict', transport: McpTransport.http, url: 'https://dict.example/mcp'));
    final info = await start();
    await open(info.id);
    session.mcpReported.complete({
      'dict': const McpToolsReport(
        pin: {'lookup': 'd1'},
        pending: [
          McpToolReview(name: 'define', digest: 'e1', isNew: true, reasons: ['x']),
        ],
      ),
    });
    await pumpEventQueue();
    final dict = container.read(codeMcpServersProvider).global.single;
    expect(dict.pinned, {'lookup': 'd1'});
    expect([for (final p in dict.pending) p.name], ['define']);
  });

  test('a reopened EveryAI session gets the MCP servers and pins as they are now', () async {
    final info = await start();
    final mcp = container.read(codeMcpServersProvider.notifier);
    mcp.put(
      const McpServer(
        name: 'dict',
        transport: McpTransport.http,
        url: 'https://dict.example/mcp',
        pinned: {'lookup': 'd1'},
        pending: [McpToolReview(name: 'define', digest: 'e1')],
      ),
    );
    await container
        .read(codeSessionsProvider.notifier)
        .attachSession(CodeSessionInfo.fromJson({...info.toJson(), 'harness': everyaiHarnessName}));
    final reopened = drivers[everyaiHarnessName]!.reopenedWithMcp.single;
    // Its own harness vets per tool, so a server with tools to review still comes, with its pins.
    expect(reopened.keys, ['dict']);
    expect((reopened['dict']! as Map)['pinned'], {'lookup': 'd1'});
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

  group('screen tools', () {
    const counter = (id: 7, pid: 70, owner: 'counter', title: 'Counter', width: 800, height: 600);
    const mail = (id: 8, pid: 80, owner: 'Mail', title: 'Inbox', width: 900, height: 700);

    test("a screenshot of the session's own window comes back as a picture, with no card", () async {
      final info = await start();
      await open(info.id);
      screen
        ..windows = [mail, counter]
        ..sessionPids = {70};
      final call = hostCall(info.id, screenshotTool, const {});
      final r = await call.result;
      expect(r, (text: 'Captured counter (0 more)', isError: false));
      expect(screen.captured, [7]);
      expect(stateOf(info.id).transcript.openQuestion, isNull);
    });

    test("another app's window asks once, naming it; allowed, it is captured again without asking", () async {
      final info = await start();
      final c = await open(info.id);
      screen.windows = [mail];
      final first = hostCall(info.id, screenshotTool, const {'app': 'mail'});
      await pumpEventQueue();
      final card = stateOf(info.id).transcript.openQuestion!;
      expect(card.questions.single.question, contains('Mail — “Inbox”'));
      await c.answer(card, const [
        QuestionAnswer(selected: {0}),
      ]);
      expect((await first.result).isError, isFalse);
      expect(stateOf(info.id).transcript.openQuestion, isNull);
      final again = hostCall(info.id, screenshotTool, const {'window_id': 8});
      expect((await again.result).isError, isFalse);
      expect(screen.captured, [8, 8]);
    });

    test('a password manager or a banking page is never captured, not even in Bypass', () async {
      final info = await start(mode: AgentMode.bypass);
      await open(info.id);
      screen.windows = [
        mail,
        (id: 9, pid: 90, owner: 'Bitwarden', title: 'My vault', width: 900, height: 700),
        (id: 10, pid: 91, owner: 'Safari', title: 'Online Banking', width: 900, height: 700),
      ];
      final vault = await hostCall(info.id, screenshotTool, const {'app': 'Bitwarden'}).result;
      expect(vault.isError, isTrue);
      expect(vault.text, startsWith('Error: Skipped Bitwarden (a password manager): EveryAI never captures'));
      final bank = await hostCall(info.id, screenshotTool, const {'window_id': 10}).result;
      expect(bank.text, contains('Safari (looks like a banking or payment page)'));
      // Bypass still captures an ordinary window of another app without asking.
      expect((await hostCall(info.id, screenshotTool, const {'app': 'mail'}).result).isError, isFalse);
      expect(screen.captured, [8]);
      expect(stateOf(info.id).transcript.openQuestion, isNull);
    });

    test("a refused window isn't captured", () async {
      final info = await start();
      final c = await open(info.id);
      screen.windows = [mail];
      final call = hostCall(info.id, screenshotTool, const {'app': 'Mail'});
      await pumpEventQueue();
      await c.answer(stateOf(info.id).transcript.openQuestion!, const [
        QuestionAnswer(selected: {1}),
      ]);
      expect(await call.result, (text: "Error: the user didn't allow a screenshot of Mail.", isError: true));
      expect(screen.captured, isEmpty);
    });

    test('a chat message or Stop refuses the window and closes its card', () async {
      final info = await start();
      final c = await open(info.id);
      screen.windows = [mail];
      final chat = hostCall(info.id, screenshotTool, const {'app': 'mail'});
      await pumpEventQueue();
      await c.send('never mind');
      expect((await chat.result).isError, isTrue);
      expect(stateOf(info.id).transcript.openQuestion, isNull);
      final stopped = hostCall(info.id, screenshotTool, const {'app': 'mail'});
      await pumpEventQueue();
      expect(stateOf(info.id).transcript.openQuestion, isNotNull);
      await c.stop();
      expect((await stopped.result).isError, isTrue);
      expect(stateOf(info.id).transcript.openQuestion, isNull);
      expect(screen.captured, isEmpty);
    });

    test('a call that ends withdraws its card', () async {
      final info = await start();
      await open(info.id);
      screen.windows = [mail];
      final call = hostCall(info.id, screenshotTool, const {'app': 'mail'});
      await pumpEventQueue();
      call.end.complete(HostEnd.timedOut);
      expect((await call.result).isError, isTrue);
      expect(stateOf(info.id).transcript.openQuestion, isNull);
    });

    test('browser calls made together run one at a time, on one browser', () async {
      final info = await start();
      await open(info.id);
      final first = hostCall(info.id, browserTool, const {'action': 'open'});
      final second = hostCall(info.id, browserTool, const {'action': 'screenshot'});
      await pumpEventQueue();
      expect(screen.browsers, hasLength(1));
      final b = screen.browsers.single;
      expect(b.gates, hasLength(1));
      b.gates.single.complete();
      expect((await first.result).text, 'did open');
      await pumpEventQueue();
      expect(b.gates, hasLength(2));
      b.gates.last.complete();
      expect((await second.result).text, 'did screenshot');
      expect(b.mostAtOnce, 1);
    });

    test('removing a session ends its app and browser', () async {
      final info = await start();
      final c = await open(info.id);
      final browse = hostCall(info.id, browserTool, const {'action': 'open'});
      await pumpEventQueue();
      screen.browsers.single.gates.single.complete();
      await browse.result;
      screen.onSpawn = (p) => p.say('  Local:   http://localhost:3000/');
      File('${project.path}/pubspec.yaml').writeAsStringSync('name: counter\n');
      final run = hostCall(info.id, appRunTool, const {});
      await pumpEventQueue();
      await c.answer(stateOf(info.id).transcript.openQuestion!, const [
        QuestionAnswer(selected: {0}),
      ]);
      await run.result;
      expect(c.appRunPid, 1000);
      await container.read(codeSessionsProvider.notifier).remove(info.id);
      await pumpEventQueue();
      expect(screen.processes.single.closed, isTrue);
      expect(screen.browsers.single.closed, isTrue);
      expect(c.appRunPid, isNull);
    });

    test('off macOS a screenshot is not supported yet', () async {
      final info = await start();
      await open(info.id);
      screen.os = 'linux';
      final r = await hostCall(info.id, screenshotTool, const {}).result;
      expect(r.text, contains("aren't supported on Linux yet"));
      expect(r.isError, isTrue);
    });

    group('app_run', () {
      String localSettings() => File('${project.path}/.everyai/settings.local.json').readAsStringSync();

      setUp(() {
        File('${project.path}/pubspec.yaml').writeAsStringSync('name: counter\nflutter:\n');
      });

      /// Answers the run card with option [pick], or types [other].
      Future<void> confirm(CodeSessionController c, {int? pick, String other = ''}) async {
        await pumpEventQueue();
        final card = stateOf(c.sessionId).transcript.openQuestion!;
        await c.answer(card, [
          QuestionAnswer(selected: {?pick}, other: other),
        ]);
      }

      test('asks once, saves the command, starts it in the session and returns its windows', () async {
        final info = await start();
        final c = await open(info.id);
        screen.onSpawn = (p) =>
            screen.windows = [mail, (id: 9, pid: p.pid, owner: 'counter', title: '', width: 800, height: 600)];
        final first = hostCall(info.id, appRunTool, const {});
        await pumpEventQueue();
        final card = stateOf(info.id).transcript.openQuestion!;
        expect(card.questions.single.options.first.label, 'flutter run -d macos (Recommended)');
        expect(card.questions.single.options.last.label, "Don't run it");
        await confirm(c, pick: 0);
        final r = await first.result;
        expect(r.isError, isFalse);
        expect(r.text, contains('- window_id 9: counter (800x600)'));
        expect(r.text, isNot(contains('window_id 8')));
        expect(screen.spawned.single, (command: 'flutter run -d macos', cwd: info.workingDir, tag: info.id));
        expect(jsonDecode(localSettings()), {
          'run': {'command': 'flutter run -d macos'},
        });
        expect(jsonDecode(container.read(preferencesProvider)['code.run_commands']!), {
          project.path: 'flutter run -d macos',
        });
        // Again: the running copy, no card, no second start.
        final again = await hostCall(info.id, appRunTool, const {}).result;
        expect(again.text, startsWith('The app is already running'));
        expect(screen.spawned, hasLength(1));
        // A restart after it is stopped runs the saved command without asking.
        final restarted = await hostCall(info.id, appRunTool, const {'restart': true}).result;
        expect(restarted.text, startsWith('Started `flutter run -d macos`'));
        expect(screen.spawned, hasLength(2));
        expect(screen.processes.first.closed, isTrue);
      });

      test("a command in the settings file the user didn't confirm here asks again", () async {
        Directory('${project.path}/.everyai').createSync();
        File('${project.path}/.everyai/settings.local.json').writeAsStringSync('{"run": {"command": "make planted"}}');
        final info = await start();
        final c = await open(info.id);
        final call = hostCall(info.id, appRunTool, const {});
        await pumpEventQueue();
        final options = stateOf(info.id).transcript.openQuestion!.questions.single.options;
        expect(
          [for (final o in options) o.label],
          ['make planted', 'flutter run -d macos (Recommended)', "Don't run it"],
        );
        await confirm(c, pick: 2);
        expect(await call.result, (text: 'Error: the user chose not to run the app.', isError: true));
        expect(screen.spawned, isEmpty);
      });

      test('a command the floor refuses never runs', () async {
        final info = await start();
        final c = await open(info.id);
        final call = hostCall(info.id, appRunTool, const {'command': 'rm -rf ~'});
        await pumpEventQueue();
        final options = stateOf(info.id).transcript.openQuestion!.questions.single.options;
        expect(options.any((o) => o.label.contains('rm -rf')), isFalse);
        await confirm(c, other: 'rm -rf ~');
        final r = await call.result;
        expect(r.isError, isTrue);
        expect(r.text, startsWith('Not run:'));
        expect(screen.spawned, isEmpty);
      });

      test('Plan mode refuses it', () async {
        final info = await start(mode: AgentMode.plan);
        await open(info.id);
        final r = await hostCall(info.id, appRunTool, const {}).result;
        expect(r.isError, isTrue);
        expect(r.text, startsWith('Not run: Plan mode'));
        expect(stateOf(info.id).transcript.openQuestion, isNull);
      });

      test('an app that exits returns its code and output; a dev server its URL', () async {
        final info = await start();
        final c = await open(info.id);
        screen.onSpawn = (p) => p
          ..say('error: no device')
          ..exit(1);
        final failed = hostCall(info.id, appRunTool, const {});
        await confirm(c, pick: 0);
        expect(await failed.result, (
          text: 'Error: `flutter run -d macos` exited with code 1.\nOutput so far:\nerror: no device',
          isError: true,
        ));
        // The next call starts it again (the trusted command, no card).
        screen.onSpawn = (p) => p
          ..say('A Dart VM Service on macOS is available at: http://127.0.0.1:50001/abc=/')
          ..say('  Local:   http://localhost:5173/');
        final served = await hostCall(info.id, appRunTool, const {}).result;
        expect(served.text, contains('It serves http://localhost:5173/: open it with browser.'));
        expect(screen.spawned, hasLength(2));
      });

      test('Stop and closing the session end the app', () async {
        final info = await start();
        final c = await open(info.id);
        screen.onSpawn = (p) => p.say('  Local:   http://localhost:3000/');
        final call = hostCall(info.id, appRunTool, const {});
        await confirm(c, pick: 0);
        await call.result;
        await c.stop();
        expect(screen.processes.single.closed, isTrue);
        await hostCall(info.id, appRunTool, const {}).result;
        expect(screen.processes, hasLength(2));
        container.dispose();
        await pumpEventQueue();
        expect(screen.processes.last.closed, isTrue);
      });

      test('Stop while the app starts ends it once it has started', () async {
        final info = await start();
        final c = await open(info.id);
        screen.spawnGate = Completer();
        final call = hostCall(info.id, appRunTool, const {});
        await confirm(c, pick: 0);
        await screen.spawning.future;
        await c.stop();
        screen.spawnGate!.complete();
        final r = await call.result;
        expect(r.isError, isTrue);
        expect(r.text, contains('was stopped'));
        expect(screen.processes.single.closed, isTrue);
        expect(c.appRunPid, isNull);
      });

      test('two calls at once start one copy', () async {
        final info = await start();
        final c = await open(info.id);
        screen.onSpawn = (p) => p.say('  Local:   http://localhost:3000/');
        final first = hostCall(info.id, appRunTool, const {});
        final second = hostCall(info.id, appRunTool, const {});
        await confirm(c, pick: 0);
        expect((await first.result).isError, isFalse);
        expect((await second.result).text, contains('http://localhost:3000/'));
        expect(screen.spawned, hasLength(1));
        expect(stateOf(info.id).transcript.openQuestion, isNull);
      });

      test('a run card nobody answers is given up', () async {
        screen.cardLimit = Duration.zero;
        final info = await start();
        await open(info.id);
        final r = await hostCall(info.id, appRunTool, const {}).result;
        expect(r, (text: "Error: the user didn't confirm a run command, so the app wasn't started.", isError: true));
        expect(stateOf(info.id).transcript.openQuestion, isNull);
        expect(screen.spawned, isEmpty);
      });

      test("an older copy of the app built in the folder isn't the new one's window", () async {
        final info = await start();
        final c = await open(info.id);
        const old = (id: 5, pid: 50, owner: 'counter', title: 'old', width: 800, height: 600);
        screen
          ..windows = [old]
          ..executables[50] = '${info.workingDir}/build/counter.app/Contents/MacOS/counter'
          ..executables[60] = '${info.workingDir}/build/counter.app/Contents/MacOS/counter';
        // The new build opens with `open`: not in the tree, but new and run from the folder.
        screen.onSpawn = (_) =>
            screen.windows = [old, (id: 6, pid: 60, owner: 'counter', title: 'new', width: 800, height: 600)];
        final call = hostCall(info.id, appRunTool, const {});
        await confirm(c, pick: 0);
        final r = await call.result;
        expect(r.text, contains('window_id 6'));
        expect(r.text, isNot(contains('window_id 5')));
      });

      test('off macOS it stops waiting for a window and says why', () async {
        screen.os = 'linux';
        final info = await start();
        final c = await open(info.id);
        final call = hostCall(info.id, appRunTool, const {});
        await confirm(c, pick: 0);
        final r = await call.result;
        expect(r.isError, isFalse);
        expect(r.text, contains("can't see app windows on Linux yet"));
        expect(screen.spawned.single.command, 'flutter run -d linux');
      });

      test('a server that prints no URL is found by its port', () async {
        File('${project.path}/pubspec.yaml').deleteSync();
        File('${project.path}/go.mod').writeAsStringSync('module x\n');
        final info = await start();
        final c = await open(info.id);
        screen.ports = [const ListeningPort(pid: 1000, port: 8080)];
        final call = hostCall(info.id, appRunTool, const {});
        await confirm(c, pick: 0);
        final r = await call.result;
        expect(r.text, contains('It listens on http://localhost:8080'));
      });

      test("Windows isn't supported yet", () async {
        final info = await start();
        await open(info.id);
        screen.os = 'windows';
        final r = await hostCall(info.id, appRunTool, const {}).result;
        expect((r.isError, r.text), (true, "Error: app_run isn't supported on Windows yet."));
      });
    });
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

final class _MemoryStore implements SecretStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// The screen as the tests set it: windows, the session's processes, what was captured and started.
final class _FakeScreen {
  var os = 'macos';
  var windows = <ScreenWindow>[];
  var sessionPids = <int>{};
  final captured = <int>[];
  final spawned = <({String command, String cwd, String tag})>[];
  final processes = <_FakeProcess>[];
  void Function(_FakeProcess p)? onSpawn;

  /// Holds each spawn until completed, when set; [spawning] completes when one waits there.
  Completer<void>? spawnGate;
  final spawning = Completer<void>();
  final executables = <int, String>{};
  var ports = <ListeningPort>[];
  var cardLimit = const Duration(seconds: 300);
  final browsers = <_FakeBrowser>[];

  late final access = ScreenAccess(
    os: os,
    listWindows: () async => windows,
    executableOf: (pid) async => executables[pid] ?? '/Applications/App.app/Contents/MacOS/App',
    capture: (w, root, others) async {
      captured.add(w.id);
      return (
        text: 'Captured ${w.owner} ($others more)',
        isError: false,
        images: const [(mime: 'image/png', data: 'AA==')],
      );
    },
    sessionPids: ({required tag, required workingDir, required ownsDir}) async => sessionPids,
    processTree: (pid) async => {pid},
    spawn: ({required command, required cwd, required sessionTag, required logPath}) async {
      spawned.add((command: command, cwd: cwd, tag: sessionTag));
      if (!spawning.isCompleted) spawning.complete();
      await spawnGate?.future;
      final p = _FakeProcess(1000 + processes.length);
      processes.add(p);
      onSpawn?.call(p);
      return p;
    },
    browser: (_) {
      final b = _FakeBrowser();
      browsers.add(b);
      return b;
    },
    listening: (pids) async => [
      for (final p in ports)
        if (pids.contains(p.pid)) p,
    ],
    poll: () async {},
    cardLimit: cardLimit,
  );
}

/// A browser whose calls wait until the test lets them finish.
final class _FakeBrowser implements ScreenBrowser {
  final gates = <Completer<void>>[];
  var running = 0, mostAtOnce = 0;
  var closed = false;

  @override
  Future<ScreenResult> run(Map<String, Object?> args, String root) async {
    mostAtOnce = max(mostAtOnce, ++running);
    final gate = Completer<void>();
    gates.add(gate);
    await gate.future;
    running--;
    return (text: 'did ${args['action']}', isError: false, images: const <HostImage>[]);
  }

  @override
  Future<void> close() async => closed = true;
}

final class _FakeProcess implements DriverProcess {
  _FakeProcess(this.pid);
  @override
  final int pid;
  final _lines = StreamController<String>.broadcast(sync: true);
  final _exit = Completer<int>();
  final _said = <String>[];
  var closed = false;

  /// A line of output, kept for a listener that comes later.
  void say(String line) {
    _said.add(line);
    _lines.add(line);
  }

  void exit(int code) => _exit.complete(code);

  @override
  Stream<String> get lines async* {
    yield* Stream.fromIterable([..._said]);
    yield* _lines.stream;
  }

  @override
  Future<int> get exitCode => _exit.future;
  @override
  String get lastError => '';
  @override
  void send(String line) {}
  @override
  Future<void> close() async {
    closed = true;
    if (!_exit.isCompleted) _exit.complete(-15);
  }
}
