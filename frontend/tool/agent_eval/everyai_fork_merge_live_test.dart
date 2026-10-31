// Live check of a fork in its own worktree: the parent reads a file, a fork
// edits it in its copy (through the parent's paths), and the change merges
// back into the parent's folder. Not part of `flutter test`:
//
//   GATEWAY_KEY=sk-eai-… [API_BASE_URL=… EVAL_MODEL=…] flutter test tool/agent_eval/everyai_fork_merge_live_test.dart
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:io';

import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/subagents.dart';
import 'package:every_ai/features/code/git/git_service.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/everyai/everyai_harness_io.dart';
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:every_ai/features/code/settings/settings.dart';
import 'package:flutter_test/flutter_test.dart';

final _env = Platform.environment;

Future<void> _finish(HarnessSession s) async {
  final done = Completer<void>();
  final sub = s.events.listen((e) {
    if (e is ActionCall) print('  ${e.toolName} ${e.action['path'] ?? e.action['command'] ?? ''}');
    if (e is StateChange && e.executionStatus == ExecutionStatus.waitingForConfirmation) unawaited(s.respond(accept: true));
    if (e is StateChange && e.executionStatus == ExecutionStatus.finished && !done.isCompleted) done.complete();
  });
  await done.future.timeout(const Duration(minutes: 4));
  await sub.cancel();
}

void main() {
  test('a fork edits its copy and the change merges back', () async {
    final tmp = await Directory.systemTemp.createTemp('fork-merge');
    final repo = '${tmp.path}/app';
    Directory(repo).createSync();
    Future<void> git(List<String> a) => Process.run('git', ['-C', repo, ...a]);
    await git(['init', '-q', '-b', 'main']);
    File('$repo/math.js').writeAsStringSync('export function add(a, b) {\n  return a + b;\n}\n');
    await git(['add', '-A']);
    await git(['-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '-m', 'init']);
    // Uncommitted work the fork must see.
    File('$repo/notes.md').writeAsStringSync('# Notes\n');

    final api = _env['API_BASE_URL'] ?? 'http://localhost:8080';
    final harness = EveryAIHarness(dataDir: () async => tmp.path, gatewayKey: () async => _env['GATEWAY_KEY']!);
    final prompt = await agentPromptFor(repo);
    SessionSpec spec(String dir, String msg, {Map<String, String> map = const {}}) => SessionSpec(
      workingDir: dir,
      model: _env['EVAL_MODEL'] ?? 'anthropic/claude-haiku-5.5',
      mode: AgentMode.fullAuto,
      llmBaseUrl: '$api/v1',
      llmApiKey: _env['GATEWAY_KEY']!,
      sessionTag: 'fork-merge-live',
      persona: prompt.persona,
      promptSuffix: prompt.suffix,
      effort: 'low',
      initialMessage: msg,
      pathMap: map,
    );
    final parent = await harness.start(spec(repo, 'Read $repo/math.js and $repo/notes.md, then say "ready". Nothing else.'));
    await _finish(parent);
    final copy = (await GitService.forkCopy(repo, worktreesDir: '${tmp.path}/forks', slug: 'mul'))!;
    final fork = await harness.fork(
      parent.id,
      spec(
        copy.path,
        forkBrief(
          const SubagentTask(
            description: 'Add multiply',
            prompt: 'Add an exported multiply(a, b) to math.js below add, and a line "- multiply added" to notes.md.',
          ),
          copyAt: copy.path,
          parentDir: repo,
        ),
        map: {repo: copy.path, copy.repoRoot: copy.root},
      ),
    );
    await _finish(fork);
    // The parent's folder is untouched until the merge.
    expect(File('$repo/math.js').readAsStringSync(), isNot(contains('multiply')));
    final m = await GitService.mergeFork(copy, slug: 'mul');
    print('merged ${m.merged} conflicts ${m.conflicts}');
    expect(File('$repo/math.js').readAsStringSync(), contains('multiply'));
    expect(File('$repo/notes.md').readAsStringSync(), contains('multiply added'));
    expect(m.conflicts, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 10)));
}
