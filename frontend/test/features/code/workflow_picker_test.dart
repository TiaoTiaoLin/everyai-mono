import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/net/api_client.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/ui/anchored_popover.dart';
import 'package:every_ai/features/code/agent_models.dart';
import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/domain/agent_menu.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/drivers/driver.dart';
import 'package:every_ai/features/code/drivers/driver_registry.dart';
import 'package:every_ai/features/code/host/host_providers.dart';
import 'package:every_ai/features/code/ui/agent_menu.dart';
import 'package:every_ai/features/code/workflows/workflow_library.dart';
import 'package:every_ai/features/code/workflows/workflow_picker.dart';
import 'package:every_ai/features/code/workflows/workflow_runs.dart';
import 'package:every_ai/features/models/models_providers.dart';
import 'package:every_ai/features/usage/usage_totals.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart' as m;

import '../../support/fake_leads.dart';
import 'workflow_fakes.dart';

// The agent menu's Workflow page, and what a pick does: a script workflow
// takes the next message as its task, Max turns the approach skill on.

const _catalog = AgentCatalog(
  tiers: [AgentTier('everyday', 'Everyday', '')],
  models: [AgentChoice(model: 'a/m', effort: '', tier: 'everyday', label: 'M')],
  fallback: AgentChoice(model: 'a/m', effort: '', tier: 'everyday', label: 'M'),
);

WorkflowEntry _entry(String id, String title, {WorkflowOrigin origin = WorkflowOrigin.bundled}) =>
    WorkflowEntry(id: id, title: title, source: 'return 1', digest: id, origin: origin, description: '$title does it');

