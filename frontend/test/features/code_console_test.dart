import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/domain/session_commands.dart';
import 'package:every_ai/features/code/drivers/usage_limit.dart';
import 'package:every_ai/features/code/git/git_service.dart';
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:every_ai/features/code/ui/console/console_header.dart';
import 'package:every_ai/features/code/ui/console/console_layout.dart';
import 'package:every_ai/features/code/ui/console/console_state.dart';
import 'package:every_ai/features/code/ui/console/context_breakdown.dart';
import 'package:every_ai/features/code/ui/console/git_button.dart';
import 'package:every_ai/features/code/ui/console/session_info_view.dart';
import 'package:every_ai/features/models/domain/model_catalog.dart';
import 'package:every_ai/features/models/models_providers.dart';
import 'package:every_ai/features/usage/usage_totals.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:every_ai/features/code/harness/events.dart' show PlanLimits, PlanWindow;
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart' as m;

/// A worktree removal that takes a while: the session leaves the list first, the rest waits on [gate].
final class _SlowDiscard extends CodeGit {
  _SlowDiscard(this.gate, super.sessionId);
  final Completer<void> gate;

  @override
  Future<GitSnapshot> build() async => const GitSnapshot();

  @override
  Future<void> discard() async {
    await ref.read(codeSessionsProvider.notifier).remove(sessionId);
    await gate.future;
  }
}

class _FixedCatalog extends CatalogController {
  @override
  ModelCatalog build() => builtInCatalog;
}

const _worktree = SessionWorktree(
  repoRoot: '/repo',
  path: '/wt/fix',
  branch: 'everyai/fix-abc',
  baseBranch: 'main',
  baseCommit: 'abc123',
);

CodeSessionInfo _session(
  String id, {
  String? parentId,
  String workingDir = 'demo://counter-app',
  SessionWorktree? worktree,
  GitBaseline? baseline,
  bool pinned = false,
  String title = 'Fix the counter',
}) => CodeSessionInfo(
  id: id,
  projectId: 'p1',
  title: title,
  conversationId: 'conv-$id',
  model: 'anthropic/claude-haiku-5.5',
  mode: AgentMode.ask,
  workingDir: workingDir,
  createdAt: DateTime(2026),
  parentId: parentId,
  worktree: worktree,
  baseline: baseline,
  pinned: pinned,
);

