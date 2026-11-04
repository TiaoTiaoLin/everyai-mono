import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/net/api_client.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/drivers/acp/acp_mapping.dart' show agentMessageEvent;
import 'package:every_ai/features/code/drivers/driver_events.dart';
import 'package:every_ai/features/code/drivers/driver_registry.dart';
import 'package:every_ai/features/code/harness/events.dart';
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

  Future<void> git(List<String> args) async {
    final r = await Process.run('git', args, workingDirectory: project.path);
    if (r.exitCode != 0) throw StateError('git ${args.join(' ')}: ${r.stderr}');
  }

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    tmp = await Directory.systemTemp.createTemp('workflow-controller');
    project = await Directory('${tmp.path}/project').create();
    lead = FakeLeadSession();
    bridge = FakeBridge();
    drivers = {
      'test': FakeLeadDriver('test', session: lead),
      'fake2': FakeLeadDriver('fake2', label: 'Second CLI'),
      'cli': FakeLeadDriver('cli', needsConsent: true, label: 'Gated CLI'),
    };
    final prefs = await Preferences.load(db);
    prefs['code.projects'] = jsonEncode([CodeProject(id: 'p1', name: 'P', path: project.path).toJson()]);
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        preferencesProvider.overrideWithValue(prefs),
        modelCatalogProvider.overrideWith(FixedCatalog.new),
        codeUsageProvider.overrideWithBuild((ref, n) async => UsageTotals.zero),
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
        workflowBridgeProvider.overrideWithValue(({required dir, required source, required args}) async => bridge),
      ],
    );
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
    expect(lead.sent.last, contains('"fixed": true'));
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

  test('a run the app quit in the middle of carries on when the session opens again', () async {
    final c = await open();
    final id = c.sessionId;
    final runId = await c.runWorkflow('demo', 'the source', args: {'n': 2});
    // Killed with the script: nobody hears this one.
    unawaited(bridge.agent('Fix', {'harness': 'fake2'}).catchError((Object _) => null));
    final first = await child();
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
  });
}