Widget _host(Widget child) => m.MaterialApp(
  home: EveryThemeScope(
    theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light),
    child: m.Scaffold(
      body: Center(child: SizedBox(width: 320, height: 700, child: child)),
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the Workflow page', () {
    final library = (
      active: [
        _entry('ultra', 'Ultra'),
        _entry('bugfix', 'Bug fix'),
        _entry('security_review', 'Security review'),
        _entry('release', 'Release notes', origin: WorkflowOrigin.project),
      ],
      locked: [(entry: _entry('deploy', 'Deploy', origin: WorkflowOrigin.project), note: 'Came with the project.')],
    );

    Future<List<WorkflowPick?>> show(WidgetTester tester, {bool outside = false, bool demo = false}) async {
      final picks = <WorkflowPick?>[];
      await tester.pumpWidget(
        _host(
          AgentMenuPanel(
            key: ValueKey('$outside$demo'),
            groups: agentMenuGroups(_catalog),
            model: 'a/m',
            effort: '',
            demo: demo,
            onChanged: (_, _) {},
            close: () {},
            onLevel: (_) {},
            onWorkflow: picks.add,
            workflows: demo ? null : library,
            driverModels: outside ? const [DriverModel(id: 'x', label: 'X')] : null,
          ),
        ),
      );
      return picks;
    }

    testWidgets('lists None, Max, the bundled ones, then the project\'s own; a pick is reported', (tester) async {
      final picks = await show(tester);
      expect(find.text('Effort level'), findsOneWidget);
      expect(find.text('None'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('agent-menu.workflow')));
      await tester.pump();
      final titles = [
        for (final key in ['none', 'max', 'ultra', 'bugfix', 'security_review', 'release', 'locked.deploy'])
          tester.widget<PopoverRow>(find.byKey(ValueKey('agent-menu.workflow.$key'))).title,
      ];
      expect(titles, ['None', 'Max', 'Ultra', 'Bug fix', 'Security review', 'Release notes', 'Deploy']);
      // In that order down the page, with the project's under their own header.
      final ys = [for (final t in titles) tester.getTopLeft(find.widgetWithText(PopoverRow, t)).dy];
      expect([...ys]..sort(), ys);
      expect(find.text('This project'), findsOneWidget);
      expect(find.text('Came with the project.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('agent-menu.workflow.ultra')));
      await tester.pump();
      expect(picks.single!.id, 'ultra');
      // Back on the root, showing the pick.
      expect(find.text('Ultra'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('agent-menu.workflow')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('agent-menu.workflow.max')));
      await tester.pump();
      expect(picks.last!.isMax, isTrue);
    });

    testWidgets('an outside lead has the Workflow row but no effort level', (tester) async {
      await show(tester, outside: true);
      expect(find.byKey(const ValueKey('agent-menu.workflow')), findsOneWidget);
      expect(find.text('Effort level'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('agent-menu.workflow')));
      await tester.pump();
      expect(find.byKey(const ValueKey('agent-menu.workflow.max')), findsOneWidget);
      expect(find.byKey(const ValueKey('agent-menu.workflow.ultra')), findsOneWidget);
    });

    testWidgets('the demo offers only None', (tester) async {
      await show(tester, demo: true);
      expect(find.text('Not in the demo'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('agent-menu.workflow')));
      await tester.pump();
      expect(find.byKey(const ValueKey('agent-menu.workflow.none')), findsOneWidget);
      expect(find.byKey(const ValueKey('agent-menu.workflow.max')), findsNothing);
      expect(find.byKey(const ValueKey('agent-menu.workflow.ultra')), findsNothing);
    });
  });

  test('each bundled workflow gets its own args from the task; a project one gets {task}', () {
    expect(workflowArgsFor(_entry('bugfix', 'Bug fix'), 'It crashes'), {'bug': 'It crashes'});
    expect(workflowArgsFor(_entry('security_review', 'Security review'), 'main'), {'base': 'main'});
    expect(workflowArgsFor(_entry('security_review', 'Security review'), 'check the auth change'), isEmpty);
    expect(workflowArgsFor(_entry('ultra', 'Ultra'), 'Dark mode\nwith a toggle'), {
      'items': [
        {'id': 'task', 'title': 'Dark mode', 'spec': 'Dark mode\nwith a toggle'},
      ],
    });
    expect(workflowArgsFor(_entry('bugfix', 'Mine', origin: WorkflowOrigin.project), 'x'), {'task': 'x'});
  });

  group('a pick in a session', () {
    late AppDatabase db;
    late Directory tmp;
    late Directory project;
    late FakeLeadSession lead;
    late FakeLeadDriver driver;
    late ProviderContainer container;
    late Preferences prefs;
    late FakeBridge bridge;
    final started = <({String source, Map<String, Object?> args})>[];

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      tmp = await Directory.systemTemp.createTemp('workflow-picker');
      project = await Directory('${tmp.path}/project').create();
      lead = FakeLeadSession();
      driver = FakeLeadDriver('test', session: lead);
      bridge = FakeBridge();
      started.clear();
      prefs = await Preferences.load(db);
      prefs['code.projects'] = jsonEncode([CodeProject(id: 'p1', name: 'P', path: project.path).toJson()]);
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(prefs),
          modelCatalogProvider.overrideWith(FixedCatalog.new),
          codeUsageProvider.overrideWithBuild((ref, n) async => UsageTotals.zero),
          driverRegistryProvider.overrideWithValue(DriverRegistry({'test': driver})),
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
            started.add((source: source, args: args));
            return bridge;
          }),
        ],
      );
    });

    tearDown(() async {
      container.dispose();
      await db.close();
      await tmp.delete(recursive: true);
    });

    Future<(CodeSessionController, CodeSessionInfo)> open({WorkflowPick? workflow, String prompt = 'Lead'}) async {
      final info = await container
          .read(codeSessionsProvider.notifier)
          .start(
            project: container.read(codeProjectsProvider).single,
            prompt: prompt,
            model: '',
            mode: AgentMode.autoEdit,
            harness: 'test',
            workflow: workflow,
          );
      container.listen(codeSessionProvider(info.id), (_, _) {});
      await whenValue(container, codeSessionProvider(info.id).select((s) => s.connected), (bool c) => c);
      return (container.read(codeSessionProvider(info.id).notifier), info);
    }

    Future<WorkflowEntry> bundled(String id) async => (await loadBundledWorkflows()).firstWhere((w) => w.id == id);

    test('from the home page, Ultra takes the prompt as its task after the lead is told', () async {
      final ultra = await bundled('ultra');
      final (c, _) = await open(workflow: WorkflowPick.script(ultra), prompt: 'Add dark mode');
      expect(driver.specs.single.initialMessage, contains('<everyai-workflow name="ultra">'));
      expect(driver.specs.single.initialMessage, contains('Add dark mode'));
      expect(await c.launchWorkflow(ultra, 'Add dark mode'), isNull);
      await pumpEventQueue();
      expect(started.single.source, ultra.source);
      expect(((started.single.args['items']! as List).single as Map)['spec'], 'Add dark mode');
    });

    test('an armed Bug fix takes the next message as its task; the one after is a plain turn', () async {
      final (c, _) = await open();
      c.pickWorkflow(WorkflowPick.script(await bundled('bugfix')));
      expect(container.read(codeSessionProvider(c.sessionId)).armed?.id, 'bugfix');
      expect(c.workflowPick?.id, 'bugfix');
      expect(await c.send('Saving crashes'), isTrue);
      await pumpEventQueue();
      expect(lead.sent.last, contains('<everyai-workflow name="bugfix">'));
      expect(lead.sent.last, contains('Saving crashes'));
      expect(started.single.args['bug'], 'Saving crashes');
      expect(c.workflowPick, isNull);

      expect(await c.send('And the title too'), isTrue);
      await pumpEventQueue();
      expect(lead.sent.last, isNot(contains('<everyai-workflow')));
      expect(started, hasLength(1));
    });

    test('Max is kept on the session and its note goes with the next message once', () async {
      final (c, info) = await open();
      c.pickWorkflow(const WorkflowPick.max());
      final saved = container.read(codeSessionsProvider.notifier).byId(info.id)!;
      expect(saved.workflow, maxWorkflowId);
      expect(CodeSessionInfo.fromJson(saved.toJson()).workflow, maxWorkflowId);
      expect(c.workflowPick!.isMax, isTrue);
      await c.send('Build a game');
      await c.send('Make it blue');
      final noted = lead.sent.where((m) => m.contains(maxWorkflowNote(on: true))).toList();
      expect(noted, hasLength(1));
      expect(noted.single, contains('Build a game'));
      expect(noted.single, contains(maxSkillId));
      // Off again: the opposite note, once.
      c.pickWorkflow(null);
      expect(container.read(codeSessionsProvider.notifier).byId(info.id)!.workflow, isNull);
      await c.send('Now plain');
      expect(lead.sent.last, contains(maxWorkflowNote(on: false)));
      expect(started, isEmpty);
    });

    test('Max picked on the home page is on from the first message', () async {
      final (_, info) = await open(workflow: const WorkflowPick.max(), prompt: 'Build a game');
      expect(info.workflow, maxWorkflowId);
      expect(driver.specs.single.initialMessage, contains(maxWorkflowNote(on: true)));
    });

    test('a project workflow edited after it was picked does not run', () async {
      final file = File('${project.path}/.everyai/workflows/notes.js')
        ..createSync(recursive: true)
        ..writeAsStringSync("export const meta = { name: 'Notes' }\nreturn 1\n");
      final entry = (await loadProjectWorkflows(project.path)).single;
      container.read(workflowTrustProvider.notifier).set(entry, true);
      final (c, _) = await open();
      c.pickWorkflow(WorkflowPick.script(entry));
      file.writeAsStringSync("export const meta = { name: 'Notes' }\nreturn 2\n");
      final before = lead.sent.length;
      expect(await c.send('Write them'), isFalse);
      expect(started, isEmpty);
      expect(lead.sent.length, before);
      final t = container.read(codeSessionProvider(c.sessionId)).transcript;
      expect(t.items.whereType<NoticeItem>().last.message, contains('changed since you picked it'));
    });
  });
}
