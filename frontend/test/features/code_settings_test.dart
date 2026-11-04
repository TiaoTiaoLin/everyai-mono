import 'dart:convert';

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/code/code_settings_providers.dart';
import 'package:every_ai/features/code/drivers/driver.dart';
import 'package:every_ai/features/code/drivers/driver_process.dart' show notBuiltProblem;
import 'package:every_ai/features/code/drivers/driver_registry.dart';
import 'package:every_ai/features/code/harness/events.dart' show ExecutionStatus;
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:every_ai/features/code/ui/code_settings_section.dart' show HarnessesSetting, harnessStatusLine;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/mcp_providers.dart';
import 'package:every_ai/features/code/permissions_providers.dart';
import 'package:every_ai/features/skills/skills_providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

/// A driver whose check the test sets.
final class _Driver implements HarnessDriver {
  _Driver(this.info, this.status);
  @override
  final DriverInfo info;
  DriverStatus status;
  var detects = 0;

  @override
  Set<DriverCap> get caps => const {};
  @override
  Future<DriverStatus> detect() async {
    detects++;
    return status;
  }

  @override
  Future<List<DriverModel>> models() async => const [];
  @override
  Future<HarnessSession> start(SessionSpec spec) => throw UnimplementedError();
  @override
  Future<HarnessSession> attach(String conversationId) => throw UnimplementedError();
  @override
  Future<Map<String, ExecutionStatus>> statuses(List<String> conversationIds) async => const {};
}

const _fs = McpServer(name: 'fs', command: 'npx', args: ['-y', 'server-fs']);

