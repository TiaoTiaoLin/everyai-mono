import 'dart:convert';

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/code/agent_models.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/drivers/claude/claude_wire.dart' show claudeModes;
import 'package:every_ai/features/code/drivers/driver_registry.dart';
import 'package:every_ai/features/code/mcp_providers.dart';
import 'package:every_ai/features/code/settings/agent_prompt.dart' show HarnessTier;
import 'package:every_ai/features/code/ui/agent_menu.dart';
import 'package:every_ai/features/code/ui/code_composer.dart';
import 'package:every_ai/features/code/workflows/workflow_picker.dart' show WorkflowPick;
import 'package:every_ai/features/models/models_providers.dart';
import 'package:every_ai/features/settings/settings_registry.dart';
import 'package:every_ai/features/skills/domain/skill_format.dart';
import 'package:every_ai/features/skills/skills_providers.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

import '../support/fake_leads.dart';

const _project = '/work/app';

InstalledSkill _skill(String name, {SkillSource source = SkillSource.library, String? projectId}) {
  final md = '---\nname: $name\ndescription: Does a thing. Use it when asked.\n---\nBody of $name.\n';
  final c = checkSkill(dirName: name, skillMd: md, entries: const [SkillEntry('SKILL.md', size: 10)]);
  return InstalledSkill(
    dirName: name,
    dir: '/skills/${source.name}/$name',
    source: source,
    projectId: projectId,
    manifest: c.manifest,
    report: c.report,
    digest: 'd1',
  );
}

final class _Skills extends NoInstalledSkills {
  _Skills(this.skills);
  final List<InstalledSkill> skills;

  @override
  Future<List<InstalledSkill>> build() async => skills;
}

