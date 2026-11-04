import 'dart:convert';

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/core/ui/adaptive.dart' show AdaptiveMenuButton;
import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/history/ui/sidebar.dart';
import 'package:every_ai/features/remote/host_mirror.dart' show remoteFollowedProvider;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

// The sidebar's Code lists: Pinned, Recents with status marks, search, and the pin menu.

CodeSessionInfo _s(
  String id, {
  String project = 'p1',
  String title = '',
  bool pinned = false,
  int day = 1,
  String branch = '',
  String? parent,
  int? pr,
}) => CodeSessionInfo(
  id: id,
  projectId: project,
  title: title.isEmpty ? 'Session $id' : title,
  conversationId: 'c-$id',
  model: 'a/m',
  mode: AgentMode.ask,
  // Demo sessions: the status poller leaves them alone, so the test sets the statuses itself.
  workingDir: 'demo://$project',
  createdAt: DateTime(2026, 11, day),
  branch: branch,
  pinned: pinned,
  parentId: parent,
  prNumber: pr,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('filterSessions and groupCodeSessions', () {
    final all = [
      _s('a', title: 'Fix login', branch: 'fix/login', day: 1),
      _s('b', title: 'Dark mode', pinned: true, day: 2),
      _s('c', title: 'Docs', project: 'p2', pinned: true, day: 3),
      _s('d', title: 'Child', parent: 'a'),
    ];

    test('pinned first by newest, subagents in neither list', () {
      final g = groupCodeSessions(all);
      expect([for (final s in g.pinned) s.id], ['c', 'b']);
      expect([for (final s in g.recent) s.id], ['a']);
    });

    test('nothing pinned leaves the pinned group empty', () {
      expect(groupCodeSessions([_s('a'), _s('b')]).pinned, isEmpty);
    });

    test('matches the title, branch or project name; blank keeps all', () {
      List<String> ids(String q) => [
        for (final s in filterSessions(all, q, projectNames: {'p1': 'Alpha', 'p2': 'Beta'})) s.id,
      ];
      expect(ids('  '), ['a', 'b', 'c', 'd']);
      expect(ids('DARK'), ['b']);
      expect(ids('fix/'), ['a']);
      expect(ids('beta'), ['c']);
      expect(ids('zzz'), isEmpty);
    });
  });

  test('a session keeps its pull request and pin through JSON; the PR number comes from the URL', () {
    final back = CodeSessionInfo.fromJson(_s('a', pinned: true, pr: 42).toJson());
    expect((back.pinned, back.prNumber), (true, 42));
    expect(CodeSessionInfo.fromJson(_s('a').toJson()).prNumber, isNull);
    expect(_s('a', pr: 7).copyWith(clearPr: true).prNumber, isNull);
    expect(prNumberOf('https://github.com/o/r/pull/123\n'), 123);
    expect(prNumberOf('no url'), isNull);
  });

  group('the Code session list', () {
    // The session list is a desktop view; the override must be gone before the test ends.
    ProviderContainer? opened;
    void desktopTest(String name, Future<void> Function(WidgetTester) body) => testWidgets(name, (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        await body(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
        // The status poller's timer goes with the container.
        await tester.pumpWidget(const SizedBox());
        opened?.dispose();
        opened = null;
      }
    });

    late AppDatabase db;
    late Preferences prefs;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      prefs = await Preferences.load(db);
    });
    tearDown(() => db.close());

    Future<ProviderContainer> show(
      WidgetTester tester,
      List<CodeSessionInfo> sessions, {
      String query = '',
      Map<String, SessionStatus> statuses = const {},
      Set<String> followed = const {},
    }) async {
      prefs['code.projects'] =
          '[{"id":"p1","name":"Alpha","path":"/tmp/p1"},{"id":"p2","name":"Beta","path":"/tmp/p2"}]';
      prefs['code.sessions'] = jsonEncode([for (final s in sessions) s.toJson()]);
      final container = ProviderContainer(overrides: [preferencesProvider.overrideWithValue(prefs)]);
      opened = container;
      container.read(remoteFollowedProvider.notifier).set(followed);
      container.listen(codeStatusesProvider, (_, _) {});
      // ignore: invalid_use_of_protected_member
      container.read(codeStatusesProvider.notifier).state = statuses;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: m.MaterialApp(
            home: EveryThemeScope(
              theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light),
              child: m.Scaffold(
                body: SizedBox(
                  width: 300,
                  height: 700,
                  child: CodeSessionList(location: '/code', query: query, onNavigate: (_) {}),
                ),
              ),
            ),
          ),
        ),
      );
      return container;
    }

    desktopTest('Pinned shows only with a pinned session, above Recents', (tester) async {
      await show(tester, [_s('a'), _s('b', pinned: true)]);
      expect(find.text('Pinned'), findsOneWidget);
      expect(find.text('Recents'), findsOneWidget);
      expect(tester.getTopLeft(find.text('Session b')).dy, lessThan(tester.getTopLeft(find.text('Session a')).dy));
    });

    desktopTest('without pins there is no Pinned or Recents label', (tester) async {
      await show(tester, [_s('a')]);
      expect(find.text('Pinned'), findsNothing);
      expect(find.text('Recents'), findsNothing);
      expect(find.text('Session a'), findsOneWidget);
    });

    desktopTest('the row menu pins and unpins', (tester) async {
      final container = await show(tester, [_s('a')]);
      await tester.tap(find.byType(AdaptiveMenuButton));
      await tester.pump();
      await tester.tap(find.text('Pin'));
      await tester.pump();
      expect(container.read(codeSessionsProvider).single.pinned, isTrue);
      expect(find.text('Pinned'), findsOneWidget);

      await tester.tap(find.byType(AdaptiveMenuButton));
      await tester.pump();
      await tester.tap(find.text('Unpin'));
      await tester.pump();
      expect(container.read(codeSessionsProvider).single.pinned, isFalse);
      expect(find.text('Pinned'), findsNothing);
    });

    desktopTest('status marks differ per state; idle and done show none', (tester) async {
      await show(
        tester,
        [_s('r'), _s('n'), _s('f'), _s('i'), _s('d')],
        statuses: {
          'r': SessionStatus.running,
          'n': SessionStatus.needsInput,
          'f': SessionStatus.failed,
          'd': SessionStatus.done,
        },
      );
      expect(find.byKey(const ValueKey('status-running')), findsOneWidget);
      expect(find.byKey(const ValueKey('status-needs-input')), findsOneWidget);
      expect(find.byKey(const ValueKey('status-failed')), findsOneWidget);
    });

    desktopTest('a pull request number and a following device show on the row', (tester) async {
      await show(tester, [_s('a', pr: 42), _s('b')], followed: {'b'});
      expect(find.text('#42'), findsOneWidget);
      expect(find.byKey(const ValueKey('session-followed')), findsOneWidget);
    });

    desktopTest('the query filters the list', (tester) async {
      await show(tester, [_s('a', title: 'Fix login'), _s('b', title: 'Dark mode', pinned: true)], query: 'login');
      expect(find.text('Fix login'), findsOneWidget);
      expect(find.text('Dark mode'), findsNothing);
      expect(find.text('Pinned'), findsNothing);
    });

    desktopTest('a query that matches nothing says so', (tester) async {
      await show(tester, [_s('a')], query: 'zzz');
      expect(find.text('No matching sessions.'), findsOneWidget);
    });
  });
}
