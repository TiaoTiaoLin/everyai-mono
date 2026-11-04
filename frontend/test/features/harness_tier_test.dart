import 'package:every_ai/features/code/domain/agent_mode.dart';
import 'package:every_ai/features/code/domain/code_session.dart';
import 'package:every_ai/features/code/settings/agent_prompt.dart';
import 'package:every_ai/features/code/settings/code_settings.dart';
import 'package:every_ai/features/code/settings/settings.dart' show AgentSettings;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('each level has its own rules, and forks are mentioned only where they apply', () {
    expect(tierBlock(HarnessTier.ultraEfficient), contains('smallest sound change'));
    expect(tierBlock(HarnessTier.efficient), contains('one polish pass'));
    expect(tierBlock(HarnessTier.thorough), contains('showcase'));
    expect(tierBlock(HarnessTier.efficient), isNot(contains('fork')));
    expect(tierBlock(HarnessTier.efficient, forks: true), contains('fork yourself'));
    expect(tierBlock(HarnessTier.ultraEfficient, forks: true), isNot(contains('fork')));
    // No phases or Bug fix rules are left in the prompt.
    final suffix = agentPromptSuffix(AgentSettings.defaults, tier: HarnessTier.thorough);
    expect(suffix, isNot(contains('HARNESS_MODE')));
    expect(suffix, isNot(contains('research → questions')));
  });

  test('the effort level offers Efficient and Thorough; ultra efficient stays hidden', () {
    expect(HarnessTier.offered, [HarnessTier.efficient, HarnessTier.thorough]);
    expect(HarnessTier.values, [HarnessTier.ultraEfficient, HarnessTier.efficient, HarnessTier.thorough]);
  });

  test('the level and fork isolation are stored, with the defaults left out', () {
    const plain = StoredCodeSettings();
    expect(plain.tier, HarnessTier.efficient);
    expect(plain.forksIsolated, isTrue);
    expect(plain.toJson()['global'], isEmpty);
    final set = plain.withTier(HarnessTier.thorough).withForksIsolated(false);
    final back = StoredCodeSettings.fromJson(set.toJson());
    expect(back.tier, HarnessTier.thorough);
    expect(back.forksIsolated, isFalse);
  });

  test('an old global Max or Ultra tier reads as Thorough, and the old harness mode is dropped', () {
    StoredCodeSettings read(Map<String, Object?> global) => StoredCodeSettings.fromJson({'global': global});
    expect(read({'harnessTier': 'ultra'}).tier, HarnessTier.thorough);
    expect(read({'harnessTier': 'max'}).tier, HarnessTier.thorough);
    expect(read({'harnessTier': 'max', 'harnessMode': 'bugFix'}).toJson()['global'], {'harnessTier': 'thorough'});
  });

  test('old work styles move to the levels: balanced is now efficient, efficient is ultra efficient', () {
    StoredCodeSettings read(String style) => StoredCodeSettings.fromJson({
      'global': {'workStyle': style},
    });
    expect(read('balanced').tier, HarnessTier.efficient);
    expect(read('efficient').tier, HarnessTier.ultraEfficient);
    expect(read('thorough').tier, HarnessTier.thorough);
  });

  group('a stored session', () {
    final base = CodeSessionInfo(
      id: 's',
      projectId: 'p',
      title: 't',
      conversationId: 'c',
      model: 'm',
      mode: AgentMode.autoEdit,
      workingDir: '/w',
      createdAt: DateTime(2026),
      harness: 'everyai',
    ).toJson();
    CodeSessionInfo load(Map<String, Object?> extra) => CodeSessionInfo.fromJson({...base, ...extra});

    test('keeps its level and its Max workflow', () {
      final info = load({'tier': 'thorough', 'workflow': 'max'});
      final back = CodeSessionInfo.fromJson(info.toJson());
      expect(back.tier, HarnessTier.thorough);
      expect(back.workflow, 'max');
      expect(back.copyWith(clearWorkflow: true).workflow, isNull);
    });

    test('on the old Max tier goes on as Thorough with the Max workflow', () {
      final info = load({'tier': 'max'});
      expect(info.tier, HarnessTier.thorough);
      expect(info.workflow, 'max');
    });

    test('on Ultra or in Bug fix mode goes on as Thorough with no workflow', () {
      for (final extra in [
        {'tier': 'ultra'},
        {'harness_mode': 'bugFix'},
        {'tier': 'ultra', 'harness_mode': 'bugFix'},
      ]) {
        final info = load(extra);
        expect(info.tier, HarnessTier.thorough, reason: '$extra');
        expect(info.workflow, isNull, reason: '$extra');
        expect(info.toJson().containsKey('harness_mode'), isFalse);
      }
    });

    test('without a tier is Efficient', () {
      expect(CodeSessionInfo.fromJson({...base}..remove('tier')).tier, HarnessTier.efficient);
    });
  });

  test('moving a running session to another level sends the new rules', () {
    expect(tierChangeNote(HarnessTier.thorough), allOf(contains('Thorough tier'), contains('showcase')));
  });
}
