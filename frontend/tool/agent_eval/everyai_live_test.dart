// Live check of the EveryAI harness: one session on a real model through the
// gateway, every call approved (Full auto), with a transcript printed.
// Not part of `flutter test`; run it explicitly:
//
//   GATEWAY_KEY=sk-eai-… EVAL_DIR=/path/to/repo EVAL_PROMPT='…' \
//   [API_BASE_URL=http://localhost:8080 EVAL_MODEL=anthropic/claude-haiku-5.5 EVAL_MINUTES=10] \
//   flutter test tool/agent_eval/everyai_live_test.dart
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:io';

import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/everyai/everyai_harness_io.dart';
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:every_ai/features/code/settings/settings.dart';
import 'package:flutter_test/flutter_test.dart';

final _env = Platform.environment;

void main() {
  test(
    'EveryAI harness live run',
    () async {
      final dir = _env['EVAL_DIR']!;
      final api = _env['API_BASE_URL'] ?? 'http://localhost:8080';
      final data = await Directory.systemTemp.createTemp('everyai-live');
      final harness = EveryAIHarness(dataDir: () async => data.path, gatewayKey: () async => _env['GATEWAY_KEY']!);
      final prompt = await agentPromptFor(dir);
      final session = await harness.start(
        SessionSpec(
          workingDir: dir,
          model: _env['EVAL_MODEL'] ?? 'anthropic/claude-haiku-5.5',
          mode: AgentMode.fullAuto,
          llmBaseUrl: '$api/v1',
          llmApiKey: _env['GATEWAY_KEY']!,
          sessionTag: _env['EVAL_TAG'] ?? 'everyai-live-${DateTime.now().millisecondsSinceEpoch}',
          persona: prompt.persona,
          promptSuffix: prompt.suffix,
          effort: _env['EVAL_EFFORT'] ?? 'medium',
          holdClientTools: true,
          initialMessage: modeNote(AgentMode.fullAuto, _env['EVAL_PROMPT']!),
        ),
      );
      final done = Completer<void>();
      final calls = <String, ActionCall>{};
      final watch = Stopwatch()..start();
      session.events.listen((e) async {
        final t = '[${(watch.elapsedMilliseconds / 1000).toStringAsFixed(1)}s]';
        switch (e) {
          case ChatMessage(:final fromUser, :final text) when text.trim().isNotEmpty:
            print('$t ${fromUser ? 'USER' : 'AGENT'}: ${text.trim()}');
          case ActionCall():
            calls[e.id] = e;
            final what = e.str('command').isNotEmpty ? e.str('command') : e.action.toString();
            print('$t CALL ${e.toolName}: ${what.length > 300 ? '${what.substring(0, 300)}…' : what}');
          case ToolResult():
            final text = e.text.trim();
            print('$t  → ${e.outcome.name}: ${text.length > 400 ? '${text.substring(0, 400)}…' : text}');
          case StateChange(:final executionStatus):
            if (executionStatus == ExecutionStatus.waitingForConfirmation) {
              final held = calls.values.where(isHeldTool).where((c) => c.toolName == askUserQuestionTool);
              if (held.isNotEmpty) {
                await session.respond(accept: false, reason: 'Pick whatever you think is best.');
                await session.resume();
              } else {
                await session.respond(accept: true);
              }
            }
            if (executionStatus == ExecutionStatus.finished || executionStatus == ExecutionStatus.error) {
              if (!done.isCompleted) done.complete();
            }
          case ConversationFailure(:final message):
            print('$t ERROR: $message');
          default:
            break;
        }
      });
      await done.future.timeout(Duration(minutes: int.parse(_env['EVAL_MINUTES'] ?? '10')));
      print('Finished in ${watch.elapsed.inSeconds}s; session data in ${data.path}');
    },
    timeout: const Timeout(Duration(minutes: 30)),
  );
}
