// Live check that an EveryAI agent can see: through the Playwright MCP
// server (screenshots) and by reading a screenshot file. Not part of
// `flutter test`:
//
//   GATEWAY_KEY=sk-eai-… EVAL_DIR=/path/with/page [API_BASE_URL=… EVAL_MODEL=…] \
//   flutter test tool/agent_eval/everyai_vision_live_test.dart
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:io';

import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/mcp_servers.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:every_ai/features/code/harness/everyai/everyai_harness_io.dart';
import 'package:every_ai/features/code/harness/harness.dart';
import 'package:every_ai/features/code/settings/settings.dart';
import 'package:flutter_test/flutter_test.dart';

final _env = Platform.environment;

Future<List<HarnessEvent>> _finish(HarnessSession s) async {
  final events = <HarnessEvent>[];
  final done = Completer<void>();
  final sub = s.events.listen((e) {
    events.add(e);
    if (e is ActionCall) print('  call ${e.toolName} ${e.action.toString().substring(0, e.action.toString().length.clamp(0, 140))}');
    if (e is ToolResult) print('  result ${e.text.length > 300 ? e.text.substring(0, 300) : e.text}');
    if (e is ConversationFailure) print('  FAIL ${e.message}');
    if (e is StateChange) print('  status ${e.executionStatus}');
    if (e is StateChange && e.executionStatus == ExecutionStatus.waitingForConfirmation) unawaited(s.respond(accept: true));
    if (e is StateChange && e.executionStatus == ExecutionStatus.finished && !done.isCompleted) done.complete();
  });
  await done.future.timeout(const Duration(minutes: 6));
  // The final message can land just after the status.
  await Future<void>.delayed(const Duration(milliseconds: 500));
  await sub.cancel();
  return events;
}

void main() {
  test('an EveryAI agent sees a page through Playwright MCP and a screenshot file', () async {
    final dir = _env['EVAL_DIR']!;
    final api = _env['API_BASE_URL'] ?? 'http://localhost:8080';
    final data = await Directory.systemTemp.createTemp('everyai-vision');
    final harness = EveryAIHarness(dataDir: () async => data.path, gatewayKey: () async => _env['GATEWAY_KEY']!);
    final prompt = await agentPromptFor(dir);
    // Playwright blocks file: URLs, so the page is served.
    final server = await Process.start('python3', ['-m', 'http.server', '8765', '--bind', '127.0.0.1'], workingDirectory: dir);
    addTearDown(server.kill);
    await Future<void>.delayed(const Duration(seconds: 1));
    final playwright = mcpPresets.firstWhere((p) => p.id == 'playwright').server;
    final session = await harness.start(
      SessionSpec(
        workingDir: dir,
        model: _env['EVAL_MODEL'] ?? 'anthropic/claude-haiku-5.5',
        mode: AgentMode.fullAuto,
        llmBaseUrl: '$api/v1',
        llmApiKey: _env['GATEWAY_KEY']!,
        sessionTag: 'vision-live-${DateTime.now().millisecondsSinceEpoch}',
        persona: prompt.persona,
        promptSuffix: prompt.suffix,
        effort: 'low',
        vision: true,
        mcpConfig: {'playwright': playwright.toAgentConfig()},
        initialMessage:
            'Two checks, then answer in two short lines. 1) With the Playwright MCP tools, open http://127.0.0.1:8765/page.html, '
            'take a screenshot and say the big word on it and its colour. 2) Read $dir/shot.png with the read tool '
            'and say what shape and colour it shows. Use no other tools.',
      ),
    );
    final events = await _finish(session);
    final answer = events.whereType<ChatMessage>().where((m) => !m.fromUser).map((m) => m.text).join('\n');
    print('ANSWER: $answer');
    expect(events.whereType<ActionCall>().any((c) => c.actionKind == 'MCPToolAction'), isTrue);
    expect(answer.toUpperCase(), contains('PELICAN'));
    expect(answer.toLowerCase(), contains('circle'));
  }, timeout: const Timeout(Duration(minutes: 8)));
}
