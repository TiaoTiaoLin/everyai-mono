import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/net/api_client.dart';
import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/code_settings_providers.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/domain/transcript.dart';
import 'package:every_ai/features/code/drivers/acp/acp_mapping.dart' show agentMessageEvent, userMessageEvent;
import 'package:every_ai/features/code/drivers/driver.dart';
import 'package:every_ai/features/code/drivers/driver_registry.dart';
import 'package:every_ai/features/code/gateway_key.dart';
import 'package:every_ai/features/code/git/git_service_io.dart' show worktreePaths;
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:every_ai/features/code/host/host_providers.dart';
import 'package:every_ai/features/code/resume/past_sessions.dart';
import 'package:every_ai/features/code/resume/resume_providers.dart';
import 'package:every_ai/features/code/ui/code_home.dart' show PastSessionTile;
import 'package:every_ai/features/models/models_providers.dart';
import 'package:every_ai/features/usage/usage_totals.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart' as m;

import '../../support/fake_leads.dart';

/// A harness's own sessions for a folder, as a test lists them.
final class _Source implements PastSessionSource {
  _Source(this.harness, this.sessions, {this.gate, this.fails = false});

  @override
  final String harness;
  final List<PastSession> sessions;
  final Completer<void>? gate;
  final bool fails;
  final asked = <(String, List<String>)>[];

  @override
  Future<List<PastSession>> list(String folder, {List<String> worktrees = const []}) async {
    asked.add((folder, worktrees));
    if (gate case final g?) await g.future;
    if (fails) throw StateError('unreadable');
    return sessions;
  }

  @override
  Future<List<HarnessEvent>> history(PastSession session) async => const [];
}

/// [FakeLeadDriver] that takes over a CLI's own conversation: adopting one makes it reopenable, replaying
/// [cliHistory] on attach only when [replays].
final class _Adopting implements HarnessDriver, AttachesBriefed, AdoptsNativeSession {
  _Adopting(this.inner, {this.replays = false, this.cliHistory = const [], this.ownId});

  final FakeLeadDriver inner;
  final bool replays;
  final List<HarnessEvent> cliHistory;

  /// The id it keys an adopted session by, when not the native one (ACP).
  final String? ownId;
  final adopted = <({String id, String cwd, String tag})>[];

  @override
  Future<String> adoptNative(
    String nativeId, {
    required String cwd,
    required String sessionTag,
    required String model,
    String? effort,
    required AgentMode mode,
  }) async {
    adopted.add((id: nativeId, cwd: cwd, tag: sessionTag));
    final id = ownId ?? nativeId;
    inner.conversations[id] = FakeLeadSession(id: id, replays: true, history: replays ? cliHistory : const []);
    return id;
  }

  @override
  bool get replaysNativeHistory => replays;

  @override
  DriverInfo get info => inner.info;
  @override
  Set<DriverCap> get caps => inner.caps;
  @override
  Future<DriverStatus> detect() => inner.detect();
  @override
  Future<List<DriverModel>> models() => inner.models();
  @override
  Future<HarnessSession> start(SessionSpec spec) => inner.start(spec);
  @override
  Future<HarnessSession> attach(String conversationId) => inner.attach(conversationId);
  @override
  Future<HarnessSession> attachBriefed(
    String conversationId,
    DriverBriefing briefing, {
    Map<String, Object?> mcpConfig = const {},
  }) => inner.attachBriefed(conversationId, briefing, mcpConfig: mcpConfig);
  @override
  Future<Map<String, ExecutionStatus>> statuses(List<String> conversationIds) => inner.statuses(conversationIds);
}

