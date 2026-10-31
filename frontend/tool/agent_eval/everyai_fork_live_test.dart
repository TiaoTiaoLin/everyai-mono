// Live check that a fork shares its parent's prompt cache: the parent reads
// a file, then a fork answers a question about it; the fork's first call
// should read most of its prompt from the cache. Not part of `flutter test`:
//
//   GATEWAY_KEY=sk-eai-… EVAL_DIR=/path/to/repo [API_BASE_URL=… EVAL_MODEL=…] \
//   flutter test tool/agent_eval/everyai_fork_live_test.dart
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:io';

import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/subagents.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/everyai/everyai_harness_io.dart';
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:every_ai/features/code/settings/settings.dart';
import 'package:flutter_test/flutter_test.dart';

final _env = Platform.environment;

Future<void> _finish(HarnessSession s) async {
  final done = Completer<void>();
  final sub = s.events.listen((e) {
    // The app's policy approves in Full auto; here everything is approved.
    if (e is StateChange && e.executionStatus == ExecutionStatus.waitingForConfirmation) {
      unawaited(s.respond(accept: true));
    }
    if (e is StateChange && e.executionStatus == ExecutionStatus.finished && !done.isCompleted) done.complete();
  });
  await done.future.timeout(const Duration(minutes: 2));
  await sub.cancel();
}

void main() {
  test('a fork reads its prefix from the cache', () async {
    final dir = _env['EVAL_DIR']!;
    final api = _env['API_BASE_URL'] ?? 'http://localhost:8080';
    final data = await Directory.systemTemp.createTemp('everyai-fork');
    final harness = EveryAIHarness(dataDir: () async => data.path, gatewayKey: () async => _env['GATEWAY_KEY']!);
    final prompt = await agentPromptFor(dir);
    SessionSpec spec(String message, String tag) => SessionSpec(
      workingDir: dir,
      model: _env['EVAL_MODEL'] ?? 'anthropic/claude-haiku-5.5',
      mode: AgentMode.fullAuto,
      llmBaseUrl: '$api/v1',
      llmApiKey: _env['GATEWAY_KEY']!,
      sessionTag: tag,
      persona: prompt.persona,
      promptSuffix: prompt.suffix,
      effort: 'low',
      initialMessage: message,
      clientTools: [forkingTaskSpec()],
      holdClientTools: true,
    );
    final tag = 'fork-live-${DateTime.now().millisecondsSinceEpoch}';
    final parent = await harness.start(spec('List the files here with one bash call, then say "ok". Do not start subagents.', tag)) as EveryAISession;
    await _finish(parent);
    print('parent: prompt ${parent.lastPromptTokens}, cached ${parent.lastCachedTokens}');
    final fork = await harness.fork(
      parent.id,
      spec(forkBrief(const SubagentTask(description: 'Count files', prompt: 'How many entries did the listing show? Answer with the number only, no tools.')), tag),
    ) as EveryAISession;
    await _finish(fork);
    print('fork: prompt ${fork.lastPromptTokens}, cached ${fork.lastCachedTokens}');
    expect(fork.lastCachedTokens, greaterThan(fork.lastPromptTokens ~/ 2));
  }, timeout: const Timeout(Duration(minutes: 10)));
}
