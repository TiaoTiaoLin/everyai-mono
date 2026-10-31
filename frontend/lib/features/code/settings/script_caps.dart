import '../harness/everyai/model_family.dart';
import '../harness/harness.dart' show ScriptCaps;
import 'agent_prompt.dart' show HarnessTier;

/// The run_script setting: the tier's defaults, or one level for every tier.
enum ScriptLevel {
  byTier('By tier', 'Each tier\'s own limits'),
  off('Off', 'No run_script'),
  decide('Scripts + decide', 'Scripts with fast decisions, no llmQuery'),
  query('Scripts + llmQuery', 'Scripts may hand chunks to a cheap model'),
  deep('Deep', 'llmQuery may write scripts of its own (depth 2)');

  const ScriptLevel(this.label, this.description);
  final String label;
  final String description;

  static ScriptLevel parse(Object? s) => values.where((v) => v.name == s).firstOrNull ?? byTier;
}

/// Model families that write sound programs: the others keep plain tool
/// calls unless the user turned scripts on for every tier.
const _scriptFamilies = {ModelFamily.claude, ModelFamily.gpt, ModelFamily.gemini};

/// What run_script and the decider may do in a session on [tier] with
/// [model], after the user's [level]. Efficient saves tokens (scripts and
/// decide); higher tiers dig deeper (llmQuery, then depth 2) and score old
/// tool output before compaction clears it.
ScriptCaps scriptCapsFor(HarnessTier tier, String model, {ScriptLevel level = ScriptLevel.byTier}) {
  final smart = tier.index >= HarnessTier.thorough.index;
  final (decides, queries, depth) = switch (tier) {
    HarnessTier.ultraEfficient => (10, 0, 1),
    HarnessTier.efficient => (20, 0, 1),
    HarnessTier.thorough => (40, 20, 1),
    HarnessTier.max => (80, 40, 1),
    HarnessTier.ultra => (150, 80, 2),
  };
  final family = _scriptFamilies.contains(familyOf(model));
  return switch (level) {
    ScriptLevel.byTier => ScriptCaps(
      enabled: family,
      decides: decides,
      queries: queries,
      depth: depth,
      smartCompaction: smart,
    ),
    ScriptLevel.off => ScriptCaps(enabled: false, smartCompaction: smart),
    ScriptLevel.decide => ScriptCaps(decides: decides, queries: 0, smartCompaction: smart),
    ScriptLevel.query => ScriptCaps(decides: decides, queries: queries < 20 ? 20 : queries, smartCompaction: smart),
    ScriptLevel.deep => ScriptCaps(
      decides: decides,
      queries: queries < 20 ? 20 : queries,
      depth: 2,
      smartCompaction: smart,
    ),
  };
}