void main() {
  group('StoredCodeSettings', () {
    test('round-trips prompts and budgets, dropping empty ones', () {
      final s = const StoredCodeSettings()
          .withPrompt(null, '  Use British English. ')
          .withPrompt('p1', 'Use pnpm.')
          .withPrompt('p2', '')
          .withBudget('s1', 5)
          .withBudget('s2', 0);
      final back = StoredCodeSettings.fromJson(jsonDecode(jsonEncode(s.toJson())));
      expect(back.globalPrompt, 'Use British English.');
      expect(back.promptFor('p1'), 'Use pnpm.');
      expect(back.projectPrompts.containsKey('p2'), isFalse);
      expect(back.budgets, {'s1': 5.0});
      expect(back.withBudget('s1', null).budgets, isEmpty);
    });

    test('reads junk as empty', () {
      expect(StoredCodeSettings.fromJson('nope').globalPrompt, '');
      expect(
        StoredCodeSettings.fromJson({
          'sessions': {
            's': {'budgetUsd': 'x'},
          },
        }).budgets,
        isEmpty,
      );
    });
  });

  group('layers', () {
    final sources = CodeSettingsSources(
      settings: const StoredCodeSettings(globalPrompt: 'G', projectPrompts: {'p1': 'P'}),
      permissions: const StoredPermissions(
        global: PermissionRules(deny: ['git push *']),
        projects: {
          'p1': PermissionRules(allow: ['npm test *']),
        },
      ),
      mcp: StoredMcpServers(
        global: [_fs.approve()],
        projects: const {
          'p1': [McpServer(name: 'docs', transport: McpTransport.http, url: 'https://example.com/mcp')],
        },
      ),
      skills: const SkillSettings(disabled: {'library:slides'}, trusted: {'project:p1:x': 'abc'}),
      session: (model: 'anthropic/claude-haiku-5.5', effort: 'low', mode: AgentMode.plan, budgetUsd: 2.0),
    );

    test('each layer shows its own values, without approvals or trust', () {
      final global = layerJson(SettingsScope.global, sources);
      expect(global['systemPrompt'], 'G');
      expect(global['permissions'], {
        'allow': <String>[],
        'deny': ['git push *'],
      });
      expect((global['mcpServers']! as List).single, isNot(contains('approved')));
      expect(global['skills'], {
        'disabled': ['library:slides'],
      });
      final project = layerJson(SettingsScope.project, sources, projectId: 'p1');
      expect(project.keys, ['systemPrompt', 'permissions', 'mcpServers']);
      expect(project['systemPrompt'], 'P');
      final session = layerJson(SettingsScope.session, sources);
      expect(session, {'model': 'anthropic/claude-haiku-5.5', 'effort': 'low', 'mode': 'plan', 'budgetUsd': 2.0});
    });

    test('the effective view merges every layer', () {
      final e = effectiveJson(sources, projectId: 'p1');
      expect(e['systemPrompt'], 'G\n\nP');
      expect(e['permissions'], {
        'allow': ['npm test *'],
        'deny': ['git push *'],
      });
      expect([for (final s in e['mcpServers']! as List) (s as Map)['name']], ['fs', 'docs']);
      expect(((e['mcpServers']! as List).first as Map)['active'], isTrue);
      expect(e['mode'], 'plan');
    });
  });

  test('withSystemPrompts appends a block only when there are prompts', () {
    expect(withSystemPrompts('BASE', global: ' ', project: ''), 'BASE');
    final s = withSystemPrompts('BASE', global: 'Be brief.', project: 'Use pnpm.');
    expect(s, startsWith('BASE\n\n<USER_SYSTEM_PROMPT>\n'));
    expect(s, contains('\nBe brief.\n'));
    expect(s, contains('For this project:\nUse pnpm.\n'));
    expect(s, endsWith('</USER_SYSTEM_PROMPT>'));
    expect(withSystemPrompts('B', global: '', project: 'P'), isNot(contains('\n\n\nFor')));
  });

  test('crossedBudget fires once, at the crossing', () {
    expect(crossedBudget(0, 900000, 1), isFalse);
    expect(crossedBudget(900000, 1000000, 1), isTrue);
    expect(crossedBudget(1000000, 1200000, 1), isFalse);
    expect(crossedBudget(0, 5000000, null), isFalse);
    expect(budgetFill(500000, 2), 0.25);
    expect(budgetFill(5, null), isNull);
  });

  test('"Use my own installed CLIs" is off by default and kept per CLI', () {
    const off = StoredCodeSettings();
    expect(off.ownClis, isEmpty);
    expect(off.toJson()['global'], isNot(contains('ownClis')));
    final on = off.withOwnCli('claude-code', true).withOwnCli('gemini', true).withOwnCli('gemini', false);
    expect(on.ownClis, {'claude-code'});
    expect(StoredCodeSettings.fromJson(jsonDecode(jsonEncode(on.toJson()))).ownClis, {'claude-code'});
    // Other edits keep it.
    expect(on.withTier(HarnessTier.thorough).ownClis, {'claude-code'});
  });

  test('a harness status reads in plain words', () {
    expect(harnessStatusLine('everyai', const DriverStatus(installed: true)), 'Built in');
    expect(harnessStatusLine('codex', const DriverStatus()), 'Not installed');
    expect(
      harnessStatusLine('claude-code', const DriverStatus(installed: true, version: '2.1.318', signedIn: true)),
      '2.1.318 · signed in',
    );
    expect(
      harnessStatusLine('opencode', const DriverStatus(installed: true, version: '2.1.3', problem: notBuiltProblem)),
      '2.1.3 · Not built yet',
    );
  });

  testWidgets('Settings → Code → Harnesses: statuses, install hints, the consent switch and Refresh', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    late Preferences prefs;
    await tester.runAsync(() async => prefs = await Preferences.load(db));
    final claude = _Driver(
      const DriverInfo(id: 'claude-code', label: 'Claude Code', needsConsent: true),
      const DriverStatus(installed: true, version: '2.1.318', problem: notBuiltProblem),
    );
    final codex = _Driver(
      const DriverInfo(id: 'codex', label: 'Codex', installHint: 'npm install -g @openai/codex'),
      const DriverStatus(),
    );
    var reloads = 0;
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        preferencesProvider.overrideWithValue(prefs),
        driverRegistryProvider.overrideWithValue(DriverRegistry({'claude-code': claude, 'codex': codex})),
        driverStatusesProvider.overrideWith(
          () => DriverStatuses(loadShell: () async {}, reloadShell: () async => reloads++),
        ),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: m.MaterialApp(
          home: EveryThemeScope(
            theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light),
            child: const m.Scaffold(body: SingleChildScrollView(child: HarnessesSetting())),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('2.1.318 · Not built yet'), findsOneWidget);
    expect(find.text('Not installed'), findsOneWidget);
    // Every harness is listed; a missing one says how to install it.
    expect(find.text('To install: npm install -g @openai/codex'), findsOneWidget);
    expect(find.byKey(const ValueKey('code-settings.harness.claude-code.hint')), findsNothing);
    expect(find.text('Checked just now'), findsOneWidget);
    expect(find.textContaining('Claude Code run the copy installed on this computer'), findsOneWidget);
    // Only the subscription CLI has the switch, and it starts off.
    expect(find.byKey(const ValueKey('code-settings.own-cli.codex')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('code-settings.own-cli.claude-code')));
    await tester.pump();
    expect(container.read(codeSettingsProvider).ownClis, {'claude-code'});

    codex.status = const DriverStatus(installed: true, version: '0.9');
    await tester.tap(find.byKey(const ValueKey('code-settings.harnesses.refresh')));
    await tester.pump();
    await tester.pump();
    expect(codex.detects, 2);
    expect(reloads, 1);
    expect(find.text('0.9'), findsOneWidget);
    expect(find.textContaining('To install'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    await tester.runAsync(db.close);
  });
}
