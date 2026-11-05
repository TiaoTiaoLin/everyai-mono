// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import '../harness/events.dart';
import 'agent_mode.dart';
import 'permissions.dart';

/// Why [call] waits for the user, in one plain sentence: the rule, the mode
/// or the safety reason behind [d] (from [PermissionPolicy.decide]). Shown
/// on the approval card and told to the agent when the user says no, so it
/// knows what would have run on its own. Empty for decisions that don't ask.
///
/// [outsideKind] names the outside harness ("Claude Code") when the call is
/// one of its own tools the rules can't judge (`autoDecidable` is false),
/// which always asks. [askMcp]: a Max/Ultra flow before the plan is approved
/// (see [PermissionPolicy.decideAll]).
String askReason(Decision d, ActionCall call, AgentMode mode, {String? outsideKind, bool askMcp = false}) {
  if (outsideKind != null && d.verdict == Verdict.allow) {
    final tool = call.toolName.isEmpty ? 'tool' : '${call.toolName} tool';
    return "$outsideKind's own $tool can't be checked by EveryAI's rules, so it always asks.";
  }
  return switch (d.source) {
    DecisionSource.floor => 'This ${_bare(d.why)}, which is on the safety floor.',
    DecisionSource.dangerous when d.why == outsideProject =>
      'Edits outside the project ask in every mode, Full auto included.',
    DecisionSource.dangerous => 'This ${_bare(d.why)}, so it asks in every mode but Full auto.',
    // Full auto would run it, but the Max/Ultra gate asks.
    DecisionSource.mode when isMcpTool(call) && askMcp && d.verdict == Verdict.allow =>
      'Before the plan is approved, MCP tools ask even in Full auto.',
    DecisionSource.mode when d.verdict != Verdict.ask => '',
    DecisionSource.mode when isMcpTool(call) =>
      'MCP tools ask unless the session is in Full auto or an Mcp(...) rule allows them.',
    DecisionSource.mode when mode == AgentMode.plan && planExitTools.contains(call.toolName) =>
      "Leaving Plan mode with a plan is the user's call.",
    DecisionSource.mode => switch (mode) {
      AgentMode.plan => 'Plan mode asks before looking things up.',
      AgentMode.ask => 'Ask mode asks before every edit and command.',
      AgentMode.autoEdit => 'Auto-edit asks before commands and anything else that is not a file edit.',
      AgentMode.fullAuto => '',
    },
    _ => '',
  };
}

/// "an environment file…" → "environment file…" after "This".
String _bare(String why) => why.replaceFirst(RegExp(r'^an? '), '');

/// [askReason] for each of [pending] that has one, by call id. [outsideKind]
/// gives the harness's name for a call the rules can't judge, or null.
Map<String, String> approvalReasons(
  PermissionPolicy policy,
  Iterable<ActionCall> pending,
  AgentMode mode, {
  String? Function(ActionCall call)? outsideKind,
  bool askMcp = false,
}) => {
  for (final c in pending)
    if (askReason(policy.decide(c, mode), c, mode, outsideKind: outsideKind?.call(c), askMcp: askMcp) case final why
        when why.isNotEmpty)
      c.id: why,
};

/// The distinct reasons in [reasons] as one line for [denialMessage]'s
/// `asked`, at most [max] of them.
String askedLine(Iterable<String> reasons, {int max = 3}) => reasons.toSet().take(max).join(' ');
