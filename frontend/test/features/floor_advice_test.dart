import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/floor_advice.dart';
import 'package:every_ai/features/code/domain/permissions.dart';
import 'package:every_ai/features/code/harness/events.dart';
import 'package:flutter_test/flutter_test.dart';

ActionCall _sh(String command, {String id = 'a'}) => HarnessEvent.decode({
  'kind': 'ActionEvent',
  'id': id,
  'tool_name': 'terminal',
  'action': {'kind': 'TerminalAction', 'command': command},
}) as ActionCall;

void main() {
  const policy = PermissionPolicy(workingDir: '/work/app');

  test('Full auto: a floor hit is refused with advice the model can act on', () {
    final v = outsideVerdict(policy, _sh('rm -rf ~'), AgentMode.fullAuto)!;
    expect(v.accept, isFalse);
    expect(v.reason, startsWith(floorAdviceLead));
    expect(v.reason, contains(floorReason('rm -rf ~')!));
    expect(v.reason, contains('ask them'));
  });

  test('once advised about a floor reason, the user decides, however the retry is worded', () {
    final advised = <String>{};
    expect(
      outsideVerdict(policy, _sh('rm -rf ~'), AgentMode.fullAuto, advised: advised)?.reason,
      startsWith(floorAdviceLead),
    );
    for (final retry in ['rm -rf ~', 'rm  -rf   ~', 'cd /tmp && rm -rf ~']) {
      expect(outsideVerdict(policy, _sh(retry), AgentMode.fullAuto, advised: advised), isNull, reason: retry);
    }
  });

  test('a host-run check that hits the floor is refused outright, with no advice', () {
    final check = HarnessEvent.decode({
      'kind': 'ActionEvent',
      'id': 'b',
      'tool_name': 'mcp__everyai__bug_check',
      'action': {'kind': 'MCPToolAction', 'command': 'rm -rf ~'},
    }) as ActionCall;
    for (final m in AgentMode.values) {
      for (final advised in [
        <String>{},
        {floorReason('rm -rf ~')!},
      ]) {
        final v = outsideVerdict(policy, check, m, advised: advised);
        expect(v?.accept, isFalse, reason: '$m');
        expect(v!.reason, isNot(startsWith(floorAdviceLead)), reason: '$m');
      }
    }
  });

  test('a floor hit is never approved on its own', () {
    for (final m in AgentMode.values) {
      for (final c in ['rm -rf ~', 'sudo rm -rf /usr', 'mkfs.ext4 /dev/sdb1', ':(){ :|:& };:']) {
        for (final advised in [
          <String>{},
          {floorReason(c) ?? ''},
        ]) {
          expect(outsideVerdict(policy, _sh(c), m, advised: advised)?.accept, isNot(isTrue), reason: '$m $c');
        }
      }
    }
  });

  test('Ask and Auto-edit leave it to the card; Plan still refuses', () {
    expect(outsideVerdict(policy, _sh('rm -rf ~'), AgentMode.ask), isNull);
    expect(outsideVerdict(policy, _sh('rm -rf ~'), AgentMode.autoEdit), isNull);
    expect(outsideVerdict(policy, _sh('rm -rf ~'), AgentMode.plan), (accept: false, reason: AgentMode.planRefusal));
  });

  test("the user's deny rules stay hard", () {
    const denying = PermissionPolicy(rules: PermissionRules(deny: ['rm *']));
    for (final m in [AgentMode.fullAuto, AgentMode.ask]) {
      final v = outsideVerdict(denying, _sh('rm -rf ~'), m)!;
      expect(v.accept, isFalse);
      expect(v.reason, isNot(startsWith(floorAdviceLead)));
      expect(v.reason, contains('`rm *` forbids it'));
    }
  });

  test('anything else is decided as before', () {
    for (final m in AgentMode.values) {
      for (final c in ['ls', 'npm install', 'git reset --hard']) {
        expect(outsideVerdict(policy, _sh(c), m), policy.decideAll([_sh(c)], m), reason: '$m $c');
      }
    }
  });

  test('the card warns about floor hits and dangerous calls, not plain asks', () {
    final flags = approvalFlags(policy, [
      _sh('rm -rf ~', id: 'floor'),
      _sh('git reset --hard', id: 'danger'),
      _sh('npm install', id: 'plain'),
    ], AgentMode.ask);
    expect(flags.keys, unorderedEquals(['floor', 'danger']));
    expect(flags['floor'], floorReason('rm -rf ~'));
  });
}
