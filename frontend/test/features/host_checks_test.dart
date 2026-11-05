import 'dart:convert';
import 'dart:io';

import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/goal.dart';
import 'package:every_ai/features/code/domain/permissions.dart';
import 'package:every_ai/features/code/domain/phases.dart' show bugCheckTool;
import 'package:every_ai/features/code/domain/spill.dart';
import 'package:every_ai/features/code/drivers/briefing/session_skill.dart';
import 'package:every_ai/features/code/drivers/claude/claude_wire.dart' show answeredBySession;
import 'package:every_ai/features/code/drivers/driver_events.dart';
import 'package:every_ai/features/code/drivers/driver_policy.dart';
import 'package:every_ai/features/code/drivers/opencode/opencode_session.dart' show openCodeSessionRules;
import 'package:every_ai/features/code/git/git_models.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/everyai/script_io.dart' show findDeno;
import 'package:every_ai/features/code/host/host.dart';
import 'package:every_ai/features/code/host/host_checks.dart';
import 'package:every_ai/features/code/host/host_output.dart';
import 'package:every_ai/features/code/host/host_script.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  late String dir;
  late String stateDir;

  setUp(() {
    tmp = Directory(Directory.systemTemp.createTempSync('host-checks').resolveSymbolicLinksSync());
    dir = '${tmp.path}/repo';
    stateDir = '${tmp.path}/state';
    Directory(dir).createSync();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  var n = 0;
  HostCall call(String name, [Map<String, Object?> args = const {}]) =>
      HostCall(id: 'h${++n}', sessionId: 's1', name: name, args: args, ended: Future<HostEnd>.value(HostEnd.cancelled));

  /// A context whose commands go to [runs] (answered by [answer]) and whose gate is [refusal].
  HostCheckContext context({
    List<String>? runs,
    ({int exit, String out}) Function(String command)? answer,
    String? Function(String command)? refusal,
    SessionWorktree? worktree,
    Goal? goal,
  }) => HostCheckContext(
    sessionId: 's1',
    workingDir: dir,
    stateDir: stateDir,
    worktree: worktree,
    goal: goal,
    refusal: refusal ?? (_) => null,
    run: (command, _) async {
      runs?.add(command);
      return answer?.call(command) ?? (exit: 0, out: 'ok');
    },
  );

  void write(String path, [String text = '']) => File('$dir/$path')
    ..createSync(recursive: true)
    ..writeAsStringSync(text);

  group('output spill', () {
    test('a result over the limit goes to .everyai/spill with a preview naming it', () {
      final lines = [for (var i = 0; i < 3000; i++) 'line $i'];
      final r = hostFit(dir, 'host-1-check', (text: lines.join('\n'), isError: true));
      expect(r.isError, isTrue);
      expect(r.text, allOf(contains('line 0'), contains('line 2999'), isNot(contains('line 1500'))));
      expect(r.text, contains('.everyai/spill/host-1-check.txt'));
      expect(File('$dir/$spillDir/host-1-check.txt').readAsStringSync(), lines.join('\n'));
    });

    test('a short result is unchanged', () {
      const r = (text: 'all good', isError: false);
      expect(hostFit(dir, 'x', r), r);
      expect(Directory('$dir/$spillDir').existsSync(), isFalse);
    });
  });

  group('diff_stats', () {
    Future<String> git(List<String> args) async {
      final r = await Process.run('git', ['-C', dir, ...args]);
      if (r.exitCode != 0) fail('git ${args.join(' ')}: ${r.stderr}');
      return '${r.stdout}'.trim();
    }

    test('per-file lines and the total since the base commit, untracked files too', () async {
      await git(['init', '-q']);
      write('a.txt', 'one\ntwo\n');
      write('b.txt', 'keep\n');
      await git(['add', '.']);
      await git(['-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'base']);
      final base = await git(['rev-parse', 'HEAD']);
      write('a.txt', 'one\n2\nthree\n');
      write('new.txt', 'n\n');
      final w = SessionWorktree(repoRoot: dir, path: dir, branch: 'main', baseBranch: 'main', baseCommit: base);
      final r = await hostCheckTool(call(diffStatsTool), context(worktree: w));
      expect(r.isError, isFalse);
      expect(r.text.split('\n'), [
        '2 files changed, +3 -1 since the session started (base ${base.substring(0, 7)}):',
        'M a.txt +2 -1',
        'A new.txt +1 -0',
      ]);
    });

    test("without a worktree: what isn't committed in the folder, new files too", () async {
      final runs = <String>[];
      final r = await hostCheckTool(
        call(diffStatsTool),
        context(
          runs: runs,
          answer: (_) => (exit: 0, out: ' a.txt | 2 +-\n 1 file changed, 1 insertion(+), 1 deletion(-)\nnew.txt\n'),
        ),
      );
      expect(runs.single, startsWith('git diff --stat HEAD'));
      expect(r.isError, isFalse);
      expect(r.text, contains('not committed yet'));
      expect(r.text, contains(' a.txt | 2 +-'));
      expect(r.text, contains('New files: new.txt'));
    });

    test('without a worktree, outside a repository or when the gate refuses, it says so', () async {
      final bare = await hostCheckTool(call(diffStatsTool), context(answer: (_) => (exit: 128, out: 'fatal')));
      expect(bare.text, contains('not a git repository'));
      final refused = await hostCheckTool(call(diffStatsTool), context(refusal: (_) => 'Not approved.'));
      expect(refused.isError, isTrue);
      expect(refused.text, startsWith('Not approved.'));
    });
  });

  group('goal_check', () {
    test('no goal', () async {
      expect((await hostCheckTool(call(goalCheckTool), context())).text, contains('No goal is set'));
    });

    test('the goal and the rules, for the lead to judge', () async {
      final r = await hostCheckTool(call(goalCheckTool), context(goal: const Goal(objective: 'Dark mode works')));
      expect(r.isError, isFalse);
      expect(r.text, startsWith('Goal: Dark mode works'));
      expect(r.text, contains(goalSelfCheck('Dark mode works')));
      expect(r.text, contains('sub-agent'));
    });
  });

  group('check', () {
    bool exists(String p) => FileSystemEntity.typeSync('$dir/$p') != FileSystemEntityType.notFound;
    String? read(String p) => File('$dir/$p').existsSync() ? File('$dir/$p').readAsStringSync() : null;

    test('detects each project kind and maps sources to their tests', () {
      write('app/pubspec.yaml', 'dependencies:\n  flutter:\n    sdk: flutter\n');
      write('app/lib/ui/home.dart');
      write('app/test/ui/home_test.dart');
      write('app/lib/none.dart');
      write('pkg/pubspec.yaml', 'name: pkg\n');
      write('pkg/test/x_test.dart');
      write('web/package.json', '{"devDependencies": {"vitest": "1"}}');
      write('web/src/a.ts');
      write('api/package.json', '{"devDependencies": {"jest": "29"}}');
      write('api/src/b.js');
      write('svc/go.mod', 'module x');
      write('svc/internal/q/q.go');
      write('core/Cargo.toml', '[package]');
      write('core/src/lib.rs');
      write('py/pyproject.toml', '[project]');
      write('py/pkg/util.py');
      write('py/tests/test_util.py');
      write('README.md');
      final found = detectChecks(
        [
          'app/lib/ui/home.dart',
          'app/lib/none.dart',
          'pkg/test/x_test.dart',
          'web/src/a.ts',
          'api/src/b.js',
          'svc/internal/q/q.go',
          'core/src/lib.rs',
          'py/pkg/util.py',
          'README.md',
        ],
        exists: exists,
        read: read,
      );
      expect(
        [for (final r in found.runs) checkCommand(r)],
        [
          'cd app && flutter test test/ui/home_test.dart',
          'cd pkg && dart test test/x_test.dart',
          'cd web && npx vitest related --run src/a.ts',
          'cd api && npx jest --findRelatedTests src/b.js',
          'cd svc && go test ./internal/q',
          'cd core && cargo test',
          'cd py && python -m pytest tests/test_util.py',
        ],
      );
      expect(found.unmatched, [
        'README.md (no project file such as pubspec.yaml, package.json or go.mod in its folder or above)',
        'app/lib/none.dart (looked for app/test/none_test.dart)',
      ]);
    });

    test('runs the detected tests through the gate; a failure is an error result', () async {
      write('pubspec.yaml', 'name: p\n');
      write('lib/a.dart');
      write('test/a_test.dart');
      final runs = <String>[];
      var r = await hostCheckTool(
        call(checkTool, {
          'files': ['lib/a.dart'],
        }),
        context(runs: runs, answer: (_) => (exit: 1, out: 'Some tests failed: a')),
      );
      expect(runs, ['dart test test/a_test.dart']);
      expect(r.isError, isTrue);
      expect(r.text, allOf(contains('Some tests failed.'), contains('[exit 1]')));
      r = await hostCheckTool(
        call(checkTool, {
          'files': ['lib/a.dart'],
        }),
        context(runs: runs, refusal: (_) => 'Not run: no.'),
      );
      expect(r.isError, true);
      expect(r.text, startsWith('Not run: no.'));
      expect(runs, hasLength(1));
    });

    test('absolute paths in the session folder find their tests', () async {
      write('pubspec.yaml', 'name: p\n');
      write('lib/foo.dart');
      write('test/foo_test.dart');
      final runs = <String>[];
      await hostCheckTool(
        call(checkTool, {
          'files': ['$dir/lib/foo.dart'],
        }),
        context(runs: runs),
      );
      expect(runs, ['dart test test/foo_test.dart']);
    });

    test('nothing to test is said plainly', () async {
      write('notes.txt');
      final r = await hostCheckTool(
        call(checkTool, {
          'files': ['notes.txt'],
        }),
        context(),
      );
      expect(r.isError, true);
      expect(r.text, contains('No test found for: notes.txt'));
      expect((await hostCheckTool(call(checkTool), context())).text, contains('name the files'));
    });
  });

  group('bug_check', () {
    test('reproduced with expect: a hit records it, a miss does not', () async {
      var out = 'all fine';
      final ctx = context(answer: (_) => (exit: 0, out: out));
      var r = await hostCheckTool(
        call(bugCheckTool, {'action': 'reproduced', 'command': 'run', 'expect': 'BOOM'}),
        ctx,
      );
      expect(r.isError, true);
      expect(r.text, startsWith('Not reproduced'));
      expect(File('$stateDir/bug_check.json').existsSync(), isFalse);
      out = 'BOOM at line 3';
      r = await hostCheckTool(call(bugCheckTool, {'action': 'reproduced', 'command': 'run', 'expect': 'BOOM'}), ctx);
      expect(r.isError, false);
      expect(r.text, startsWith('Reproduced'));
      final state = jsonDecode(File('$stateDir/bug_check.json').readAsStringSync()) as Map;
      expect((state['command'], state['expect']), ('run', 'BOOM'));
    });

    test('without expect a non-zero exit reproduces; verify passes on exit 0', () async {
      var exit = 2;
      write('test/bug_test.dart', 'expect(1, 2)');
      final ctx = context(answer: (_) => (exit: exit, out: 'out'));
      final cmd = 'dart test test/bug_test.dart';
      var r = await hostCheckTool(call(bugCheckTool, {'action': 'reproduced', 'command': cmd}), ctx);
      expect(r.text, startsWith('Reproduced'));
      r = await hostCheckTool(call(bugCheckTool, {'action': 'verify'}), ctx);
      expect(r.isError, true);
      expect(r.text, startsWith('Not verified: the command still fails'));
      exit = 0;
      r = await hostCheckTool(call(bugCheckTool, {'action': 'verify'}), ctx);
      expect(r.isError, false);
      expect(r.text, startsWith('Verified'));
      r = await hostCheckTool(call(bugCheckTool, {'action': 'status'}), ctx);
      expect(r.text, allOf(contains('Repro command: $cmd'), contains('Verified: the fix passed.')));
    });

    test('verify refuses when a file the repro names changed', () async {
      write('test/bug_test.dart', 'expect(1, 2)');
      final runs = <String>[];
      var exit = 1;
      final ctx = context(runs: runs, answer: (_) => (exit: exit, out: ''));
      await hostCheckTool(call(bugCheckTool, {'action': 'reproduced', 'command': 'dart test test/bug_test.dart'}), ctx);
      write('test/bug_test.dart', 'expect(1, 1)');
      exit = 0;
      final r = await hostCheckTool(call(bugCheckTool, {'action': 'verify'}), ctx);
      expect(r.isError, true);
      expect(r.text, contains('test/bug_test.dart'));
      expect(runs, hasLength(1));
    });

    test('verify refuses an edited repro named by an absolute path, a scratch script or a runner alone', () async {
      write('test/abs_test.dart', 'expect(1, 2)');
      write('.everyai/scratch/repro.sh', 'exit 1');
      var exit = 1;
      final ctx = context(answer: (_) => (exit: exit, out: ''));
      await hostCheckTool(
        call(bugCheckTool, {'action': 'reproduced', 'command': 'dart test $dir/test/abs_test.dart'}),
        ctx,
      );
      write('test/abs_test.dart', 'expect(1, 1)');
      exit = 0;
      var r = await hostCheckTool(call(bugCheckTool, {'action': 'verify'}), ctx);
      expect(r.isError, isTrue);
      expect(r.text, contains('test/abs_test.dart'));
      // `npm test` names no file; the scratch script still counts.
      exit = 1;
      await hostCheckTool(call(bugCheckTool, {'action': 'reproduced', 'command': 'npm test'}), ctx);
      write('.everyai/scratch/repro.sh', 'exit 0');
      exit = 0;
      r = await hostCheckTool(call(bugCheckTool, {'action': 'verify'}), ctx);
      expect(r.isError, isTrue);
      expect(r.text, contains('.everyai/scratch/repro.sh'));
    });

    test('verify refuses an edited test that was new or changed at reproduced', () async {
      Process.runSync('git', ['init', '-q'], workingDirectory: dir);
      write('tests/test_bug.py', 'assert 1 == 2');
      var exit = 1;
      final ctx = context(answer: (_) => (exit: exit, out: ''));
      await hostCheckTool(call(bugCheckTool, {'action': 'reproduced', 'command': 'pytest -k bug'}), ctx);
      write('tests/test_bug.py', 'assert 1 == 1');
      exit = 0;
      final r = await hostCheckTool(call(bugCheckTool, {'action': 'verify'}), ctx);
      expect(r.isError, isTrue);
      expect(r.text, contains('tests/test_bug.py'));
    });

    test('verify before reproduced, and a refused command', () async {
      var r = await hostCheckTool(call(bugCheckTool, {'action': 'verify'}), context());
      expect(r.text, contains('reproduced first'));
      r = await hostCheckTool(
        call(bugCheckTool, {'action': 'reproduced', 'command': 'rm -rf ~'}),
        context(refusal: (c) => 'Not run: $c'),
      );
      expect((r.isError, r.text), (true, 'Not run: rm -rf ~'));
    });
  });

  group('the gate for commands the app runs', () {
    ActionCall row(String id, Map<String, Object?> args, {String name = 'mcp__everyai__check'}) =>
        actionEvent(id: id, toolName: name, kind: 'MCPToolAction', args: args);

    const args = {
      'files': ['lib/a.dart'],
    };
    String? gate(
      String command, {
      PermissionPolicy policy = const PermissionPolicy(hostTools: true),
      AgentMode mode = AgentMode.ask,
      List<ActionCall>? approved,
    }) => hostRunRefusal(
      policy: policy,
      mode: mode,
      tool: checkTool,
      args: args,
      command: command,
      approved: approved ?? [],
    );

    test('the floor and deny rules always refuse, Full auto included', () {
      expect(gate('rm -rf ~', mode: AgentMode.fullAuto), startsWith('Not run:'));
      expect(
        gate(
          'dart test',
          mode: AgentMode.fullAuto,
          policy: const PermissionPolicy(rules: PermissionRules(deny: ['dart test *']), hostTools: true),
        ),
        contains('dart test *'),
      );
      // An approval doesn't lift the floor.
      expect(gate('rm -rf ~', approved: [row('a1', args)]), startsWith('Not run:'));
    });

    test('Full auto and allow rules run', () {
      expect(gate('dart test', mode: AgentMode.fullAuto), isNull);
      expect(
        gate(
          'dart test',
          policy: const PermissionPolicy(rules: PermissionRules(allow: ['dart test *'])),
        ),
        isNull,
      );
    });

    test('an ask runs only for an approved call with the same arguments, once', () {
      // Nothing approved: a process outside the agent's tool flow (curl with the token) is refused,
      // and so is the agent's own open row that nobody approved (Codex pre-approved MCP tools).
      expect(gate('dart test'), contains('approval'));
      // Approved, under each CLI's naming: Claude Code, Codex, OpenCode.
      for (final name in ['mcp__everyai__check', 'everyai__check', 'everyai_check']) {
        final approved = [row('a1', args, name: name)];
        expect(gate('dart test', approved: approved), isNull, reason: name);
        // Used up: the same call again needs another approval.
        expect(gate('dart test', approved: approved), contains('approval'), reason: name);
      }
      // Other arguments, or another tool, don't count.
      final other = [
        row('a1', {
          'files': ['lib/b.dart'],
        }),
        row('a2', args, name: 'mcp__everyai__bug_check'),
      ];
      expect(gate('dart test', approved: other), contains('approval'));
      expect(other, hasLength(2));
    });
  });

  group('policy', () {
    ActionCall mcp(String tool, [Map<String, Object?> args = const {}]) =>
        actionEvent(id: 'a', toolName: 'mcp__everyai__$tool', kind: 'MCPToolAction', args: args);
    const policy = PermissionPolicy(hostTools: true);

    test('the new tools are ours; the read-only ones run, the ones that run commands ask', () {
      for (final t in ['check', 'diff_stats', 'goal_check', 'run_script', 'bug_check', 'report_issue']) {
        expect(hostToolOf(mcp(t)), t);
        // OpenCode's naming.
        expect(hostToolOf(actionEvent(id: 'o', toolName: 'everyai_$t', kind: 'MCPToolAction', args: const {})), t);
      }
      for (final t in ['diff_stats', 'goal_check', 'run_script', 'report_issue']) {
        expect(policy.decide(mcp(t), AgentMode.ask).verdict, Verdict.allow, reason: t);
      }
      expect(policy.decide(mcp('check'), AgentMode.ask).verdict, Verdict.ask);
      expect(policy.decide(mcp('bug_check', {'command': 'dart test'}), AgentMode.ask).verdict, Verdict.ask);
    });

    test("bug_check's command meets the floor", () {
      final d = policy.decide(mcp('bug_check', {'action': 'reproduced', 'command': 'rm -rf ~'}), AgentMode.fullAuto);
      expect((d.verdict, d.source), (Verdict.deny, DecisionSource.floor));
    });

    test('OpenCode asks the session before the tools that run commands (the last match wins)', () {
      Object? effect(String tool) => openCodeSessionRules.lastWhere(
        (r) => r['action'] == '*' || r['action'] == 'everyai_*' || r['action'] == tool,
      )['effect'];
      expect(effect('everyai_check'), 'ask');
      expect(effect('everyai_bug_check'), 'ask');
      expect(effect('everyai_diff_stats'), 'allow');
    });

    test('Claude Code asks the session before the tools that run commands', () {
      expect(answeredBySession('mcp__everyai__diff_stats', briefed: true), isTrue);
      expect(answeredBySession('mcp__everyai__check', briefed: true), isFalse);
      expect(answeredBySession('mcp__everyai__bug_check', briefed: true), isFalse);
    });
  });

  test('the briefing lists the checks', () {
    final text = sessionBriefing(
      SessionSkillInput(
        worktree: dir,
        projectRoot: dir,
        lead: (name: 'Claude Code', model: 'sonnet'),
        hostTools: checkToolInfos,
      ),
    );
    for (final t in ['bug_check', 'check', 'diff_stats', 'goal_check', 'run_script']) {
      expect(text, contains('`$t`'));
    }
  });

  group('run_script on the host', () {
    final deno = findDeno();
    test('reads project files; model and web functions are refused before any request', () async {
      write('lib/a.dart', 'void a() {}\n');
      final r = await hostRunScript(dir, stateDir, {
        'code': r'''
console.log((await glob("lib/*.dart")).join(","), (await readFile("lib/a.dart")).trim());
for (const f of [() => decide("x", [{id: "a", kind: "bool", prompt: "?"}]), () => llmQuery("hi"),
  () => webFetch("https://example.com"), () => webSearch("q"), () => rank(["a"], "?")]) {
  try { await f(); console.log("ALLOWED"); } catch (e) { console.log("refused:", e.message.split(":")[0]); }
}
''',
      });
      expect(r.isError, isFalse, reason: r.text);
      expect(r.text, contains('lib/a.dart void a() {}'));
      expect(r.text, isNot(contains('ALLOWED')));
      expect(RegExp('refused: (decide|llmQuery|webFetch|webSearch) is off here').allMatches(r.text), hasLength(5));
    }, skip: deno == null ? 'no deno' : false);
  });
}
