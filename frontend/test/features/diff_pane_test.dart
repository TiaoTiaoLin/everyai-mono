import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:every_ai/core/db/app_database.dart';
import 'package:every_ai/core/platform/platform_kind.dart';
import 'package:every_ai/core/preferences.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/core/theme/every_theme.dart';
import 'package:every_ai/features/code/code_providers.dart';
import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/git/git_service.dart';
import 'package:every_ai/features/code/ui/console/console_layout.dart';
import 'package:every_ai/features/code/ui/console/console_state.dart';
import 'package:every_ai/features/code/ui/panes/diff_pane.dart';
import 'package:every_ai/features/usage/usage_totals.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

Future<void> _git(String dir, List<String> args) async {
  final r = await Process.run('git', ['-C', dir, ...args]);
  if (r.exitCode != 0) fail('git ${args.join(' ')}: ${r.stderr}');
}

void main() {
  for (final inPanel in [false, true]) {
    testWidgets(
      "the Diff ${inPanel ? "view in the console's right panel" : 'pane'} lists the session's changes and reverts a hunk",
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        late Directory tmp;
        late CodeSessionInfo info;
        late Preferences prefs;
        // Git runs as real processes, outside the test's fake clock.
        await tester.runAsync(() async {
          prefs = await Preferences.load(db);
          tmp = await Directory.systemTemp.createTemp('everyai-pane');
          final repo = '${tmp.path}/app';
          await Directory(repo).create();
          await _git(repo, ['init', '-q', '-b', 'main']);
          await _git(repo, ['config', 'user.name', 'Dev']);
          await _git(repo, ['config', 'user.email', 'dev@example.com']);
          File('$repo/a.txt').writeAsStringSync('${List.generate(12, (i) => 'line $i').join('\n')}\n');
          await _git(repo, ['add', '-A']);
          await _git(repo, ['commit', '-q', '-m', 'Initial commit']);
          final w = await GitService.createWorktree(
            repoRoot: repo,
            slug: 'tweak-lines-abc123',
            worktreesDir: '${tmp.path}/worktrees',
            hooksDir: '${tmp.path}/hooks',
          );
          File('${w.path}/a.txt')
              .writeAsStringSync('${List.generate(12, (i) => i == 0 || i == 11 ? 'LINE $i' : 'line $i').join('\n')}\n');
          File('${w.path}/b.txt').writeAsStringSync('new\n');
          info = CodeSessionInfo(
            id: 's1',
            projectId: 'p1',
            title: 'Tweak lines',
            conversationId: 'c1',
            model: 'anthropic/claude-haiku-5.5',
            mode: AgentMode.ask,
            workingDir: w.path,
            createdAt: DateTime(2026),
            branch: w.branch,
            worktree: w,
          );
          prefs['code.sessions'] = jsonEncode([info.toJson()]);
        });
        addTearDown(() => tmp.delete(recursive: true));

        final container = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(db),
            preferencesProvider.overrideWithValue(prefs),
            codeUsageProvider.overrideWithBuild((ref, n) async => UsageTotals.zero),
          ],
        );
        addTearDown(container.dispose);
        if (inPanel) container.read(consolePanelProvider('s1').notifier).show(ConsoleView.diff);
        await tester.runAsync(() => container.read(codeGitProvider('s1').future));

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: m.MaterialApp(
              home: m.Material(
                child: EveryThemeScope(
                  theme: EveryTheme.resolve(DesignLanguage.material, Brightness.light),
                  child: inPanel ? ConsolePanelView(session: info) : DiffPane(session: info, onClose: () {}),
                ),
              ),
            ),
          ),
        );

        expect(find.text('a.txt'), findsOneWidget);
        expect(find.text('b.txt'), findsOneWidget);
        expect(find.text('everyai/tweak-lines-abc123 → main'), findsOneWidget);
        expect(find.text('Revert'), findsNWidgets(3));

        final a = container.read(codeGitProvider('s1')).value!.files.firstWhere((f) => f.path == 'a.txt');
        await tester.runAsync(() => container.read(codeGitProvider('s1').notifier).revertHunk(a, 0));
        await tester.pump();
        expect(File('${info.workingDir}/a.txt').readAsStringSync(), startsWith('line 0\n'));
        expect(File('${info.workingDir}/a.txt').readAsStringSync(), endsWith('LINE 11\n'));
        expect(find.text('Revert'), findsNWidgets(2));
      },
    );
  }
}
