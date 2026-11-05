import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/approval_reason.dart';
import 'package:every_ai/features/code/domain/permissions.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:flutter_test/flutter_test.dart';

ActionCall _call(Map<String, Object?> action, {String tool = 'terminal', String id = 'a'}) =>
    HarnessEvent.decode({'kind': 'ActionEvent', 'id': id, 'tool_name': tool, 'action': action}) as ActionCall;

ActionCall _sh(String command, {String id = 'a'}) => _call({'kind': 'TerminalAction', 'command': command}, id: id);

ActionCall _write(String path, {String id = 'w'}) =>
    _call({'kind': 'WriteFileAction', 'path': path, 'content': 'x'}, tool: 'write', id: id);

const _dir = '/work/app';
const _policy = PermissionPolicy(workingDir: _dir);

String _why(ActionCall c, AgentMode mode, {String? outsideKind, bool askMcp = false}) =>
    askReason(_policy.decide(c, mode), c, mode, outsideKind: outsideKind, askMcp: askMcp);

void main() {
  test('each mode says what it asks about', () {
    expect(_why(_sh('npm test'), AgentMode.ask), 'Ask mode asks before every edit and command.');
    expect(_why(_write('$_dir/a.txt'), AgentMode.ask), 'Ask mode asks before every edit and command.');
    expect(_why(_sh('npm test'), AgentMode.autoEdit), startsWith('Auto-edit asks before commands'));
    expect(_why(_sh('git fetch origin'), AgentMode.plan), 'Plan mode asks before looking things up.');
    final exit = _call({'kind': 'ExitPlanModeAction'}, tool: 'ExitPlanMode');
    expect(_why(exit, AgentMode.plan), "Leaving Plan mode with a plan is the user's call.");
  });

  test('MCP tools, dangerous actions and edits outside the project name their rule', () {
    final mcp = _call({'kind': 'MCPToolAction'}, tool: 'browser_click');
    expect(_why(mcp, AgentMode.autoEdit), startsWith('MCP tools ask unless the session is in Full auto'));
    expect(_why(mcp, AgentMode.fullAuto), isEmpty);
    expect(
      _why(mcp, AgentMode.fullAuto, askMcp: true),
      'Before the plan is approved, MCP tools ask even in Full auto.',
    );
    expect(_why(_sh('rm -rf build'), AgentMode.autoEdit), endsWith('so it asks in every mode but Full auto.'));
    expect(
      _why(_write('/etc/hosts'), AgentMode.fullAuto),
      'Edits outside the project ask in every mode, Full auto included.',
    );
    expect(
      _why(_write('$_dir/.env'), AgentMode.ask),
      'This edits an environment file, which may hold secrets, so it asks in every mode but Full auto.',
    );
    // On a card only for an outside lead, after the floor advice.
    expect(_why(_sh('rm -rf /'), AgentMode.fullAuto), 'This ${floorReason('rm -rf /')}, which is on the safety floor.');
  });

  test("an outside harness's own tools say why they always ask", () {
    final own = _call({'kind': 'WebSearchAction'}, tool: 'WebSearch');
    expect(
      _why(own, AgentMode.fullAuto, outsideKind: 'Claude Code'),
      "Claude Code's own WebSearch tool can't be checked by EveryAI's rules, so it always asks.",
    );
  });

  test('what runs on its own has no reason', () {
    expect(_why(_sh('ls'), AgentMode.ask), isEmpty);
    expect(_why(_sh('npm test'), AgentMode.fullAuto), isEmpty);
    expect(_why(_write('$_dir/a.txt'), AgentMode.autoEdit), isEmpty);
    final reasons = approvalReasons(_policy, [_sh('npm test', id: '1'), _sh('ls', id: '2')], AgentMode.ask);
    expect(reasons, {'1': 'Ask mode asks before every edit and command.'});
    expect(askedLine(['a.', 'a.', 'b.', 'c.', 'd.']), 'a. b. c.');
  });
}
