// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:http/http.dart' as http;

import '../harness/everyai/llm.dart';
import '../harness/everyai/script_io.dart';
import '../harness/everyai/shell_io.dart';
import '../harness/everyai/tools_io.dart';
import '../harness/harness.dart' show ScriptCaps;
import 'host.dart' show HostResult;

bool get hostScriptsAvailable => findDeno() != null;

/// No model call and no web: the runner is offline, and its gateway could
/// not reach anything even if a call slipped past that.
const _caps = ScriptCaps(decides: 0, queries: 0);

final class _NoNetwork extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      throw StateError('run_script on the MCP host makes no requests');
}

Future<HostResult> hostRunScript(
  String root,
  String stateDir,
  Map<String, Object?> args, {
  Future<void>? cancel,
}) async {
  final deno = findDeno();
  if (deno == null) return (text: 'Error: Deno is not installed here, so scripts are off.', isError: true);
  final code = args['code'] as String? ?? '';
  if (code.trim().isEmpty) return (text: 'Error: code is empty.', isError: true);
  final gateway = GatewayClient(baseUrl: 'http://offline.invalid/v1', apiKey: 'offline', client: _NoNetwork());
  const tag = 'host-script';
  final runner = ScriptRunner(
    deno: deno,
    dir: '$stateDir/scripts',
    root: root,
    tools: ToolRunner(
      root: root,
      shell: SessionShell(root: root, sessionTag: tag, scratchDir: '$stateDir/shell'),
      gateway: gateway,
      sessionTag: tag,
    ),
    gateway: gateway,
    sessionTag: tag,
    offline: true,
  );
  final seconds = ((args['timeout_seconds'] as num?)?.toInt() ?? 120).clamp(1, 600);
  final r = await runner.run(
    code,
    budget: ScriptBudget(_caps),
    timeout: Duration(seconds: seconds),
    cancel: cancel,
  );
  final head = r.timedOut
      ? '[The script timed out and was stopped.]\n'
      : r.exitCode != 0
      ? '[The script failed (exit ${r.exitCode}).]\n'
      : '';
  return (text: '$head${r.output.isEmpty ? '(The script printed nothing.)' : r.output}', isError: r.exitCode != 0);
}
