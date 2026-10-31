import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/settings/agent_prompt.dart';
import 'package:every_ai/features/code/settings/code_settings.dart';
import 'package:every_ai/features/code/settings/settings.dart' show AgentSettings;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('each tier has its own rules, and forks are mentioned only where they apply', () {
    expect(tierBlock(HarnessTier.ultraEfficient), contains('smallest sound change'));
    expect(tierBlock(HarnessTier.efficient), contains('one polish pass'));
    expect(tierBlock(HarnessTier.thorough), contains('showcase'));
    expect(tierBlock(HarnessTier.max), allOf(contains('research → questions → plan'), contains('showcase')));
    expect(tierBlock(HarnessTier.efficient), isNot(contains('fork')));
    expect(tierBlock(HarnessTier.efficient, forks: true), contains('fork yourself'));
    expect(tierBlock(HarnessTier.max, forks: true), contains('role "researcher"'));
    expect(tierBlock(HarnessTier.ultraEfficient, forks: true), isNot(contains('fork')));
  });

  test('the bar offers four tiers; ultra efficient stays hidden', () {
    expect(HarnessTier.offered, [HarnessTier.efficient, HarnessTier.thorough, HarnessTier.max, HarnessTier.ultra]);
    expect(HarnessTier.max.phased && HarnessTier.ultra.phased, isTrue);
    expect(HarnessTier.thorough.phased, isFalse);
  });

  test('the tier and fork isolation are stored, with the defaults left out', () {
    const plain = StoredCodeSettings();
    expect(plain.tier, HarnessTier.efficient);
    expect(plain.forksIsolated, isTrue);
    expect(plain.toJson()['global'], isEmpty);
    final set = plain.withTier(HarnessTier.max).withForksIsolated(false);
    final back = StoredCodeSettings.fromJson(set.toJson());
    expect(back.tier, HarnessTier.max);
    expect(back.forksIsolated, isFalse);
  });

  test('old work styles move to the tiers: balanced is now efficient, efficient is ultra efficient', () {
    StoredCodeSettings read(String style) => StoredCodeSettings.fromJson({
      'global': {'workStyle': style},
    });
    expect(read('balanced').tier, HarnessTier.efficient);
    expect(read('efficient').tier, HarnessTier.ultraEfficient);
    expect(read('thorough').tier, HarnessTier.thorough);
  });

  test('a session keeps its tier and harness mode', () {
    final info = CodeSessionInfo(
      id: 's',
      projectId: 'p',
      title: 't',
      conversationId: 'c',
      model: 'm',
      mode: AgentMode.autoEdit,
      workingDir: '/w',
      createdAt: DateTime(2026),
      tier: HarnessTier.max,
    );
    final back = CodeSessionInfo.fromJson(info.toJson());
    expect(back.tier, HarnessTier.max);
    expect(back.harnessMode, HarnessMode.build);
    expect(back.copyWith(tier: HarnessTier.thorough).tier, HarnessTier.thorough);
  });

  test('moving a running session to another tier sends the new rules', () {
    expect(tierChangeNote(HarnessTier.thorough), allOf(contains('Thorough tier'), contains('showcase')));
  });

  test('Bug fix mode adds its rules, and the mode is stored as the default for new sessions', () {
    final suffix = agentPromptSuffix(AgentSettings.defaults, harnessMode: HarnessMode.bugFix);
    expect(
      suffix,
      allOf(contains('<HARNESS_MODE name="bugFix">'), contains("don't guess"), contains('ask_user_question')),
    );
    expect(agentPromptSuffix(AgentSettings.defaults), isNot(contains('HARNESS_MODE')));
    final back = StoredCodeSettings.fromJson(const StoredCodeSettings().withHarnessMode(HarnessMode.bugFix).toJson());
    expect(back.harnessMode, HarnessMode.bugFix);
  });
}
