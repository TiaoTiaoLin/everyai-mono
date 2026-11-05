import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'harness/events.dart';

/// Prefs key prefix of the limit banner the user closed, per session (see
/// `LimitBanner`).
const codeLimitBannerPrefix = 'code.limit_banner.';

/// The latest [PlanLimits] a session's harness reported, or null when it
/// reports none (the EveryAI harness, ACP, OpenCode). History replays it,
/// so a reopened session has it again; a new lead starts with none (the
/// old lead's limits aren't the session's any more).
final codePlanLimitsProvider = NotifierProvider.family<CodePlanLimits, PlanLimits?, String>(CodePlanLimits.new);

final class CodePlanLimits extends Notifier<PlanLimits?> {
  CodePlanLimits(this.sessionId);
  final String sessionId;

  @override
  PlanLimits? build() => null;

  void set(PlanLimits limits) => state = limits;

  void clear() => state = null;
}