final _noNetwork = MockClient((req) async => http.Response('no network in this test', 599));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late Directory tmp;
  late Directory project;
  late Preferences prefs;
  late ProviderContainer container;
  late Map<String, HarnessDriver> drivers;
  late List<PastSessionSource> sources;
  var gitTrees = <String>[];

  ProviderContainer make() => ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      preferencesProvider.overrideWithValue(prefs),
      modelCatalogProvider.overrideWith(FixedCatalog.new),
      codeUsageProvider.overrideWithBuild((ref, n) async => UsageTotals.zero),
      driverRegistryProvider.overrideWithValue(DriverRegistry({...drivers})),
      hostServerProvider.overrideWithValue(FakeHost()),
      driverDataDirProvider.overrideWithValue(() async => '${tmp.path}/data'),
      gatewayKeysProvider.overrideWith((ref) => throw StateError('no gateway key for outside agents')),
      apiClientProvider.overrideWithValue(ApiClient(baseUrl: Uri.parse('http://backend/'), client: _noNetwork)),
      pastSessionSourcesProvider.overrideWith((ref) => sources),
      pastSessionTimeoutProvider.overrideWithValue(const Duration(milliseconds: 200)),
      gitWorktreesProvider.overrideWithValue((dir) async => gitTrees),
    ],
  );

  PastSession past(String harness, String id, {required DateTime at, String? cwd, String title = 'Fix the login'}) =>
      PastSession(
        harness: harness,
        nativeId: id,
        cwd: cwd ?? project.path,
        title: title,
        lastActive: at,
        turns: 3,
        model: 'm1',
        branch: 'main',
      );

  CodeProject theProject() => container.read(codeProjectsProvider).single;
  Future<List<PastSession>> listed() => container.read(pastSessionsProvider('p1').future);

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    tmp = await Directory.systemTemp.createTemp('code-resume');
    project = await Directory('${tmp.path}/project').create();
    drivers = {
      everyaiHarnessName: FakeLeadDriver(everyaiHarnessName, label: 'EveryAI'),
      'alpha': _Adopting(FakeLeadDriver('alpha', label: 'Alpha')),
      'beta': _Adopting(FakeLeadDriver('beta', label: 'Beta')),
      'gone': _Adopting(FakeLeadDriver('gone', label: 'Gone', status: const DriverStatus())),
      'off': _Adopting(
        FakeLeadDriver('off', label: 'Off', status: const DriverStatus(installed: true, signedIn: false)),
      ),
      'cli': _Adopting(FakeLeadDriver('cli', label: 'Consent', needsConsent: true)),
    };
    sources = const [];
    gitTrees = [];
    prefs = await Preferences.load(db);
    prefs['code.projects'] = jsonEncode([CodeProject(id: 'p1', name: 'P', path: project.path).toJson()]);
    container = make();
  });

  tearDown(() async {
    container.dispose();
    await db.close();
    await tmp.delete(recursive: true);
  });

  test('every installed harness is listed for the folder, newest first; a slow or broken one is left out', () async {
    final slow = Completer<void>();
    final alpha = _Source('alpha', [past('alpha', 'a1', at: DateTime(2026, 11, 1))]);
    sources = [
      alpha,
      _Source('beta', [past('beta', 'b1', at: DateTime(2026, 11, 3))]),
      _Source('cli', [past('cli', 'x1', at: DateTime(2026, 11, 2))], gate: slow),
      _Source('off', const [], fails: true),
      // Not installed: never asked.
      _Source('gone', [past('gone', 'g1', at: DateTime(2026, 11, 4))]),
    ];
    container = make();
    final got = await listed();
    expect([for (final p in got) p.nativeId], ['b1', 'a1']);
    expect(alpha.asked.single.$1, project.path);
    expect((sources[4] as _Source).asked, isEmpty);
    slow.complete();
  });

  test(
    "a conversation EveryAI already keeps shows once, as ours, marked; blocked harnesses say what's in the way",
    () async {
      final info = await container
          .read(codeSessionsProvider.notifier)
          .start(project: theProject(), prompt: 'Add dark mode', model: '', mode: AgentMode.ask, harness: 'alpha');
      sources = [
        _Source('alpha', [
          past('alpha', info.conversationId, at: DateTime(2026, 11, 3)),
          past('alpha', 'a2', at: DateTime(2026, 11, 2)),
        ]),
        _Source('off', [past('off', 'o1', at: DateTime(2026, 11, 1))]),
        _Source('cli', [past('cli', 'c1', at: DateTime(2026, 10, 30))]),
      ];
      container.invalidate(pastSessionSourcesProvider);
      expect([for (final p in await listed()) p.nativeId], ['a2', 'o1', 'c1']);
      final rows = container.read(earlierSessionsProvider('p1'));
      expect(rows.first.ours?.id, info.id);
      expect(
        [for (final r in rows.skip(1)) (r.past!.nativeId, r.blocked)],
        [('a2', null), ('o1', 'Not signed in'), ('c1', 'Turn on in Settings → Code → Harnesses')],
      );
    },
  );

  test('resuming runs on its own harness in the folder it ran in, reopened by its id, with its history once', () async {
    final worktree = await Directory('${tmp.path}/wt').create();
    final history = [userMessageEvent('h-u', 'Fix the login'), agentMessageEvent('h-a', 'Fixed it.')];
    final alpha = drivers['alpha']! as _Adopting;
    final pick = past('alpha', 'native-1', at: DateTime(2026, 11, 1), cwd: worktree.path);
    final info = await container
        .read(codeSessionsProvider.notifier)
        .resumePast(project: theProject(), past: pick, mode: AgentMode.autoEdit, history: history);
    expect(
      (info.harness, info.conversationId, info.workingDir, info.mode),
      ('alpha', 'native-1', worktree.path, AgentMode.autoEdit),
    );
    expect(alpha.adopted.single, (id: 'native-1', cwd: worktree.path, tag: info.id));
    expect(info.worktree, isNull);
    container.listen(codeSessionProvider(info.id), (_, _) {});
    await whenValue(container, codeSessionProvider(info.id).select((s) => s.connected), (bool c) => c);
    await pumpEventQueue();
    expect(alpha.inner.attached, ['native-1']);
    // Briefed like any reopen of an outside session.
    expect(alpha.inner.reopened, hasLength(1));
    final texts = [
      for (final i in container.read(codeSessionProvider(info.id)).transcript.items)
        if (i is UserTurn) i.text else if (i is AgentText) i.text,
    ];
    expect(texts, ['Fix the login', 'Fixed it.']);
  });

  test("a driver that replays the conversation itself isn't given the history twice", () async {
    final history = [userMessageEvent('h-u', 'Fix the login'), agentMessageEvent('h-a', 'Fixed it.')];
    drivers['beta'] = _Adopting(FakeLeadDriver('beta', label: 'Beta'), replays: true, cliHistory: history);
    container = make();
    final info = await container
        .read(codeSessionsProvider.notifier)
        .resumePast(
          project: theProject(),
          past: past('beta', 'n2', at: DateTime(2026, 11, 1)),
          mode: AgentMode.ask,
          history: history,
        );
    container.listen(codeSessionProvider(info.id), (_, _) {});
    await whenValue(container, codeSessionProvider(info.id).select((s) => s.connected), (bool c) => c);
    await pumpEventQueue();
    final texts = [
      for (final i in container.read(codeSessionProvider(info.id)).transcript.items)
        if (i is UserTurn) i.text else if (i is AgentText) i.text,
    ];
    expect(texts, ['Fix the login', 'Fixed it.']);
  });

  test('an ACP-style driver keys the session by its own id; consent is checked first', () async {
    drivers['beta'] = _Adopting(FakeLeadDriver('beta', label: 'Beta'), ownId: 'ours-1');
    container = make();
    final info = await container
        .read(codeSessionsProvider.notifier)
        .resumePast(
          project: theProject(),
          past: past('beta', 'acp-9', at: DateTime(2026, 11, 1)),
          mode: AgentMode.ask,
        );
    expect(info.conversationId, 'ours-1');
    await expectLater(
      container
          .read(codeSessionsProvider.notifier)
          .resumePast(
            project: theProject(),
            past: past('cli', 'c1', at: DateTime(2026, 11, 1)),
            mode: AgentMode.ask,
          ),
      throwsA(isA<HarnessError>()),
    );
    expect((drivers['cli']! as _Adopting).adopted, isEmpty);
    container.read(codeSettingsProvider.notifier).setOwnCli('cli', true);
    final ok = await container
        .read(codeSessionsProvider.notifier)
        .resumePast(
          project: theProject(),
          past: past('cli', 'c1', at: DateTime(2026, 11, 1)),
          mode: AgentMode.ask,
        );
    expect(ok.harness, 'cli');
  });

  testWidgets('a blocked row is greyed with its reason and does nothing on a tap', (tester) async {
    var opened = 0;
    Widget host(Widget child) => m.MaterialApp(
      home: EveryThemeScope(
        theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light),
        child: m.Scaffold(body: child),
      ),
    );
    final p = PastSession(
      harness: 'alpha',
      nativeId: 'a1',
      cwd: '/x',
      title: 'Fix the login',
      lastActive: DateTime.now().subtract(const Duration(hours: 2)),
      turns: 4,
      model: 'm1',
      branch: 'feat/login',
    );
    await tester.pumpWidget(
      host(
        Column(
          children: [
            PastSessionTile(key: const ValueKey('ok'), past: p, label: 'Alpha', onOpen: () => opened++),
            PastSessionTile(
              key: const ValueKey('no'),
              past: p,
              label: 'Alpha',
              blocked: 'Not signed in',
              onOpen: () => opened++,
            ),
          ],
        ),
      ),
    );
    expect(find.text('Alpha · m1 · 2h · 4 turns · feat/login'), findsOneWidget);
    expect(find.text('Not signed in'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('no')));
    expect(opened, 0);
    await tester.tap(find.byKey(const ValueKey('ok')));
    expect(opened, 1);
  });

  test("the folder's git worktrees are searched too, made by EveryAI or not", () async {
    final alpha = _Source('alpha', const []);
    sources = [alpha];
    gitTrees = [project.path, '/elsewhere/feature-wt'];
    container = make();
    await listed();
    expect(alpha.asked.single.$1, project.path);
    expect(alpha.asked.single.$2, ['/elsewhere/feature-wt']);
  });

  test('worktree paths are read from git worktree list --porcelain; bare and prunable ones left out', () {
    const out =
        'worktree /repo\nHEAD abc\nbranch refs/heads/main\n\nworktree /wt/a\nHEAD def\ndetached\n\n'
        'worktree /wt/gone\nHEAD 123\nprunable gitdir file points to non-existent location\n\nworktree /bare\nbare\n';
    expect(worktreePaths(out), ['/repo', '/wt/a']);
    expect(worktreePaths(''), isEmpty);
  });

  test("a lead switch after a resume hands over the resumed conversation's history too", () async {
    final history = [userMessageEvent('h-u', 'Fix the login'), agentMessageEvent('h-a', 'Fixed it in auth.dart.')];
    final info = await container
        .read(codeSessionsProvider.notifier)
        .resumePast(
          project: theProject(),
          past: past('alpha', 'native-1', at: DateTime(2026, 11, 1)),
          mode: AgentMode.ask,
          history: history,
        );
    container.listen(codeSessionProvider(info.id), (_, _) {});
    await whenValue(container, codeSessionProvider(info.id).select((s) => s.connected), (bool c) => c);
    await pumpEventQueue();
    final outcome = await container.read(codeSessionProvider(info.id).notifier).switchLead('beta', run: true);
    expect(outcome.failed, isFalse);
    final beta = (drivers['beta']! as _Adopting).inner;
    final first = beta.specs.single.initialMessage!;
    final path = RegExp(r'<transcript>\n(.+)\n</transcript>').firstMatch(first)![1]!;
    final file = File('${project.path}/$path').readAsStringSync();
    expect(file, contains('# Alpha'));
    expect(file, contains('Fix the login'));
    expect(file, contains('Fixed it in auth.dart.'));
  });
}
