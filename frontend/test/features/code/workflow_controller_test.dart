import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/net/api_client.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/code_settings_providers.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/domain/permissions.dart' show ApprovalScope;
import 'package:every_ai/features/code/drivers/acp/acp_mapping.dart' show agentMessageEvent;
import 'package:every_ai/features/code/drivers/driver_events.dart';
import 'package:every_ai/features/code/drivers/driver_registry.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/harness.dart' show NativeMode;
import 'package:every_ai/features/code/host/host.dart';
import 'package:every_ai/features/code/host/host_prompts.dart';
import 'package:every_ai/features/code/host/host_providers.dart';
import 'package:every_ai/features/code/workflows/workflow_engine.dart';
import 'package:every_ai/features/code/workflows/workflow_runs.dart';
import 'package:every_ai/features/models/models_providers.dart';
import 'package:every_ai/features/usage/usage_totals.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../../support/fake_leads.dart';
import 'workflow_fakes.dart';

// A workflow run from a session's controller: its agents are child
// sessions on whichever harness each call names.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late Directory tmp;
  late Directory project;
  late FakeLeadSession lead;
  late Map<String, FakeLeadDriver> drivers;
  late ProviderContainer container;
  late FakeBridge bridge;
  late Map<String, UsageTotals> usage;
  late Preferences prefs;
  Map<String, Object?>? startedArgs;
  String? startedSource;

  Future<void> git(List<String> args) async {
    final r = await Process.run('git', args, workingDirectory: project.path);
    if (r.exitCode != 0) throw StateError('git ${args.join(' ')}: ${r.stderr}');
  }

  /// The app on the same database, drivers and data folder: a second one is a restart.
  ProviderContainer makeContainer() => ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      preferencesProvider.overrideWithValue(prefs),
      modelCatalogProvider.overrideWith(FixedCatalog.new),
      codeUsageProvider.overrideWithBuild((ref, n) async => usage[n.sessionId] ?? UsageTotals.zero),
      driverRegistryProvider.overrideWithValue(DriverRegistry({...drivers})),
      hostServerProvider.overrideWithValue(FakeHost()),
      driverDataDirProvider.overrideWithValue(() async => '${tmp.path}/data'),
      apiClientProvider.overrideWithValue(
        ApiClient(
          baseUrl: Uri.parse('http://backend/'),
          client: MockClient((req) async => http.Response('no network in this test', 599)),
        ),
      ),
      codeSideModelProvider.overrideWithValue((messages) async => ''),
      workflowBridgeProvider.overrideWithValue(({required dir, required source, required args}) async {
        startedArgs = args;
        startedSource = source;
        return bridge;
      }),
    ],
  );

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    tmp = await Directory.systemTemp.createTemp('workflow-controller');
    project = await Directory('${tmp.path}/project').create();
    lead = FakeLeadSession();
    bridge = FakeBridge();
    usage = {};
    drivers = {
      'test': FakeLeadDriver('test', session: lead),
      'fake2': FakeLeadDriver('fake2', label: 'Second CLI'),
      'cli': FakeLeadDriver('cli', needsConsent: true, label: 'Gated CLI'),
    };
    prefs = await Preferences.load(db);
    prefs['code.projects'] = jsonEncode([CodeProject(id: 'p1', name: 'P', path: project.path).toJson()]);
    container = makeContainer();
  });

  tearDown(() async {
    container.dispose();
    await db.close();
    await tmp.delete(recursive: true);
  });

  Future<CodeSessionController> open() async {
    final info = await container
        .read(codeSessionsProvider.notifier)
        .start(
          project: container.read(codeProjectsProvider).single,
          prompt: 'Lead the work',
          model: '',
          mode: AgentMode.autoEdit,
          harness: 'test',
        );
    container.listen(codeSessionProvider(info.id), (_, _) {});
    await whenValue(container, codeSessionProvider(info.id).select((s) => s.connected), (bool c) => c);
    return container.read(codeSessionProvider(info.id).notifier);
  }

  Future<CodeSessionInfo> child() => whenValue(
    container,
    codeSessionsProvider,
    (List<CodeSessionInfo> all) => all.any((s) => s.parentCallId.startsWith('wf-')),
  ).then((all) => all.firstWhere((s) => s.parentCallId.startsWith('wf-')));

  /// The child's agent answers [text] and ends its turn.
  void answer(FakeLeadSession s, String text) => s
    ..add(stateEvent('${s.id}-r', ExecutionStatus.running))
    ..add(agentMessageEvent('${s.id}-m', text))
    ..add(stateEvent('${s.id}-f', ExecutionStatus.finished));

  test('an agent on another harness is a child session there, and the result goes to the lead', () async {
    final c = await open();
    final runId = await c.runWorkflow('demo', 'source', args: {'n': 1});
    final reply = bridge.agent('Fix the bug', {'harness': 'fake2', 'label': 'Fixer'});
    final info = await child();
    expect(info.harness, 'fake2');
    expect(info.parentId, c.sessionId);
    expect(info.parentCallId, startsWith('wf-$runId-'));
    expect(info.title, 'Fixer');
    final s = drivers['fake2']!.latest!;
    expect(s.sent.single, contains('Fix the bug'));
    answer(s, 'Fixed it');
    expect(await reply, 'Fixed it');
    bridge.finish({'fixed': true});
    final runs = await whenValue(
      container,
      workflowRunsProvider(c.sessionId),
      (List<WorkflowRun> r) => r.isNotEmpty && r.single.status == WorkflowStatus.done,
    );
    expect(runs.single.agents.single.harness, 'fake2');
    await pumpEventQueue();
    expect(lead.sent.last, startsWith('<workflow-result name="demo" status="done">'));
    expect(lead.sent.last, contains('"fixed":true'));
    // An ended run's journal is kept aside, so opening the session doesn't read it again.
    final dir = '${tmp.path}/data/workflows/${c.sessionId}';
    expect(File('$dir/$runId.done.jsonl').existsSync(), isTrue);
    expect(File('$dir/$runId.jsonl').existsSync(), isFalse);
  });

  HostCall runCall(Map<String, Object?> args) =>
      HostCall(id: 'h1', sessionId: '', name: runWorkflowTool, args: args, ended: Completer<HostEnd>().future);

  test('run_workflow starts a listed workflow at once, and its result waits for the lead\'s turn to end', () async {
    final c = await open();
    expect([for (final p in await c.workflowPrompts()) p.id], ['ultra', 'bugfix', 'security_review']);
    var r = await c.call(runCall({'id': 'nope'}));
    expect(r.isError, isTrue);
    expect(r.text, contains('It can run: ultra, bugfix, security_review'));
    r = await c.call(runCall({'id': 'ultra', 'args': 'x'}));
    expect(r.isError, isTrue);

    r = await c.call(
      runCall({
        'id': 'security_review',
        'args': {'base': 'main'},
      }),
    );
    expect(r.isError, isFalse);
    expect(r.text, startsWith('Started Security review (run '));
    await pumpEventQueue();
    expect(startedSource, contains("id: 'security_review'"));
    expect(startedArgs!['base'], 'main');
    // The script's ctx: the run, the lead, and no review model on an outside lead (it would spend).
    final ctx = startedArgs!['_ctx']! as Map;
    expect(r.text, contains('${ctx['runId']}'));
    expect(ctx['lead'], {'harness': 'test', 'model': ''});
    expect(ctx['review'], isNull);

    // One run at a time: a second call is refused while this one runs.
    r = await c.call(
      runCall({
        'id': 'bugfix',
        'args': {'bug': 'x'},
      }),
    );
    expect(r.isError, isTrue);
    expect(r.text, contains('already running in this session (run ${ctx['runId']})'));

    // The lead is mid-turn when the run ends: the result goes after it, not into the user's queue.
    final before = lead.sent.length;
    lead.add(stateEvent('busy', ExecutionStatus.running));
    await whenValue(container, codeSessionProvider(c.sessionId).select((s) => s.transcript.running), (bool b) => b);
    bridge.finish({'findings': <Object>[]});
    await pumpEventQueue();
    expect(container.read(codeSessionProvider(c.sessionId)).queued, isEmpty);
    expect(lead.sent.length, before);
    // Stop clears the user's queue; the result stays and goes once the lead is idle.
    await c.stop();
    lead.add(stateEvent('idle', ExecutionStatus.finished));
    for (var i = 0; i < 50 && !lead.sent.any((m) => m.contains('<workflow-result')); i++) {
      await pumpEventQueue();
    }
    expect(lead.sent.where((m) => m.contains('<workflow-result')), hasLength(1));
    expect(lead.sent.last, startsWith('<workflow-result name="Security review" status="done">'));
    // The run ended, so another may start.
    r = await c.call(
      runCall({
        'id': 'bugfix',
        'args': {'bug': 'x'},
      }),
    );
    expect(r.isError, isFalse);
  });

  test('a read-only agent asks before writes and commands, even when the lead is in Full auto', () async {
    final c = await open();
    await c.setMode(AgentMode.fullAuto);
    await c.runWorkflow('demo', 'source');
    unawaited(bridge.agent('Review', {'harness': 'fake2', 'readOnly': true}).catchError((Object _) => null));
    expect((await child()).mode, AgentMode.ask);
  });

  test('agents start in the lead\'s mode, and allowing a call for all forks settles the waiting siblings', () async {
    final c = await open();
    await c.setMode(AgentMode.ask);
    await c.runWorkflow('demo', 'source');
    unawaited(bridge.agent('One', {'harness': 'fake2'}).catchError((Object _) => null));
    unawaited(bridge.agent('Two', {'harness': 'fake2'}).catchError((Object _) => null));
    final kids = await whenValue(
      container,
      codeSessionsProvider,
      (List<CodeSessionInfo> all) => all.where((s) => s.parentCallId.startsWith('wf-')).length == 2,
    ).then((all) => all.where((s) => s.parentCallId.startsWith('wf-')).toList());
    expect(kids.map((k) => k.mode), everyElement(AgentMode.ask));
    final sessions = drivers['fake2']!.conversations.values.toList();
    expect(sessions, hasLength(2));
    for (final k in kids) {
      container.listen(codeSessionProvider(k.id), (_, _) {});
    }
    // Both ask to run the same command.
    for (final (i, s) in sessions.indexed) {
      s
        ..add(actionEvent(id: 'a$i', toolName: 'bash', kind: 'TerminalAction', args: {'command': 'npm test'}))
        ..add(stateEvent('w$i', ExecutionStatus.waitingForConfirmation));
    }
    for (final k in kids) {
      await whenValue(
        container,
        codeSessionProvider(k.id).select((s) => s.transcript.pending.length),
        (int n) => n == 1,
      );
    }
    expect(sessions.map((s) => s.answers), everyElement(isEmpty));
    final first = container.read(codeSessionProvider(kids.first.id).notifier);
    expect(first.askReasons().values.single, 'Ask mode asks before every edit and command.');
    // Which kid owns which conversation: the one the first controller answers.
    await first.approve(ApprovalScope.session);
    await pumpEventQueue();
    expect(sessions.map((s) => s.answers.map((a) => a.accept).toList()), everyElement([true]));
    // Remembered in the lead's session scope, so the lead's own call runs too.
    expect(c.policy.session, contains('npm test *'));
  });

  test("a read-only agent neither uses nor adds to the lead's session approvals", () async {
    final c = await open();
    await c.setMode(AgentMode.ask);
    lead
      ..add(actionEvent(id: 'l1', toolName: 'bash', kind: 'TerminalAction', args: {'command': 'npm test'}))
      ..add(stateEvent('lw', ExecutionStatus.waitingForConfirmation));
    await whenValue(
      container,
      codeSessionProvider(c.sessionId).select((s) => s.transcript.pending.length),
      (int n) => n == 1,
    );
    await c.approve(ApprovalScope.session);
    expect(c.policy.session, contains('npm test *'));
    await c.runWorkflow('demo', 'source');
    unawaited(bridge.agent('Review', {'harness': 'fake2', 'readOnly': true}).catchError((Object _) => null));
    final kid = await child();
    expect(kid.ownApprovals, isTrue);
    expect(kid.sharesApprovals, isFalse);
    container.listen(codeSessionProvider(kid.id), (_, _) {});
    final reviewer = container.read(codeSessionProvider(kid.id).notifier);
    expect(reviewer.policy.session, isNot(contains('npm test *')));
    final s = drivers['fake2']!.conversations.values.single;
    s
      ..add(actionEvent(id: 'r1', toolName: 'bash', kind: 'TerminalAction', args: {'command': 'npm test'}))
      ..add(stateEvent('rw', ExecutionStatus.waitingForConfirmation));
    await whenValue(
      container,
      codeSessionProvider(kid.id).select((s) => s.transcript.pending.length),
      (int n) => n == 1,
    );
    expect(s.answers, isEmpty);
    // Its own "for this session" stays its own.
    s
      ..add(actionEvent(id: 'r2', toolName: 'bash', kind: 'TerminalAction', args: {'command': 'make lint'}))
      ..add(stateEvent('rw2', ExecutionStatus.waitingForConfirmation));
    await reviewer.approve(ApprovalScope.session);
    expect(reviewer.policy.session, isNotEmpty);
    expect(c.policy.session, isNot(contains('make lint *')));
  });

  test("a user's no tells the agent why the app asked", () async {
    final c = await open();
    await c.setMode(AgentMode.ask);
    lead
      ..add(actionEvent(id: 'x1', toolName: 'bash', kind: 'TerminalAction', args: {'command': 'npm test'}))
      ..add(stateEvent('xw', ExecutionStatus.waitingForConfirmation));
    await whenValue(
      container,
      codeSessionProvider(c.sessionId).select((s) => s.transcript.pending.length),
      (int n) => n == 1,
    );
    await c.deny('use yarn');
    final reason = lead.answers.last.reason!;
    expect(reason, contains("It needed the user's OK because: Ask mode asks before every edit and command."));
    expect(reason, endsWith('use yarn'));
  });

  group('native modes', () {
    const ask = NativeMode(id: 'default', label: 'Default', policy: AgentMode.ask);
    const edits = NativeMode(id: 'acceptEdits', label: 'Accept edits', policy: AgentMode.autoEdit);
    const auto = NativeMode(id: 'auto', label: 'Auto', policy: AgentMode.fullAuto);

    Future<CodeSessionController> openOn(String harness, AgentMode mode) async {
      final info = await container
          .read(codeSessionsProvider.notifier)
          .start(
            project: container.read(codeProjectsProvider).single,
            prompt: 'Lead the work',
            model: '',
            mode: mode,
            harness: harness,
          );
      container.listen(codeSessionProvider(info.id), (_, _) {});
      await whenValue(container, codeSessionProvider(info.id).select((s) => s.connected), (bool c) => c);
      // The mode feed's listener is on before the test sets modes.
      await pumpEventQueue();
      return container.read(codeSessionProvider(info.id).notifier);
    }

    test('a Full auto session whose first list lacks auto moves there once a later list has it', () async {
      final c = await openOn('fake2', AgentMode.fullAuto);
      final s = drivers['fake2']!.latest!;
      s.modeFeed.set(modes: [ask, edits], current: 'default');
      await pumpEventQueue();
      expect(s.picked, ['acceptEdits']);
      s.modeFeed.set(modes: [ask, edits, auto]);
      await pumpEventQueue();
      expect(s.picked, ['acceptEdits', 'auto']);
      expect(container.read(codeSessionProvider(c.sessionId)).mode, AgentMode.fullAuto);
      // Once there, nothing more moves it.
      s.modeFeed.set(modes: [ask, edits, auto]);
      await pumpEventQueue();
      expect(s.picked, hasLength(2));
    });

    test('a mode the user picks meanwhile wins over the one the session started in', () async {
      final c = await openOn('fake2', AgentMode.fullAuto);
      final s = drivers['fake2']!.latest!;
      s.modeFeed.set(modes: [ask, edits], current: 'default');
      await pumpEventQueue();
      await c.setNativeMode('default');
      s.modeFeed.set(modes: [ask, edits, auto]);
      await pumpEventQueue();
      expect(s.picked, ['acceptEdits', 'default']);
    });

    test("an agent in the lead's mode gets its native mode too; a read-only one doesn't", () async {
      final c = await openOn('fake2', AgentMode.fullAuto);
      final s = drivers['fake2']!.latest!;
      s.modeFeed.set(modes: [ask, edits, auto], current: 'default');
      await pumpEventQueue();
      expect(container.read(codeSessionsProvider.notifier).byId(c.sessionId)!.nativeMode, 'auto');
      await c.runWorkflow('demo', 'source');
      unawaited(bridge.agent('Review', {'harness': 'fake2', 'readOnly': true}).catchError((Object _) => null));
      final reviewer = await child();
      expect((reviewer.mode, reviewer.nativeMode), (AgentMode.ask, ''));
      container.listen(codeSessionProvider(reviewer.id), (_, _) {});
      await pumpEventQueue();
      final rs = drivers['fake2']!.latest!;
      rs.modeFeed.set(modes: [ask, edits, auto], current: 'default');
      await pumpEventQueue();
      expect(rs.picked, isEmpty);
      unawaited(bridge.agent('Fix', {'harness': 'fake2'}).catchError((Object _) => null));
      final fixer = await whenValue(
        container,
        codeSessionsProvider,
        (List<CodeSessionInfo> all) => all.any((k) => k.title == 'Fix' || (k.parentId != null && k.id != reviewer.id)),
      ).then((all) => all.firstWhere((k) => k.parentId != null && k.id != reviewer.id));
      expect((fixer.mode, fixer.nativeMode), (AgentMode.fullAuto, 'auto'));
    });
  });

  test("an agent can list the workflow prompts before its session's start returns", () async {
    final gate = drivers['test']!.startGate = Completer<void>();
    final starting = container
        .read(codeSessionsProvider.notifier)
        .start(
          project: container.read(codeProjectsProvider).single,
          prompt: 'Lead the work',
          model: '',
          mode: AgentMode.autoEdit,
          harness: 'test',
        );
    final host = container.read(hostServerProvider) as FakeHost;
    for (var i = 0; i < 50 && host.tools.isEmpty; i++) {
      await pumpEventQueue();
    }
    // Gemini over ACP lists prompts inside session/new, which is what the start waits for.
    final prompts = await (host.tools.values.single as HostPrompts).workflowPrompts();
    expect([for (final p in prompts) p.id], ['ultra', 'bugfix', 'security_review']);
    gate.complete();
    await starting;
  });

  test('a schema reply that misses gets its repair message in the same child', () async {
    final c = await open();
    await c.runWorkflow('demo', 'source');
    final reply = bridge.agent('Review', {
      'harness': 'fake2',
      'schema': {
        'type': 'object',
        'required': ['ok'],
      },
    });
    await child();
    final s = drivers['fake2']!.latest!;
    answer(s, 'Looks fine');
    // The repair goes through the child's own send, which reads its folder first.
    for (var i = 0; i < 50 && s.sent.length < 2; i++) {
      await pumpEventQueue();
    }
    expect(s.sent.last, contains("doesn't match the schema"));
    answer(s, '```json\n{"ok": true}\n```');
    expect(await reply, {'ok': true});
    expect(drivers['fake2']!.specs, hasLength(1));
  });

  test('a harness that needs consent refuses the agent', () async {
    final c = await open();
    await c.runWorkflow('demo', 'source');
    await expectLater(bridge.agent('Fix', {'harness': 'cli'}), throwsA(contains('Use my own installed CLIs')));
    expect(drivers['cli']!.specs, isEmpty);
  });

  test('a worktree agent works in its own copy, merged back when it finishes', () async {
    await git(['init', '-q']);
    File('${project.path}/a.txt').writeAsStringSync('one\n');
    await git(['add', '.']);
    await git(['-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'init']);
    final c = await open();
    await c.runWorkflow('demo', 'source');
    final reply = bridge.agent('Add b', {'harness': 'fake2', 'worktree': true});
    final info = await child();
    expect(info.workingDir, isNot(project.path));
    expect(info.forkCopy, isNotNull);
    File('${info.workingDir}/b.txt').writeAsStringSync('two\n');
    answer(drivers['fake2']!.latest!, 'Added b');
    final text = await reply as String;
    expect(text, startsWith('Added b'));
    expect(text, contains('b.txt'));
    expect(File('${project.path}/b.txt').readAsStringSync(), 'two\n');
  });

  Future<void> repo() async {
    await git(['init', '-q']);
    File('${project.path}/a.txt').writeAsStringSync('one\n');
    await git(['add', '.']);
    await git(['-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'init']);
  }

  test('while the lead plans, the work of a worktree agent is kept on its ref, not merged', () async {
    await repo();
    final c = await open();
    await c.setMode(AgentMode.plan);
    await c.runWorkflow('demo', 'source');
    final reply = bridge.agent('Add b', {'harness': 'fake2', 'worktree': true});
    final info = await child();
    File('${info.workingDir}/b.txt').writeAsStringSync('two\n');
    answer(drivers['fake2']!.latest!, 'Added b');
    final text = await reply as String;
    expect(text, contains('Not merged while planning'));
    expect(File('${project.path}/b.txt').existsSync(), isFalse);
  });

  test('stopping the run ends the watch on a working agent, so its worktree is settled', () async {
    await repo();
    final c = await open();
    final runId = await c.runWorkflow('demo', 'source');
    final reply = bridge.agent('Add b', {'harness': 'fake2', 'worktree': true});
    final info = await child();
    drivers['fake2']!.latest!.add(stateEvent('s-r', ExecutionStatus.running));
    await pumpEventQueue();
    c.stopWorkflow(runId);
    await expectLater(reply, throwsA(anything));
    await whenValue(
      container,
      codeSessionsProvider,
      (List<CodeSessionInfo> all) => all.firstWhere((s) => s.id == info.id).forkCopy == null,
    );
  });

  test('a run the app quit in the middle of carries on when the session opens again', () async {
    final c = await open();
    final id = c.sessionId;
    final runId = await c.runWorkflow('demo', 'the source', args: {'n': 2});
    // Killed with the script: nobody hears this one.
    unawaited(bridge.agent('Fix', {'harness': 'fake2'}).catchError((Object _) => null));
    final first = await child();
    // Still at work: the session closed, not the app.
    drivers['fake2']!.latest!.add(stateEvent('w-r', ExecutionStatus.running));
    // The app quits: the script dies, the journal has the spawn but no answer.
    final old = bridge;
    bridge = FakeBridge();
    container.invalidate(codeSessionProvider(id));
    await pumpEventQueue();
    expect(old.killed, isTrue);
    final journal = File('${tmp.path}/data/workflows/$id/$runId.jsonl').readAsLinesSync();
    expect(journal.map((l) => (jsonDecode(l) as Map)['t']), ['start', 'spawn']);
    final runs = await whenValue(
      container,
      workflowRunsProvider(id),
      (List<WorkflowRun> r) => r.isNotEmpty && r.last.status == WorkflowStatus.running && r.last.agents.isEmpty,
    );
    expect(runs.last.runId, runId);
    // The script runs again: the same call reattaches to the child it started.
    final again = bridge.agent('Fix', {'harness': 'fake2'});
    await pumpEventQueue();
    answer(drivers['fake2']!.latest!, 'Fixed');
    expect(await again, 'Fixed');
    expect(drivers['fake2']!.specs, hasLength(1));
    expect(container.read(codeSessionsProvider).where((s) => s.parentId == id).single.id, first.id);
    expect(drivers['fake2']!.latest!.sent.where((m) => m.contains(workflowCarryOn)), isEmpty);
  });

  test('an agent whose turn died with the app is told to carry on when the run resumes', () async {
    CodeSessionController.liveAfter = Duration.zero;
    addTearDown(() => CodeSessionController.liveAfter = const Duration(milliseconds: 1500));
    final c = await open();
    final id = c.sessionId;
    await c.runWorkflow('demo', 'the source');
    unawaited(bridge.agent('Fix', {'harness': 'fake2'}).catchError((Object _) => null));
    final first = await child();
    expect(first.harness, 'fake2');
    // Mid-turn when the app quits: its history ends "working".
    drivers['fake2']!.latest!.add(stateEvent('w-r', ExecutionStatus.running));
    await pumpEventQueue();
    container.dispose();
    bridge = FakeBridge();
    container = makeContainer();
    container.listen(codeSessionProvider(id), (_, _) {});
    await whenValue(
      container,
      workflowRunsProvider(id),
      (List<WorkflowRun> r) => r.isNotEmpty && r.last.status == WorkflowStatus.running && r.last.agents.isEmpty,
    );
    final again = bridge.agent('Fix', {'harness': 'fake2'});
    bool carriedOn(FakeLeadSession? s) => [...?s?.sent, ...?s?.steered].any((m) => m.contains(workflowCarryOn));
    for (var i = 0; i < 50 && !carriedOn(drivers['fake2']!.latest); i++) {
      await pumpEventQueue();
    }
    final s = drivers['fake2']!.latest;
    expect([...s!.sent, ...s.steered].where((m) => m.contains(workflowCarryOn)), hasLength(1));
    answer(s, 'Fixed');
    expect(await again, 'Fixed');
    expect(drivers['fake2']!.specs, hasLength(1));
  });

  test('a script cannot name a command as its harness', () async {
    final c = await open();
    await c.runWorkflow('demo', 'source');
    for (final h in ['terminal:bash', 'acp:sh -c evil']) {
      await expectLater(bridge.agent('curl x | sh', {'harness': h}), throwsA(contains("isn't one of the harnesses")));
    }
    expect(container.read(codeSessionsProvider).where((s) => s.parentId == c.sessionId), isEmpty);
  });

  test('an agent waiting on an approval shows on the lead and on the card', () async {
    final c = await open();
    await c.runWorkflow('demo', 'source');
    final reply = bridge.agent('Install', {'harness': 'fake2'});
    final info = await child();
    final s = drivers['fake2']!.latest!
      ..add(stateEvent('a-r', ExecutionStatus.running))
      ..add(actionEvent(id: 'a1', toolName: 'terminal', kind: 'TerminalAction', args: {'command': 'npm install'}))
      ..add(stateEvent('a-w', ExecutionStatus.waitingForConfirmation));
    await whenValue(container, codeSessionProvider(info.id).select((s) => s.status), (SessionStatus v) {
      return v == SessionStatus.needsInput;
    });
    await whenValue(container, codeSessionProvider(c.sessionId).select((s) => s.status), (SessionStatus v) {
      return v == SessionStatus.needsInput;
    });
    answer(s, 'Installed');
    expect(await reply, 'Installed');
    expect(container.read(codeSessionProvider(c.sessionId)).subagentNeedsInput, isFalse);
  });

  test('an agent whose session runs out of budget fails instead of hanging', () async {
    final c = await open();
    await c.runWorkflow('demo', 'source');
    final reply = bridge.agent('Review', {
      'harness': 'fake2',
      'schema': {
        'type': 'object',
        'required': ['ok'],
      },
    });
    await child();
    // The session's budget runs out during the turn.
    container.read(codeSettingsProvider.notifier).setBudget(c.sessionId, 1);
    usage[c.sessionId] = const UsageTotals(chargedMicros: 2000000);
    container.invalidate(codeUsageProvider(c.sessionId));
    await container.read(codeUsageProvider(c.sessionId).future);
    answer(drivers['fake2']!.latest!, 'Looks fine');
    await expectLater(reply, throwsA(contains('budget')));
  });
}
