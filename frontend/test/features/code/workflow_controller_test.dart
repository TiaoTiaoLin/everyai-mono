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
import 'package:every_ai/features/code/domain/permissions.dart' show Verdict;
import 'package:every_ai/features/code/domain/questions.dart';
import 'package:every_ai/features/code/domain/transcript.dart' show NoticeItem, QuestionItem;
import 'package:every_ai/features/code/drivers/acp/acp_mapping.dart' show agentMessageEvent, userMessageEvent;
import 'package:every_ai/features/code/drivers/driver_events.dart';
import 'package:every_ai/features/code/drivers/driver_registry.dart';
import 'package:every_ai/features/code/gateway_key.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/host/host.dart';
import 'package:every_ai/features/code/host/host_prompts.dart';
import 'package:every_ai/features/code/host/host_providers.dart';
import 'package:every_ai/features/code/workflows/bug_report.dart';
import 'package:every_ai/features/code/workflows/workflow_engine.dart';
import 'package:every_ai/features/code/workflows/workflow_landing.dart';
import 'package:every_ai/features/code/workflows/workflow_library.dart' show loadBundledWorkflows;
import 'package:every_ai/features/code/workflows/workflow_picker.dart' show WorkflowPick, workflowStartNote;
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

/// A keychain that keeps nothing.
final class _NoStore implements SecretStore {
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {}
  @override
  Future<void> delete(String key) async {}
}

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
  late FakeHost host;

  /// The backend: every request's path, and what it answers (no network by default).
  late List<String> api;
  late Future<http.Response> Function(http.Request req) backend;

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
      hostServerProvider.overrideWithValue(host),
      driverDataDirProvider.overrideWithValue(() async => '${tmp.path}/data'),
      apiClientProvider.overrideWithValue(
        ApiClient(
          baseUrl: Uri.parse('http://backend/'),
          client: MockClient((req) async {
            api.add(req.url.path);
            return backend(req);
          }),
        ),
      ),
      codeSideModelProvider.overrideWithValue((messages) async => ''),
      gatewayKeysProvider.overrideWith((ref) => GatewayKeys(store: _NoStore(), mint: () async => 'sk-eai-test')),
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
    host = FakeHost();
    startedArgs = null;
    api = [];
    backend = (req) async => http.Response('no network in this test', 599);
    prefs['code.projects'] = jsonEncode([CodeProject(id: 'p1', name: 'P', path: project.path).toJson()]);
    container = makeContainer();
  });

  tearDown(() async {
    container.dispose();
    await db.close();
    await tmp.delete(recursive: true);
  });

  Future<CodeSessionController> open({String harness = 'test'}) async {
    final info = await container
        .read(codeSessionsProvider.notifier)
        .start(
          project: container.read(codeProjectsProvider).single,
          prompt: 'Lead the work',
          model: '',
          mode: AgentMode.autoEdit,
          harness: harness,
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

  group('landing', () {
    const run = WorkflowRun(runId: 'abcdef123', name: 'Bug fix', status: WorkflowStatus.done);

    /// A session in a git repository with a file the workflow left uncommitted.
    Future<(CodeSessionController, String)> dirty() async {
      await git(['init', '-q']);
      await git(['config', 'user.name', 't']);
      await git(['config', 'user.email', 't@t']);
      File('${project.path}/a.txt').writeAsStringSync('one\n');
      await git(['add', '.']);
      await git(['commit', '-qm', 'init']);
      final c = await open();
      final dir = container.read(codeSessionsProvider.notifier).byId(c.sessionId)!.diffTarget!.path;
      File('$dir/b.txt').writeAsStringSync('two\n');
      return (c, dir);
    }

    Future<String> told() async {
      for (var i = 0; i < 50 && !lead.sent.any((m) => m.contains('<workflow-landing')); i++) {
        await pumpEventQueue();
      }
      return lead.sent.singleWhere((m) => m.contains('<workflow-landing'));
    }

    WorkflowLanded? landed(CodeSessionController c) => container.read(workflowLandingProvider(c.sessionId))[run.runId];

    Future<String> out(String dir, List<String> args) async =>
        '${(await Process.run('git', ['-C', dir, ...args])).stdout}'.trim();

    test('the card asks only when the folder is dirty', () async {
      final (c, dir) = await dirty();
      final key = (sessionId: c.sessionId, runId: run.runId);
      expect(await container.read(workflowDirtyProvider(key).future), isTrue);
      await c.landWorkflow(run, WorkflowLand.commit, message: 'Bug fix: two');
      container.invalidate(workflowDirtyProvider(key));
      expect(await container.read(workflowDirtyProvider(key).future), isFalse);
      expect(await out(dir, ['log', '-1', '--format=%s']), 'Bug fix: two');
    });

    test('Commit here commits the folder and tells the lead once', () async {
      final (c, dir) = await dirty();
      await c.landWorkflow(run, WorkflowLand.commit, message: 'Bug fix: two');
      expect(landed(c)!.ok, isTrue);
      expect(landed(c)!.text, startsWith('Committed '));
      final msg = await told();
      expect(msg, contains('<workflow-landing run="abcdef123" choice="commit" commit="'));
      expect(msg, isNot(contains('branch=')));
      expect(await out(dir, ['status', '--porcelain']), isEmpty);
    });

    test('New branch commits on a branch of that name; a bad name changes nothing and tells no one', () async {
      final (c, dir) = await dirty();
      final before = await out(dir, ['rev-parse', 'HEAD']);
      await c.landWorkflow(run, WorkflowLand.branch, message: 'x', branch: 'not a branch');
      expect(landed(c)!.ok, isFalse);
      expect(await out(dir, ['rev-parse', 'HEAD']), before);
      expect(await out(dir, ['status', '--porcelain']), isNotEmpty);
      expect(lead.sent.where((m) => m.contains('<workflow-landing')), isEmpty);

      await c.landWorkflow(run, WorkflowLand.branch, message: 'Bug fix: two', branch: 'everyai/bug-fix-abcdef');
      expect(landed(c)!.ok, isTrue);
      expect(landed(c)!.text, contains('on everyai/bug-fix-abcdef'));
      expect(await out(dir, ['branch', '--show-current']), 'everyai/bug-fix-abcdef');
      expect(await told(), contains('choice="branch" branch="everyai/bug-fix-abcdef"'));
    });

    test('Leave uncommitted touches nothing and still tells the lead', () async {
      final (c, dir) = await dirty();
      await c.landWorkflow(run, WorkflowLand.leave);
      expect(landed(c)!.text, 'Left uncommitted.');
      expect(await out(dir, ['status', '--porcelain']), isNotEmpty);
      expect(await told(), contains('choice="leave"'));
    });
  });

  test('a finished run tells the lead its changes are not committed yet', () async {
    final c = await open();
    await c.runWorkflow('demo', 'source');
    bridge.finish({'fixed': true});
    for (var i = 0; i < 50 && !lead.sent.any((m) => m.contains('<workflow-result')); i++) {
      await pumpEventQueue();
    }
    final msg = lead.sent.singleWhere((m) => m.contains('<workflow-result'));
    expect(msg, contains('not committed'));
    expect(msg, contains('you will be told'));
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
    // Reopening briefs it again (files on disk) before it is told to carry on.
    await whenValue(container, codeSessionProvider(first.id).select((s) => s.connected), (bool c) => c);
    bool carriedOn(FakeLeadSession? s) => [...?s?.sent, ...?s?.steered].any((m) => m.contains(workflowCarryOn));
    for (var i = 0; i < 50 && !carriedOn(drivers['fake2']!.latest); i++) {
      await pumpEventQueue();
    }
    final s = drivers['fake2']!.latest;
    expect([...s!.sent, ...s.steered].where((m) => m.contains(workflowCarryOn)), hasLength(1));
    // Its old token died with the app: it reopens with a fresh one, for the proof tools only.
    final reopened = drivers['fake2']!.reopened.single;
    expect(host.live[first.id], contains(reopened.mcpToken));
    expect(host.only[first.id], workflowHostTools);
    expect(reopened.sessionSkill, isNot(contains('## Workflows')));
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

  group('proof tools', () {
    const fixSchema = {
      'type': 'object',
      'properties': {
        'cause': {'type': 'string'},
      },
      'required': ['cause'],
    };

    test("a workflow agent's host has only the proof tools, and its briefing no workflows", () async {
      final c = await open();
      await c.runWorkflow('demo', 'source');
      unawaited(bridge.agent('Fix', {'harness': 'fake2'}).catchError((Object _) => null));
      final info = await child();
      expect(info.isWorkflowAgent, isTrue);
      expect(host.only[info.id], workflowHostTools);
      // The memory is in its instructions; the lead decides what is kept.
      expect(workflowHostTools, isNot(contains('memory')));
      expect(host.only[c.sessionId], isNull);
      final text = drivers['fake2']!.specs.single.briefing!.sessionSkill!;
      final tools = text.substring(text.indexOf('## everyai tools'), text.indexOf('## Rules'));
      expect(
        RegExp(r'^- `(\w+)`', multiLine: true).allMatches(tools).map((m) => m[1]),
        unorderedEquals(workflowHostTools),
      );
      expect(text, isNot(contains('## Workflows')));
      expect(text, isNot(contains('run_workflow')));
      expect(await (host.tools[info.id]! as HostPrompts).workflowPrompts(), isEmpty);
    });

    test("a workflow agent's read-only proof tools run, its commands ask", () async {
      final c = await open();
      await c.runWorkflow('demo', 'source');
      unawaited(bridge.agent('Fix', {'harness': 'fake2'}).catchError((Object _) => null));
      final info = await child();
      final policy = container.read(codeSessionProvider(info.id).notifier).policy;
      ActionCall mcp(String name) => ActionCall(
        id: name,
        raw: const {},
        toolName: 'mcp__everyai__$name',
        toolCallId: name,
        action: const {'kind': 'MCPToolAction'},
      );
      expect(policy.decide(mcp('diff_stats'), AgentMode.autoEdit).verdict, Verdict.allow);
      expect(policy.decide(mcp('bug_check'), AgentMode.autoEdit).verdict, Verdict.ask);
    });

    test("bug_check's record comes from the child's state file, seeded before its first turn", () async {
      final c = await open();
      await c.runWorkflow('demo', 'source');
      File('${project.path}/test/repro_test.dart')
        ..createSync(recursive: true)
        ..writeAsStringSync('// repro');
      final seed = {
        'available': true,
        'state': 'verified',
        'command': 'dart test test/repro_test.dart',
        'expect': 'Expected: 3',
        // A git-excluded script stayed in the fixer's checkout: its absence here isn't a change to the repro.
        'files': {'test/repro_test.dart': 'abc', '.everyai/scratch/repro.sh': 'def'},
      };
      final reply = bridge.agent('Refix', {'harness': 'fake2', 'schema': fixSchema, 'bugCheck': seed});
      final info = await child();
      final state = File('${tmp.path}/data/driver-sessions/${info.id}/bug_check.json');
      expect(jsonDecode(state.readAsStringSync()), {
        'command': 'dart test test/repro_test.dart',
        'expect': 'Expected: 3',
        'files': {'test/repro_test.dart': 'abc'},
        'verified': false,
      });
      // The child verifies (the host writes the state), and says something else itself.
      state.writeAsStringSync(
        jsonEncode({
          'command': 'dart test test/repro_test.dart',
          'expect': '',
          'files': <String, Object?>{},
          'verified': true,
        }),
      );
      answer(drivers['fake2']!.latest!, '```json\n{"cause": "off by one", "bug_check": {"state": "made up"}}\n```');
      final value = await reply as Map;
      expect(value['bug_check'], {
        'available': true,
        'state': 'verified',
        'command': 'dart test test/repro_test.dart',
        'expect': '',
        'files': <String, Object?>{},
      });
    });

    test('a fresh bug_check is not_reproduced; an agent with no host says why', () async {
      final c = await open();
      await c.runWorkflow('demo', 'source');
      var reply = bridge.agent('Fix', {'harness': 'fake2', 'schema': fixSchema, 'bugCheck': true});
      final first = await child();
      answer(drivers['fake2']!.latest!, '```json\n{"cause": "x"}\n```');
      expect(((await reply as Map)['bug_check'] as Map)['state'], 'not_reproduced');
      host.mintFails = StateError('no port');
      reply = bridge.agent('Fix again', {'harness': 'fake2', 'schema': fixSchema, 'bugCheck': true});
      final second = await whenValue(
        container,
        codeSessionsProvider,
        (List<CodeSessionInfo> all) => all.any((s) => s.isWorkflowAgent && s.id != first.id),
      ).then((all) => all.firstWhere((s) => s.isWorkflowAgent && s.id != first.id));
      expect(drivers['fake2']!.specs.last.briefing, isNull);
      expect(second.title, isNotEmpty);
      answer(drivers['fake2']!.latest!, '```json\n{"cause": "x"}\n```');
      final record = (await reply as Map)['bug_check'] as Map;
      expect(record['available'], isFalse);
      expect(record['why'], contains('no port'));
    });

    test('an agent reopened after a restart without a host says so in its record', () async {
      CodeSessionController.liveAfter = Duration.zero;
      addTearDown(() => CodeSessionController.liveAfter = const Duration(milliseconds: 1500));
      final c = await open();
      final id = c.sessionId;
      await c.runWorkflow('demo', 'source');
      final call = {'harness': 'fake2', 'schema': fixSchema, 'bugCheck': true};
      unawaited(bridge.agent('Fix', call).catchError((Object _) => null));
      final first = await child();
      // It reproduced the bug, then the app quit mid-turn.
      File('${tmp.path}/data/driver-sessions/${first.id}/bug_check.json')
        ..createSync(recursive: true)
        ..writeAsStringSync(jsonEncode({'command': 'make repro', 'expect': '', 'files': <String, Object?>{}}));
      drivers['fake2']!.latest!.add(stateEvent('w-r', ExecutionStatus.running));
      await pumpEventQueue();
      container.dispose();
      bridge = FakeBridge();
      host.mintFails = StateError('no port');
      container = makeContainer();
      container.listen(codeSessionProvider(id), (_, _) {});
      await whenValue(
        container,
        workflowRunsProvider(id),
        (List<WorkflowRun> r) => r.isNotEmpty && r.last.status == WorkflowStatus.running && r.last.agents.isEmpty,
      );
      final again = bridge.agent('Fix', call);
      await whenValue(container, codeSessionProvider(first.id).select((s) => s.connected), (bool c) => c);
      expect(drivers['fake2']!.reopened, isEmpty);
      answer(drivers['fake2']!.latest!, '```json\n{"cause": "x"}\n```');
      final record = (await again as Map)['bug_check'] as Map;
      expect(record['available'], isFalse);
      expect(record['why'], allOf(contains('restarted'), contains('no port')));
    });
  });

  group('a thin bug report', () {
    QuestionItem card(CodeSessionController c) => container
        .read(codeSessionProvider(c.sessionId))
        .transcript
        .items
        .whereType<QuestionItem>()
        .lastWhere((q) => q.call.id.startsWith('bugask-'));

    HostCall bugfix(String bug) => HostCall(
      id: 'h-$bug',
      sessionId: '',
      name: runWorkflowTool,
      args: {
        'id': 'bugfix',
        'args': {'bug': bug},
      },
      ended: Completer<HostEnd>().future,
    );

    const answers = [
      QuestionAnswer(other: 'Saving a note crashes with a TypeError'),
      QuestionAnswer(selected: {0}),
      QuestionAnswer(other: 'It saves'),
    ];

    test('on an outside lead: asked with no model call, then started with the answers', () async {
      final c = await open();
      final r = await c.call(bugfix('fix it'));
      expect(r, (text: bugAskedResult, isError: false));
      expect(startedArgs, isNull);
      final q = card(c);
      expect(q.questions, hasLength(3));
      expect(q.answers, isNull);
      // One at a time: a run waits for the card.
      final again = await c.call(bugfix('Saving crashes'));
      expect(again.isError, isTrue);
      expect(again.text, contains('waiting for the user'));
      await c.answer(q, answers);
      await pumpEventQueue();
      expect(startedArgs!['bug'], startsWith('fix it\nWhat goes wrong: Saving a note crashes with a TypeError'));
      expect(startedArgs!['bug'], contains('Expected: It saves'));
      expect(card(c).answers, answers);
      expect(api.where((p) => p.endsWith('/aux/decide')), isEmpty);
    });

    test('a reply in chat instead of the card is the report, and the card no longer holds runs back', () async {
      final c = await open();
      await c.call(bugfix('fix it'));
      lead.add(userMessageEvent('u-chat', 'Saving a note crashes with a TypeError'));
      for (var i = 0; i < 50 && startedArgs == null; i++) {
        await pumpEventQueue();
      }
      expect(card(c).answers, isEmpty);
      expect(startedArgs!['bug'], 'fix it\nWhat goes wrong: Saving a note crashes with a TypeError');
      final next = await c.call(bugfix('Saving crashes'));
      expect(next.text, isNot(contains('waiting for the user')));
      expect(next.text, contains('already running'));
    });

    test('a card open when the app quits: after the restart the lead hears Bug fix never started', () async {
      CodeSessionController.liveAfter = Duration.zero;
      addTearDown(() => CodeSessionController.liveAfter = const Duration(milliseconds: 1500));
      final c = await open();
      final id = c.sessionId;
      await c.call(bugfix('fix it'));
      final saved = File('${tmp.path}/data/workflows/$id/bugask.jsonl');
      expect(saved.existsSync(), isTrue);
      container.dispose();
      container = makeContainer();
      container.listen(codeSessionProvider(id), (_, _) {});
      bool told() => lead.sent.any((m) => m.contains('state="failed"'));
      for (var i = 0; i < 100 && !told(); i++) {
        await pumpEventQueue();
      }
      expect(lead.sent.lastWhere((m) => m.contains('state="failed"')), contains('closed before the user answered'));
      expect(saved.existsSync(), isFalse);
    });

    test('an answered card leaves nothing for a restart to report', () async {
      final c = await open();
      await c.call(bugfix('fix it'));
      await c.answer(card(c), answers);
      await pumpEventQueue();
      expect(File('${tmp.path}/data/workflows/${c.sessionId}/bugask.jsonl').existsSync(), isFalse);
    });

    test('a start note taken out of the queue takes its waiting card with it', () async {
      final entry = (await loadBundledWorkflows()).firstWhere((w) => w.id == 'bugfix');
      final c = await open();
      lead.add(stateEvent('busy', ExecutionStatus.running));
      await whenValue(container, codeSessionProvider(c.sessionId).select((s) => s.transcript.running), (bool b) => b);
      c.pickWorkflow(WorkflowPick.script(entry));
      await c.sendTyped('fix it');
      expect(container.read(codeSessionProvider(c.sessionId)).queued, hasLength(1));
      expect((await c.call(bugfix('Saving crashes'))).text, contains('waiting for the user'));
      c.unqueue(0);
      expect((await c.call(bugfix('Saving a note crashes'))).text, startsWith('Started Bug fix'));
    });

    test('a concrete report on an outside lead starts at once', () async {
      final c = await open();
      final r = await c.call(bugfix('Saving a note crashes'));
      expect(r.text, startsWith('Started Bug fix'));
      await pumpEventQueue();
      expect(startedArgs!['bug'], 'Saving a note crashes');
    });

    test('empty answers start nothing, and the lead is told', () async {
      final c = await open();
      await c.call(bugfix(''));
      await c.answer(card(c), const [QuestionAnswer(), QuestionAnswer(), QuestionAnswer()]);
      await pumpEventQueue();
      expect(startedArgs, isNull);
      final notices = container.read(codeSessionProvider(c.sessionId)).transcript.items.whereType<NoticeItem>();
      expect(notices.last.message, "Bug fix didn't start: no bug was given.");
      lead.add(stateEvent('idle', ExecutionStatus.finished));
      for (var i = 0; i < 50 && !lead.sent.any((m) => m.contains('state="failed"')); i++) {
        await pumpEventQueue();
      }
      expect(lead.sent.last, contains('state="failed"'));
      // The card is closed, so another run may start.
      expect((await c.call(bugfix('Saving a note crashes'))).isError, isFalse);
    });

    group('on the EveryAI harness', () {
      setUp(() {
        drivers['everyai'] = FakeLeadDriver('everyai', session: lead);
        container.dispose();
        container = makeContainer();
      });

      void decides(Object? concrete) => backend = (req) async => req.url.path.endsWith('/aux/decide')
          ? http.Response(
              jsonEncode({
                'answers': [
                  {'id': 'concrete', 'value': concrete},
                ],
              }),
              200,
              headers: {'content-type': 'application/json'},
            )
          : http.Response('no network in this test', 599);

      test('decide says no symptom: the user is asked', () async {
        decides(false);
        final c = await open(harness: 'everyai');
        expect((await c.call(bugfix('The save flow in notes needs a look please'))).text, bugAskedResult);
        expect(api.where((p) => p.endsWith('/aux/decide')), hasLength(1));
        expect(card(c).questions, bugQuestions);
      });

      test('decide says concrete: it starts at once', () async {
        decides(true);
        final c = await open(harness: 'everyai');
        expect((await c.call(bugfix('the button'))).text, startsWith('Started Bug fix'));
      });

      test('a workflow agent on it reaches the restricted host, unsaved, and its proof tools are host tools', () async {
        final c = await open(harness: 'everyai');
        await c.runWorkflow('demo', 'source');
        unawaited(bridge.agent('Fix', <String, Object?>{}).catchError((Object _) => null));
        final info = await child();
        expect(info.harness, 'everyai');
        expect(host.only[info.id], workflowHostTools);
        final briefing = drivers['everyai']!.specs.last.briefing!;
        expect(briefing.mcpToken, host.live[info.id]!.single);
        expect(briefing.sessionSkill, isNull);
        expect(prefs['code.sessions'], isNot(contains(briefing.mcpToken)));
        final policy = container.read(codeSessionProvider(info.id).notifier).policy;
        ActionCall mcp(String name) => ActionCall(
          id: name,
          raw: const {},
          toolName: 'everyai__$name',
          toolCallId: name,
          action: const {'kind': 'MCPToolAction'},
        );
        expect(policy.decide(mcp('diff_stats'), AgentMode.autoEdit).verdict, Verdict.allow);
        expect(policy.decide(mcp('bug_check'), AgentMode.autoEdit).verdict, Verdict.ask);
        // The lead on the EveryAI harness has no host tools.
        expect(c.policy.decide(mcp('diff_stats'), AgentMode.autoEdit).verdict, Verdict.ask);
      });

      test('a failed decide falls back to the heuristic', () async {
        final c = await open(harness: 'everyai');
        expect((await c.call(bugfix('the button'))).text, bugAskedResult);
        expect((await c.call(bugfix('x'))).isError, isTrue);
        await c.answer(card(c), answers);
        await pumpEventQueue();
        expect(startedArgs!['bug'], contains('What goes wrong'));
        expect(api.where((p) => p.endsWith('/aux/decide')), hasLength(1));
      });
    });

    test('a picked Bug fix asks once its start note is in, then starts', () async {
      final entry = (await loadBundledWorkflows()).firstWhere((w) => w.id == 'bugfix');
      final info = await container
          .read(codeSessionsProvider.notifier)
          .start(
            project: container.read(codeProjectsProvider).single,
            prompt: 'fix it',
            model: '',
            mode: AgentMode.autoEdit,
            harness: 'test',
            workflow: WorkflowPick.script(entry),
          );
      container.listen(codeSessionProvider(info.id), (_, _) {});
      await whenValue(container, codeSessionProvider(info.id).select((s) => s.connected), (bool c) => c);
      final c = container.read(codeSessionProvider(info.id).notifier);
      // Not before the start note: that turn would close the card as answered in chat.
      expect(container.read(codeSessionProvider(info.id)).transcript.items.whereType<QuestionItem>(), isEmpty);
      lead.add(userMessageEvent('u1', workflowStartNote(entry, 'fix it')));
      await whenValue(
        container,
        codeSessionProvider(info.id).select((s) => s.transcript.openQuestion?.call.id ?? ''),
        (String id) => id.startsWith('bugask-'),
      );
      expect(startedArgs, isNull);
      await c.answer(card(c), answers);
      await pumpEventQueue();
      expect(startedArgs!['bug'], startsWith('fix it\n'));
    });
  });
}
