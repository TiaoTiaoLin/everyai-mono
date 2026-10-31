// Runs one live scenario on the EveryAI harness through the backend gateway.
// Not part of `flutter test`: run it explicitly with the environment set.
//
//   GATEWAY_KEY=sk-eai-… \
//   EVAL_DIR=/path/to/repo EVAL_MODE=plan EVAL_MODEL=anthropic/claude-haiku-5.5 \
//   EVAL_PROMPT='…' [EVAL_EFFORT=medium EVAL_MAX_USD=5 EVAL_TAG=… EVAL_MINUTES=10] \
//   flutter test tool/agent_eval/scenario_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/harness/everyai/everyai_harness_io.dart';
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:every_ai/features/code/settings/settings.dart';
import 'package:flutter_test/flutter_test.dart';

import 'driver.dart';

void main() {
  final env = Platform.environment;
  test('scenario', () async {
    final mode = AgentMode.values.byName(env['EVAL_MODE'] ?? 'plan');
    final prompt = await agentPromptFor(env['EVAL_DIR']!);
    final api = env['API_BASE_URL'] ?? 'http://localhost:8080';
    final tag = env['EVAL_TAG'] ?? 'eval-${DateTime.now().millisecondsSinceEpoch}';
    Future<double> spent() async {
      final client = HttpClient();
      try {
        final req = await client.getUrl(Uri.parse('$api/v1/usage/session/$tag'));
        // Gateway keys can't read usage; DEV_AUTH serves it to anonymous callers.
        if (env['USER_TOKEN'] case final t?) req.headers.set('Authorization', 'Bearer $t');
        final body = await (await req.close()).transform(utf8.decoder).join();
        return ((jsonDecode(body) as Map<String, Object?>)['charged_micros'] as num? ?? 0) / 1e6;
      } finally {
        client.close();
      }
    }

    final data = await Directory.systemTemp.createTemp('everyai-scenario');
    final run = EvalRun(
      EveryAIHarness(dataDir: () async => data.path, gatewayKey: () async => env['GATEWAY_KEY']!),
      SessionSpec(
        workingDir: env['EVAL_DIR']!,
        model: env['EVAL_MODEL'] ?? 'anthropic/claude-haiku-5.5',
        mode: mode,
        llmBaseUrl: '$api/v1',
        llmApiKey: env['GATEWAY_KEY']!,
        sessionTag: tag,
        initialMessage: modeNote(mode, env['EVAL_PROMPT']!),
        maxInputTokens: 200000,
        persona: prompt.persona,
        promptSuffix: prompt.suffix,
        effort: env['EVAL_EFFORT'],
        holdClientTools: true,
      ),
      spent: spent,
      maxUsd: double.tryParse(env['EVAL_MAX_USD'] ?? ''),
    );
    try {
      await run.run(timeout: Duration(minutes: int.tryParse(env['EVAL_MINUTES'] ?? '') ?? 10));
    } finally {
      // ignore: avoid_print
      print('conversation ${run.session.id}\n${run.report()}');
    }
  }, timeout: Timeout.none);
}
