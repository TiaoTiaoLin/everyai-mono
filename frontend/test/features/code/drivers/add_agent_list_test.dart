import 'dart:convert';
import 'dart:io';

import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/code/drivers/acp/acp_driver.dart';
import 'package:every_ai/features/code/drivers/driver_registry.dart';
import 'package:every_ai/features/code/drivers/registry_install/acp_registry.dart';
import 'package:every_ai/features/code/drivers/registry_install/installed_agents.dart';
import 'package:every_ai/features/code/drivers/registry_install/ui/add_agent_list.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart' as m;

final _fixture = File('test/fixtures/drivers/acp_registry/registry.json').readAsStringSync();

void main() {
  late Preferences prefs;
  late int rescans;
  late ProviderContainer c;
  var fetched = false;

  setUp(() {
    prefs = Preferences.inMemory();
    rescans = 0;
    fetched = false;
    c = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(prefs),
        driverRegistryProvider.overrideWithValue(
          DriverRegistry({'gemini': AcpDriver(id: 'gemini', label: 'Gemini CLI', command: 'gemini')}),
        ),
        rescanHarnessesProvider.overrideWithValue((_) => rescans++),
        acpRegistryClientProvider.overrideWithValue(
          AcpRegistryClient(prefs, client: MockClient((_) async => http.Response(_fixture, 200))),
        ),
        agentInstallerProvider.overrideWithValue(
          AgentInstaller(
            client: MockClient((_) async {
              fetched = true;
              return http.Response('', 404);
            }),
            dataDir: () async => '/nonexistent',
            platform: () => 'darwin-aarch64',
            makeDir: (_) async {},
          ),
        ),
        agentRunnersProvider.overrideWith((ref) async => {DistKind.npx: false, DistKind.uvx: true}),
      ],
    );
    addTearDown(c.dispose);
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.runAsync(() async {
      await c.read(acpRegistryProvider.future);
      await c.read(agentRunnersProvider.future);
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: m.MaterialApp(
          home: EveryThemeScope(
            theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light),
            child: const m.Scaffold(body: SingleChildScrollView(child: AddAgentList())),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('a download without a checksum asks before installing', (tester) async {
    await pump(tester);
    expect(find.text('Cursor'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('add-agent.cursor.install')));
    await tester.pump();
    expect(find.byKey(const ValueKey('add-agent.cursor.unchecked')), findsOneWidget);
    expect(fetched, isFalse);
    await tester.tap(find.byKey(const ValueKey('add-agent.cursor.cancel')));
    await tester.pump();
    expect(find.byKey(const ValueKey('add-agent.cursor.unchecked')), findsNothing);
  });

  testWidgets('an npx agent without Node.js says so, and installing it checks the harnesses again', (tester) async {
    await pump(tester);
    expect(find.byKey(const ValueKey('add-agent.gemini.runner')), findsOneWidget);
    expect(find.byKey(const ValueKey('add-agent.fast-agent.runner')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('add-agent.gemini.install')));
    await tester.pump();
    await tester.pump();
    expect(rescans, 1);
    expect(c.read(installedAgentsProvider).keys, ['gemini']);
    expect(c.read(driverRegistryProvider).resolve('registry:gemini'), isA<AcpDriver>());
    expect(find.byKey(const ValueKey('add-agent.gemini.remove')), findsOneWidget);
    expect(jsonDecode(prefs[installedAgentsKey]!), containsPair('v', 1));

    await tester.tap(find.byKey(const ValueKey('add-agent.gemini.remove')));
    await tester.pump();
    await tester.pump();
    expect(rescans, 2);
    expect(c.read(installedAgentsProvider), isEmpty);
    expect(c.read(driverRegistryProvider).resolve('registry:gemini'), isNull);
  });

  testWidgets('a newer registry version offers Update', (tester) async {
    prefs[installedAgentsKey] = jsonEncode({
      'v': 1,
      'agents': {
        'gemini': const InstalledAgent(
          id: 'gemini',
          name: 'Gemini CLI',
          version: '0.65.0',
          kind: DistKind.npx,
          package: '@google/gemini-cli@0.65.0',
          home: '/nonexistent/agents/gemini',
        ).toJson(),
      },
    });
    await pump(tester);
    expect(find.byKey(const ValueKey('add-agent.gemini.update')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('add-agent.gemini.update')));
    await tester.pump();
    await tester.pump();
    expect(c.read(installedAgentsProvider)['gemini']!.package, '@google/gemini-cli@0.66.0');
  });
}