void main() {
  group('console panel state', () {
    ProviderContainer containerWith(Preferences prefs) {
      final c = ProviderContainer(overrides: [preferencesProvider.overrideWithValue(prefs)]);
      addTearDown(c.dispose);
      return c;
    }

    test('opens on Session info the first time; the active view closes it, another switches it', () {
      final c = containerWith(Preferences.inMemory());
      final panel = c.read(consolePanelProvider('s').notifier);
      expect(c.read(consolePanelProvider('s')).view, ConsoleView.info);
      panel.toggle(ConsoleView.info);
      expect(c.read(consolePanelProvider('s')).view, isNull);
      panel.toggle(ConsoleView.diff);
      expect(c.read(consolePanelProvider('s')).view, ConsoleView.diff);
      panel.toggle(ConsoleView.info);
      expect(c.read(consolePanelProvider('s')).view, ConsoleView.info);
      expect(c.read(consolePanelProvider('other')).view, ConsoleView.info);
    });

    test('each session remembers its view and width; a closed panel stays closed', () {
      final prefs = Preferences.inMemory();
      final first = containerWith(prefs);
      first.read(consolePanelProvider('a').notifier)
        ..show(ConsoleView.diff)
        ..setWidth(400, persist: false)
        ..setWidth(512);
      first.read(consolePanelProvider('b').notifier).close();

      final again = containerWith(prefs);
      expect(again.read(consolePanelProvider('a')).view, ConsoleView.diff);
      expect(again.read(consolePanelProvider('a')).width, 512);
      expect(again.read(consolePanelProvider('b')).view, isNull);
      expect(prefs['${codeLayoutPrefix}a'], isNotNull);
    });

    test('showDiff asks again each time; a child chat sits over the view until Back', () {
      final c = containerWith(Preferences.inMemory());
      final panel = c.read(consolePanelProvider('s').notifier)..showDiff('lib/a.dart');
      final seq = c.read(consolePanelProvider('s')).focusSeq;
      panel.showDiff('lib/a.dart');
      expect(c.read(consolePanelProvider('s')).focusSeq, seq + 1);
      expect(c.read(consolePanelProvider('s')).focus, 'lib/a.dart');

      panel
        ..show(ConsoleView.info)
        ..openChild('child');
      expect(c.read(consolePanelProvider('s')).child, 'child');
      panel.back();
      expect(c.read(consolePanelProvider('s')).child, isNull);
      expect(c.read(consolePanelProvider('s')).view, ConsoleView.info);
    });
  });

  test('the git button follows the work: commit, the open PR, create one, merge locally', () {
    GitAction? at({
      bool worktree = true,
      bool dirty = false,
      int ahead = 0,
      bool remote = false,
      BranchPr? pr,
      String head = 'h1',
    }) => gitActionFor(worktree: worktree, dirty: dirty, ahead: ahead, hasRemote: remote, pr: pr, head: head);
    const pr = (number: 12, url: 'https://github.com/o/r/pull/12', open: true, head: 'h0');
    const merged = (number: 12, url: 'https://github.com/o/r/pull/12', open: false, head: 'h1');

    expect(at(worktree: false, dirty: true), isNull);
    expect(at(dirty: true, ahead: 2, remote: true, pr: pr)!.label, 'Commit');
    expect(at(ahead: 2, remote: true, pr: pr)!, (
      kind: GitActionKind.viewPr,
      label: 'View PR #12',
      enabled: true,
      url: pr.url,
    ));
    expect(at(ahead: 2, remote: true)!.kind, GitActionKind.createPr);
    // Squash-merged on GitHub: the commits still count as ahead, but another PR for them would be a duplicate.
    expect(at(ahead: 2, remote: true, pr: merged)!.label, 'View PR #12');
    expect(at(ahead: 3, remote: true, pr: merged, head: 'h2')!.kind, GitActionKind.createPr);
    expect(at(ahead: 2)!.kind, GitActionKind.mergeLocally);
    expect(at()!, (kind: GitActionKind.commit, label: 'Commit', enabled: false, url: null));
  });

  test('gh pr view: the latest pull request, open or not, with its head', () {
    String json(String state) => '{"number":7,"url":"https://x/pull/7","state":"$state","headRefOid":"abc"}';
    expect(parsePrView(json('OPEN')), (number: 7, url: 'https://x/pull/7', open: true, head: 'abc'));
    expect(parsePrView(json('MERGED'))?.open, isFalse);
    expect(parsePrView(json('CLOSED'))?.open, isFalse);
    expect(parsePrView('no pull requests found for branch "x"'), isNull);
    expect(parsePrView('[]'), isNull);
  });

  test('the Plans menu reads the host listing of saved plans', () {
    expect(parseSavedPlans('- 2026-11-04-auth.md: Add sign-in\n- old.md'), [
      (file: '2026-11-04-auth.md', title: 'Add sign-in'),
      (file: 'old.md', title: 'old.md'),
    ]);
    expect(parseSavedPlans('No saved plans yet.'), isEmpty);
  });

  group('Session info', () {
    test('Environment says where the work happens', () {
      List<(String, String)> rows(CodeSessionInfo info) =>
          environmentRows(harness: 'EveryAI', model: 'Haiku 5.5', project: '~/app', info: info, remote: 'Off');
      expect(
        rows(_session('w', workingDir: '/wt/fix', worktree: _worktree)),
        contains(('Branch', 'everyai/fix-abc → main · own worktree')),
      );
      final inPlace = _session(
        'b',
        workingDir: '/repo',
        baseline: const GitBaseline(repoRoot: '/repo', dir: '/repo', branch: 'main', commit: 'h', tree: 't'),
      );
      expect(rows(inPlace), contains(('Branch', 'In place on main · your own checkout')));
      expect(rows(_session('n', workingDir: '/tmp/notes')), contains(('Branch', 'Not a git repository')));
      expect(rows(_session('n')).map((r) => r.$1), isNot(contains('Branch')));
      expect(rows(_session('n')).last, ('Remote control', 'Off'));
    });

    test('Context on the EveryAI harness: real totals, estimated parts, the rest named for what it is', () {
      final b = contextRows(
        used: 50000,
        limit: 200000,
        parts: [
          ContextPart(ContextKind.systemPrompt, 'x' * 4000),
          ContextPart(ContextKind.tools, 'y' * 800, name: 'bash'),
          ContextPart(ContextKind.mcpTools, 'z' * 400, name: 'github'),
          ContextPart(ContextKind.mcpTools, 'z' * 400, name: 'github'),
          ContextPart(ContextKind.mcpTools, 'z' * 400, name: 'linear'),
        ],
        outside: false,
        autoCompactPercent: 80,
      );
      final byLabel = {for (final r in b.rows) r.label: r};
      expect(byLabel['System prompt']!.tokens, 1000);
      expect(byLabel['System prompt']!.estimated, isTrue);
      expect(byLabel['MCP tools']!.children, [(name: 'github', tokens: 200), (name: 'linear', tokens: 100)]);
      expect(byLabel['Messages and tool results']!.tokens, 50000 - 1000 - 200 - 300);
      expect(byLabel['Autocompact buffer']!.tokens, 40000);
      expect(byLabel['Autocompact buffer']!.estimated, isFalse);
      expect(byLabel['Free space']!.tokens, 200000 - 50000 - 40000);
      expect(byLabel.keys, isNot(contains('Harness (not itemised)')));
    });

    testWidgets('Context on an outside lead: only our parts are itemised, no bar without a known window', (
      tester,
    ) async {
      final b = contextRows(
        used: 30000,
        limit: 0,
        parts: [
          ContextPart(ContextKind.briefing, 'b' * 2000),
          ContextPart(ContextKind.mcpTools, 't' * 400, name: 'everyai'),
        ],
        outside: true,
        autoCompactPercent: 80,
      );
      expect(b.rows.map((r) => r.label), ['EveryAI briefing', 'MCP tools', 'Harness (not itemised)']);
      await tester.pumpWidget(_app(ContextView(breakdown: b)));
      expect(find.text('30.0K used · limit not reported'), findsOneWidget);
      expect(find.byKey(const ValueKey('console.context.bar')), findsNothing);
      expect(find.text('≈500'), findsOneWidget);
      expect(find.textContaining('Harness (not itemised)'), findsOneWidget);
      expect(find.textContaining('estimated from length'), findsOneWidget);
    });

    test('usage lines: each plan window the lead reported, with its reset', () {
      final now = DateTime(2026, 11, 5, 12);
      final plan = PlanLimits.of(
        id: 'x',
        windows: [
          PlanWindow(name: 'seven_day', used: 0.35, resetsAt: DateTime(2026, 11, 5, 19, 59).toUtc(), minutes: 10080),
          const PlanWindow(name: 'five_hour', used: 0.1, minutes: 300),
        ],
      );
      final lines = usageLines(totals: UsageTotals.zero, plan: plan, outsideLabel: 'Claude Code', now: now);
      expect(lines, containsAllInOrder(['This week: 35% used · resets 19:59', '5-hour window: 10% used']));
      expect(lines.any((l) => l.contains('not reported')), isFalse);
      expect(planWindowName(const PlanWindow(name: 'seven_day_opus', used: 0, minutes: 10080)), 'This week (Opus)');
    });

    test('Usage shows a reached limit with its reset time, and says when a harness reports none', () {
      final now = DateTime(2026, 11, 4, 9);
      final lines = usageLines(
        totals: UsageTotals.zero,
        limit: UsageLimit(message: 'You hit your limit', resetsAt: DateTime(2026, 11, 4, 14, 5)),
        outsideLabel: 'Claude Code',
        now: now,
      );
      expect(lines, ['No model calls yet', 'No spending cap', 'Limit reached · resets 14:05']);
      expect(
        usageLines(totals: UsageTotals.zero, outsideLabel: 'Codex', budget: 5).last,
        'Plan limits: not reported by Codex',
      );
    });
  });

  group('console widgets', () {
    late AppDatabase db;
    late Preferences prefs;
    late ProviderContainer container;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      prefs = Preferences.inMemory();
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    Future<void> pump(
      WidgetTester tester,
      Widget child, {
      List<CodeSessionInfo> sessions = const [],
      Size? size,
      List<Override> extra = const [],
    }) async {
      prefs['code.sessions'] = jsonEncode([for (final s in sessions) s.toJson()]);
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(prefs),
          modelCatalogProvider.overrideWith(_FixedCatalog.new),
          codeUsageProvider.overrideWithBuild((ref, n) async => UsageTotals.zero),
          gitButtonProvider.overrideWith((ref, id) async => null),
          sessionRemoteLineProvider.overrideWithValue('Off'),
          ...extra,
        ],
      );
      if (size != null) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
      }
      final router = GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, _) => child),
          GoRoute(path: '/code', builder: (_, _) => const Text('code home')),
          GoRoute(path: '/code/s/:id', builder: (_, s) => Text('full ${s.pathParameters['id']}')),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: _app(null, router: router),
        ),
      );
      await tester.pump();
    }

    /// Unmounts the tree, so the panel's timers stop with the test.
    Future<void> unmount(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    }

    testWidgets('header icons switch the panel, the active one closes it, Diff only in git', (tester) async {
      final git = _session('g', workingDir: '/wt/fix', worktree: _worktree);
      final demo = _session('d');
      await pump(
        tester,
        Column(
          children: [
            ConsoleActions(info: git, tier: ConsoleTier.wide),
            ConsoleActions(info: demo, tier: ConsoleTier.wide),
          ],
        ),
        sessions: [git, demo],
      );
      expect(find.byKey(const ValueKey('console.icon.info')), findsNWidgets(2));
      expect(find.byKey(const ValueKey('console.icon.diff')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('console.icon.diff')));
      await tester.pump();
      expect(container.read(consolePanelProvider('g')).view, ConsoleView.diff);
      await tester.tap(find.byKey(const ValueKey('console.icon.diff')));
      await tester.pump();
      expect(container.read(consolePanelProvider('g')).view, isNull);
      await tester.tap(find.byKey(const ValueKey('console.icon.info')).first);
      await tester.pump();
      expect(container.read(consolePanelProvider('g')).view, ConsoleView.info);
      await unmount(tester);
    });

    testWidgets('the title menu pins the session; fork and archive are not there yet', (tester) async {
      final s = _session('s');
      await pump(
        tester,
        Consumer(
          builder: (_, ref, _) {
            final info = ref.watch(codeSessionsProvider).first;
            return Align(
              alignment: Alignment.topLeft,
              child: ConsoleTitle(info: info),
            );
          },
        ),
        sessions: [s],
        size: const Size(1000, 900),
      );
      await tester.tap(find.text('Fix the counter'));
      await tester.pump();
      expect(find.text('Coming later'), findsNWidgets(2));
      await tester.tap(find.byKey(const ValueKey('console.title.pin')));
      await tester.pump();
      expect(container.read(codeSessionsProvider).first.pinned, isTrue);
      expect(jsonDecode(prefs['code.sessions']!), [containsPair('pinned', true)]);

      await tester.tap(find.text('Fix the counter'));
      await tester.pump();
      expect(find.text('Unpin'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('Running work opens a child chat in the panel; Back and Open full session', (tester) async {
      final parent = _session('p');
      final child = _session('c', parentId: 'p', title: 'Research the tests');
      await pump(
        tester,
        SizedBox(width: 520, height: 900, child: ConsolePanelView(session: parent)),
        sessions: [parent, child],
        size: const Size(1200, 1000),
      );
      expect(find.text('Running work'), findsOneWidget);
      // A finished fork starts folded under its group; the header opens it.
      expect(find.byKey(const ValueKey('console.running.c')), findsNothing);
      await tester.ensureVisible(find.text('Forks and subagents · 1 done'));
      await tester.tap(find.text('Forks and subagents · 1 done'));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const ValueKey('console.running.c')));
      await tester.tap(find.byKey(const ValueKey('console.running.c')));
      await tester.pump();
      expect(container.read(consolePanelProvider('p')).child, 'c');
      expect(find.byKey(const ValueKey('console.child.back')), findsOneWidget);
      expect(find.text('Research the tests'), findsOneWidget);
      // It says plainly this isn't the main chat; the banner goes back too.
      expect(find.textContaining('A subagent of'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('subagent.banner')));
      await tester.pump();
      expect(find.text('Running work'), findsOneWidget);
      container.read(consolePanelProvider('p').notifier).openChild('c');
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('console.child.back')));
      await tester.pump();
      expect(find.text('Running work'), findsOneWidget);

      container.read(consolePanelProvider('p').notifier).openChild('c');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('console.child.open')));
      await tester.pumpAndSettle();
      expect(find.text('full c'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets("a terminal CLI's context lists no host MCP tools: it never gets them", (tester) async {
      final cli = _session('t', workingDir: '/repo').copyWith(harness: 'terminal:vim');
      final oc = _session('o', workingDir: '/repo').copyWith(harness: 'opencode');
      await pump(tester, const SizedBox(), sessions: [cli, oc]);
      bool mcp(String id) => container.read(codeContextPartsProvider(id)).any((p) => p.kind == ContextKind.mcpTools);
      expect(mcp('t'), isFalse);
      expect(mcp('o'), isTrue);
      await unmount(tester);
    });

    testWidgets('the transcript side keeps its state when the panel opens, closes or changes tier', (tester) async {
      final s = _session('s', workingDir: '/wt/fix', worktree: _worktree);
      final wide = ValueNotifier(true);
      addTearDown(wide.dispose);
      await pump(
        tester,
        ValueListenableBuilder(
          valueListenable: wide,
          builder: (_, isWide, _) => ConsoleLayout(
            session: s,
            tier: isWide ? ConsoleTier.wide : ConsoleTier.medium,
            child: const m.TextField(key: ValueKey('draft')),
          ),
        ),
        sessions: [s],
        size: const Size(1200, 800),
      );
      await tester.enterText(find.byKey(const ValueKey('draft')), 'my draft');
      final panel = container.read(consolePanelProvider('s').notifier);
      panel.close();
      await tester.pump();
      expect(find.text('my draft'), findsOneWidget);
      panel.show(ConsoleView.info);
      await tester.pump();
      expect(find.text('my draft'), findsOneWidget);
      // Below the header's wide tier, a 1200 px window still has room for both side by side.
      wide.value = false;
      await tester.pump();
      expect(find.byKey(const ValueKey('console.split')), findsOneWidget);
      expect(find.text('my draft'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('over the transcript, the panel steps aside for a draft card or a question', (tester) async {
      final s = _session('s');
      await pump(
        tester,
        ConsoleLayout(session: s, tier: ConsoleTier.narrow, child: const Text('transcript')),
        sessions: [s],
        size: const Size(650, 800),
      );
      expect(find.byKey(const ValueKey('console.overlay')), findsOneWidget);
      expect(container.read(consolePanelProvider('s')).open, isTrue);
      final controller = container.read(codeSessionProvider('s').notifier);
      controller.state = controller.state.copyWith(
        asides: [
          ...controller.state.asides,
          const Aside(id: 1, kind: AsideKind.commit),
        ],
      );
      await tester.pump();
      expect(container.read(consolePanelProvider('s')).open, isFalse);
      await unmount(tester);
    });

    testWidgets('beside the transcript, a card or question leaves the panel open', (tester) async {
      final s = _session('s');
      await pump(
        tester,
        ConsoleLayout(session: s, tier: ConsoleTier.medium, child: const Text('transcript')),
        sessions: [s],
        size: const Size(850, 800),
      );
      expect(find.byKey(const ValueKey('console.split')), findsOneWidget);
      final controller = container.read(codeSessionProvider('s').notifier);
      controller.state = controller.state.copyWith(asides: [const Aside(id: 1, kind: AsideKind.commit)]);
      await tester.pump();
      expect(container.read(consolePanelProvider('s')).open, isTrue);
      await unmount(tester);
    });

    testWidgets('Background tasks scrolls to Running work when Session info opens for it', (tester) async {
      final parent = _session('p');
      final child = _session('c', parentId: 'p', title: 'Research the tests');
      await pump(
        tester,
        ConsoleLayout(session: parent, tier: ConsoleTier.wide, child: const Text('transcript')),
        sessions: [parent, child],
        size: const Size(1200, 260),
      );
      final panel = container.read(consolePanelProvider('p').notifier);
      panel.close();
      await tester.pump();
      panel.showRunningWork();
      await tester.pumpAndSettle();
      final top = tester.getTopLeft(find.text('Running work')).dy;
      expect(top, inInclusiveRange(0, 260));
      await unmount(tester);
      // The session list polls statuses while Running work shows it; stop that with the test.
      container.dispose();
    });

    testWidgets('Delete in the title menu goes back to Code even when the screen goes first', (tester) async {
      final s = _session('s', workingDir: '/wt/fix', worktree: _worktree);
      final gate = Completer<void>();
      await pump(
        tester,
        Consumer(
          builder: (_, ref, _) {
            final info = ref.watch(codeSessionsProvider).firstOrNull;
            if (info == null) return const Text('gone');
            return Align(
              alignment: Alignment.topLeft,
              child: ConsoleTitle(info: info),
            );
          },
        ),
        sessions: [s],
        size: const Size(1000, 900),
        extra: [codeGitProvider.overrideWith2((id) => _SlowDiscard(gate, id))],
      );
      await tester.tap(find.text('Fix the counter'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('console.title.delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete').last);
      await tester.pump();
      await tester.pump();
      expect(find.text('gone'), findsOneWidget);
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('code home'), findsOneWidget);
      await unmount(tester);
    });

    for (final (width, kind) in [(1200.0, 'split'), (850.0, 'split'), (650.0, 'overlay')]) {
      testWidgets('at $width wide the panel is a $kind${width < 700 ? ' and the icons fold into ⋯' : ''}', (
        tester,
      ) async {
        final s = _session('s', workingDir: '/wt/fix', worktree: _worktree);
        await pump(
          tester,
          LayoutBuilder(
            builder: (context, box) {
              final tier = ConsoleTier.forWidth(box.maxWidth);
              return Column(
                children: [
                  ConsoleActions(info: s, tier: tier),
                  Expanded(
                    child: ConsoleLayout(session: s, tier: tier, child: const Text('transcript')),
                  ),
                ],
              );
            },
          ),
          sessions: [s],
          size: Size(width, 800),
        );
        expect(find.byKey(ValueKey('console.$kind')), findsOneWidget);
        expect(find.text('transcript'), findsOneWidget);
        final folded = width < 700;
        expect(find.byKey(const ValueKey('console.icon.info')), folded ? findsNothing : findsOneWidget);
        if (folded) {
          await tester.tap(find.byKey(const ValueKey('console.more')));
          await tester.pump();
          expect(find.byKey(const ValueKey('console.more.info')), findsOneWidget);
          expect(find.byKey(const ValueKey('console.more.diff')), findsOneWidget);
          await tester.tap(find.byKey(const ValueKey('console.more.diff')));
          await tester.pump();
          expect(container.read(consolePanelProvider('s')).view, ConsoleView.diff);
        }
        await unmount(tester);
      });
    }
  });
}

Widget _app(Widget? home, {GoRouter? router}) {
  Widget themed(Widget child) => m.Material(
    child: EveryThemeScope(theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light), child: child),
  );
  if (router != null) return m.MaterialApp.router(routerConfig: router, builder: (_, child) => themed(child!));
  return m.MaterialApp(home: themed(home!));
}