void main() {
  late AppDatabase db;
  late Preferences prefs;
  final harnesses = <String>[];
  final modes = <AgentMode>[];

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    prefs = Preferences.inMemory({
      'code.projects': jsonEncode([
        {'id': 'p1', 'name': 'app', 'path': _project},
      ]),
    });
    harnesses.clear();
    modes.clear();
  });
  tearDown(() => db.close());

  AgentMenu menu({String harness = 'everyai', bool switchable = true, WorkflowPick? workflow}) => AgentMenu(
    harness: harness,
    onHarness: switchable ? harnesses.add : null,
    model: harness == 'everyai' ? 'anthropic/claude-opus-5.5' : '',
    effort: harness == 'everyai' ? 'medium' : '',
    onChanged: (_, _) {},
    level: HarnessTier.efficient,
    onLevel: (_) {},
    workflow: workflow,
    onWorkflow: (_) {},
  );

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    AgentMenu? agent,
    List<InstalledSkill> skills = const [],
    bool native = false,
  }) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(prefs),
          modelCatalogProvider.overrideWith(FixedCatalog.new),
          agentCatalogProvider.overrideWithBuild((ref, _) => AgentCatalog.builtIn),
          installedSkillsProvider.overrideWith(() => _Skills(skills)),
          driverRegistryProvider.overrideWithValue(
            DriverRegistry({
              'everyai': FakeLeadDriver('everyai', label: 'EveryAI'),
              'alpha': FakeLeadDriver('alpha', label: 'Alpha CLI'),
            }),
          ),
          driverStatusesProvider.overrideWith(() => DriverStatuses(loadShell: () async {}, reloadShell: () async {})),
        ],
        child: m.MaterialApp(
          builder: (context, child) =>
              EveryThemeScope(theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light), child: child!),
          home: m.Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(
                width: 900,
                child: CodeComposer(
                  busy: false,
                  mode: AgentMode.ask,
                  onModeChanged: modes.add,
                  onSend: (_, _) {},
                  project: _project,
                  agent: agent,
                  nativeModes: native ? claudeModes(autoMode: false) : null,
                  nativeMode: native ? 'default' : null,
                  harnessLabel: native ? 'Claude Code' : '',
                  onNativeModeChanged: native ? (_) {} : null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(tester.element(find.byType(CodeComposer)));
  }

  Finder strip(String part) => find.byKey(ValueKey('composer.strip.$part'));
  Finder line(String part) => find.byKey(ValueKey('composer.line.$part'));
  Finder rowsStarting(String prefix) =>
      find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith(prefix));

  group('the strip', () {
    testWidgets("harness, Workflows, and this session's skills and MCP servers", (tester) async {
      final c = await pump(
        tester,
        agent: menu(),
        skills: [
          _skill('alpha'),
          _skill('beta'),
          // Another project's, and this project's before the user trusts it: not counted.
          _skill('gamma', source: SkillSource.project, projectId: 'other'),
          _skill('delta', source: SkillSource.project, projectId: 'p1'),
        ],
      );
      final mcp = c.read(codeMcpServersProvider.notifier);
      mcp.put(const McpServer(name: 'docs', transport: McpTransport.http, url: 'https://docs.example/mcp'));
      mcp.put(const McpServer(name: 'off', transport: McpTransport.http, url: 'https://x.example', enabled: false));
      // A local command not approved yet doesn't run either.
      mcp.put(
        const McpServer(name: 'local', command: 'npx', args: ['thing']),
        projectId: 'p1',
      );
      mcp.put(
        const McpServer(name: 'theirs', transport: McpTransport.http, url: 'https://y.example'),
        projectId: 'p2',
      );
      await tester.pumpAndSettle();

      expect(find.descendant(of: strip('harness'), matching: find.text('EveryAI')), findsOneWidget);
      expect(find.descendant(of: strip('workflow'), matching: find.text('Workflows')), findsOneWidget);
      expect(find.descendant(of: strip('skills'), matching: find.text('Skills 2')), findsOneWidget);
      expect(find.descendant(of: strip('mcp'), matching: find.text('MCP 1')), findsOneWidget);
    });

    for (final section in [SettingsSection.skills, SettingsSection.mcp]) {
      testWidgets('${section.name} opens Settings there, for this project', (tester) async {
        final c = await pump(tester, agent: menu());
        final targets = <SettingsTarget?>[];
        c.listen(settingsTargetProvider, (_, t) => targets.add(t));
        await tester.tap(strip(section.name));
        await tester.pumpAndSettle();
        final t = targets.nonNulls.single;
        expect(t.section, section);
        expect(t.args, {'project': 'p1'});
        expect(find.byKey(const ValueKey('settings.close')), findsOneWidget);
      });
    }

    testWidgets('the harness chip opens the Harness page at once; a pick hands the session over', (tester) async {
      await pump(tester, agent: menu());
      await tester.tap(strip('harness'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('agent-menu.back')), findsNothing);
      expect(find.byKey(const ValueKey('agent-menu.harness.everyai')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('agent-menu.harness.alpha')));
      await tester.pumpAndSettle();
      expect(harnesses, ['alpha']);
      expect(find.byKey(const ValueKey('agent-menu.harness.alpha')), findsNothing);
    });

    testWidgets("a subagent's harness can't be switched", (tester) async {
      await pump(tester, agent: menu(switchable: false));
      await tester.tap(strip('harness'));
      await tester.pumpAndSettle();
      expect(rowsStarting('agent-menu.harness'), findsNothing);
    });

    testWidgets('without an agent: no strip, the mode still under the box', (tester) async {
      await pump(tester);
      expect(strip('harness'), findsNothing);
      expect(strip('skills'), findsNothing);
      await tester.tap(find.text('Ask'));
      await tester.pumpAndSettle();
      expect(find.text('Permissions'), findsOneWidget);
    });
  });

  group('the settings line', () {
    testWidgets('model, effort and mode each open their own menu; no workflow while none is picked', (tester) async {
      await pump(tester, agent: menu());
      expect(line('workflow'), findsNothing);
      expect(find.descendant(of: line('effort'), matching: find.text('Medium · Efficient')), findsOneWidget);

      await tester.tap(line('model'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('agent-menu.back')), findsNothing);
      expect(rowsStarting('agent-menu.model.'), findsWidgets);
      expect(find.byKey(const ValueKey('agent-menu.effort')), findsNothing);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();

      await tester.tap(line('effort'));
      await tester.pumpAndSettle();
      expect(find.text('Effort level'), findsOneWidget);
      expect(find.byKey(const ValueKey('agent-menu.effort.high')), findsOneWidget);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Ask'));
      await tester.pumpAndSettle();
      expect(find.text('Permissions'), findsOneWidget);
      await tester.tap(find.text('Plan'));
      await tester.pumpAndSettle();
      expect(modes, [AgentMode.plan]);
    });

    testWidgets('a picked workflow shows in the line and opens the Workflow page', (tester) async {
      await pump(tester, agent: menu(workflow: const WorkflowPick.max()));
      expect(find.descendant(of: line('workflow'), matching: find.text('Max')), findsOneWidget);
      await tester.tap(line('workflow'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('agent-menu.workflow.none')), findsOneWidget);
      expect(find.byKey(const ValueKey('agent-menu.back')), findsNothing);
    });

    testWidgets("an outside harness's line shows its native mode", (tester) async {
      await pump(tester, agent: menu(harness: 'alpha'), native: true);
      expect(find.descendant(of: strip('harness'), matching: find.text('Alpha CLI')), findsOneWidget);
      await tester.tap(find.text('Default'));
      await tester.pumpAndSettle();
      expect(find.text('Claude Code modes'), findsOneWidget);
    });

    testWidgets('a part lights up under the pointer', (tester) async {
      await pump(tester, agent: menu());
      Color? colour() =>
          tester.widget<Text>(find.descendant(of: line('model'), matching: find.byType(Text)).first).style?.color;
      final rest = colour();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(line('model')));
      await tester.pump();
      expect(colour(), isNot(rest));
    });
  });
}
