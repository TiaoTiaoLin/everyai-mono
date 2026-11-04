import '../harness/events.dart';
import 'agent_mode.dart';
import 'permissions.dart';

/// How the floor advice starts, so a caller can tell it from other refusals.
const floorAdviceLead = 'EveryAI flagged this as dangerous and did not run it:';

/// What an outside harness's model reads when our safety floor flags [call]
/// for [why]: advice it may push back on, not a refusal that ends the work.
String floorAdvice(ActionCall call, String why) {
  final text = call.str('command').trim().replaceAll(RegExp(r'\s+'), ' ');
  final what = text.length <= 120 ? text : '${text.substring(0, 117)}…';
  return '$floorAdviceLead `$what` $why. Reconsider: if a safer way does the job, use it. '
      'If you are sure this is needed, tell the user why and ask them; '
      'when you run it again, the user decides.';
}

/// [PermissionPolicy.decideAll] for one call of an outside harness, where
/// the safety floor is advice: a floor hit is never approved on its own.
/// The user's deny rules and Plan mode still refuse it. When the mode
/// would have run it, the model gets [floorAdvice] once (until [advised]);
/// otherwise (or after that) null leaves it to the user on the card.
({bool accept, String? reason})? outsideVerdict(
  PermissionPolicy policy,
  ActionCall call,
  AgentMode mode, {
  bool askMcp = false,
  bool advised = false,
}) {
  final d = policy.decide(call, mode);
  if (d.source != DecisionSource.floor) return policy.decideAll([call], mode, askMcp: askMcp);
  final rest = policy.decide(call, mode, floor: false);
  if (rest.source == DecisionSource.rule) return (accept: false, reason: policyDenial([(call, rest)]));
  if (rest.source == DecisionSource.plan) return (accept: false, reason: AgentMode.planRefusal);
  if (rest.verdict == Verdict.allow && !advised) return (accept: false, reason: floorAdvice(call, d.why));
  return null;
}

/// The warning shown on the approval card for each of [pending]: dangerous
/// calls and safety-floor hits, by call id.
Map<String, String> approvalFlags(PermissionPolicy policy, Iterable<ActionCall> pending, AgentMode mode) => {
  for (final c in pending)
    if (policy.decide(c, mode) case Decision(source: DecisionSource.dangerous || DecisionSource.floor, :final why))
      c.id: why,
};
