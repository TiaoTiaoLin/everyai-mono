import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/drivers/briefing/session_skill.dart';
import 'package:every_ai/features/skills/domain/skill_format.dart';
import 'package:flutter_test/flutter_test.dart';

SessionSkillInput _input({
  List<RosterEntry> others = const [],
  List<String> profiles = const [],
  String worktree = '/wt/s1',
}) => SessionSkillInput(
  worktree: worktree,
  projectRoot: '/proj',
  lead: (name: 'Claude Code', model: 'sonnet-5.5'),
  others: others,
  hostTools: const [
    (name: 'ask_user_question', when: 'a decision is the user\'s'),
    (name: 'present_plan', when: 'you finish planning'),
  ],
  runtimeProfiles: profiles,
);

void main() {
  test('is deterministic and has no dates or times', () {
    final a = sessionSkill(_input());
    expect(sessionSkill(_input()), a);
    expect(a, isNot(matches(RegExp(r'\d{4}-\d{2}-\d{2}|\d{2}:\d{2}'))));
  });

  test('is a valid skill', () {
    final md = sessionSkill(_input());
    final c = checkSkill(dirName: 'everyai-session', skillMd: md, entries: const [SkillEntry('SKILL.md', size: 1)]);
    expect(c.report.errors, isEmpty);
    expect(c.manifest!.name, 'everyai-session');
  });

  test('lists every mode with its reminder and states no current mode', () {
    final md = sessionSkill(_input());
    for (final m in AgentMode.values) {
      expect(md, contains(m.reminder));
    }
    expect(md, contains('latest tag'));
    expect(md, isNot(contains('Current mode')));
  });

  test('carries the rule and the host tools', () {
    final md = sessionSkill(_input());
    expect(md, contains('Check per part, not per edit'));
    expect(md, contains('`ask_user_question`: a decision is the user\'s'));
    expect(md, contains('`/wt/s1`'));
  });

  test('roster and profiles come last: changing them leaves the prefix alone', () {
    final a = sessionSkill(_input());
    final b = sessionSkill(_input(others: [(name: 'Codex', model: 'gpt-6.1')], profiles: ['test: flutter test']));
    final cut = a.indexOf('## Who is in this session');
    expect(cut, greaterThan(0));
    expect(b.substring(0, cut), a.substring(0, cut));
    expect(b, contains('Codex (gpt-6.1)'));
    expect(b, contains('test: flutter test'));
    expect(a, contains('None recorded yet'));
    expect(a.indexOf('## Rules'), lessThan(cut));
    expect(a.indexOf('## Runtime profiles'), greaterThan(cut));
  });
}
