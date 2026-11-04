// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import '../domain/agent_mode.dart';
import '../domain/code_session.dart' show everyaiHarnessName;
import '../domain/phases.dart' show bugCheckTool;
import '../harness/events.dart';
import '../harness/harness.dart';
import '../host/host.dart' show savedPlansTool;
import 'briefing/briefing_types.dart' show everyaiServerName;
import 'driver.dart';
import 'driver_process.dart' show notBuiltProblem;

// What the app does when a driver lacks a cap, in one place.

/// Steers a running turn: in place when the driver can ([steer]), else the
/// turn is interrupted and the message sent again ([resend]).
Future<void> steerOrResend(
  HarnessSession session,
  Set<DriverCap> caps, {
  required Future<void> Function(SteersRuns session) steer,
  required Future<void> Function() resend,
}) async {
  if (session case final SteersRuns s when caps.contains(DriverCap.steer)) return steer(s);
  await session.interrupt();
  await resend();
}

/// A fork on a driver without [DriverCap.fork]. Handing the session over
/// with a summary comes later.
HarnessError forkUnavailable(DriverInfo info) => HarnessError("${info.label} can't hand a session over to a fork yet.");

/// Why [info] can't go back to an earlier turn, or null when it can.
String? rewindRefusal(DriverInfo info, Set<DriverCap> caps) => caps.contains(DriverCap.rewind)
    ? null
    : "${info.label} can't go back to an earlier turn. Start a new session from here instead.";

/// Subagents run as the app's own child sessions when the driver has none.
bool usesOurChildSessions(Set<DriverCap> caps) => !caps.contains(DriverCap.subagents);

/// The action kinds the permission policy understands for an outside
/// driver: commands, file edits and reads, MCP calls, and the app's client
/// tools. Any other kind is the driver's own tool, which the rules can't
/// judge, so only the user may approve it. So is a known kind without the
/// field its rules read (a patch without `paths`, an edit with its native
/// `file_path` instead of `path`): judged on nothing, it would pass.
bool autoDecidable(ActionCall call) {
  if (isClientTool(call)) return true;
  if (!_knownKinds.contains(call.actionKind)) return false;
  bool has(String key) => call.str(key).isNotEmpty;
  return switch (call.actionKind) {
    'TerminalAction' => has('command'),
    'FileEditorAction' || 'EditAction' || 'WriteFileAction' || 'ReadFileAction' => has('path'),
    'ApplyPatchAction' => (call.action['paths'] as List<Object?>? ?? const []).any((p) => p is String && p.isNotEmpty),
    _ => true,
  };
}

const _knownKinds = {
  'TerminalAction',
  'FileEditorAction',
  'EditAction',
  'WriteFileAction',
  'ApplyPatchAction',
  'ReadFileAction',
  'GlobAction',
  'GrepAction',
  'ListDirectoryAction',
  'TaskTrackerAction',
  'ThinkAction',
  'FinishAction',
  'WebFetchAction',
  'WebSearchAction',
  'MCPToolAction',
};

/// The tools the app's MCP host offers an outside agent (`host/host.dart`).
const hostToolNames = {askUserQuestionTool, presentPlanTool, 'memory', savedPlansTool, bugCheckTool};

/// The host tools the policy lets run without asking: they only show the
/// user a card or read and write the project's notes. bug_check runs a
/// command, so it goes through the mode like any other.
const trustedHostTools = {askUserQuestionTool, presentPlanTool, 'memory', savedPlansTool};

/// The host tool an outside agent's [call] is (`ask_user_question`, …), or
/// null when it calls another MCP server. CLIs name MCP tools their own
/// way: `mcp__everyai__x` (Claude Code), `everyai__x`, `everyai.x`,
/// `everyai/x`. Only the name counts: the call's own arguments are the
/// agent's, so a field in them can't make a foreign tool ours.
String? hostToolOf(ActionCall call) {
  if (!isMcpTool(call)) return null;
  final name = call.toolName;
  for (final prefix in const ['mcp__${everyaiServerName}__', '${everyaiServerName}__', '$everyaiServerName.']) {
    if (name.startsWith(prefix)) return _host(name.substring(prefix.length));
  }
  if (name.startsWith('$everyaiServerName/')) return _host(name.substring(everyaiServerName.length + 1));
  return null;
}

String? _host(String bare) => hostToolNames.contains(bare) ? bare : null;

/// Why [info] can't lead a new session now, or null when it can: its
/// status isn't known yet, it isn't built, installed or signed in, it needs
/// the user's consent ([consented]: "Use my own installed CLIs"), or what
/// its check reported.
String? leadBlocked(DriverInfo info, DriverStatus? status, {required bool consented}) {
  if (info.id == everyaiHarnessName) return null;
  if (status == null) return 'Checking…';
  if (status.problem == notBuiltProblem) return 'Not built yet';
  if (!status.installed) return 'Not installed';
  if (status.signedIn == false) return 'Not signed in';
  if (info.needsConsent && !consented) return 'Turn on in Settings';
  return status.problem;
}

/// One line on how far [mode] holds on an outside lead: the driver's own
/// words when it explains its modes ([ExplainsModes]), else what its caps
/// allow. Null for the EveryAI harness, which enforces every mode itself.
String? fidelityNote(HarnessDriver driver, AgentMode mode) {
  final info = driver.info;
  if (info.id == everyaiHarnessName) return null;
  final lead = '${mode.label} on ${info.label}';
  if (driver case final ExplainsModes e) {
    if (e.howEnforced(mode) case final how? when how.isNotEmpty) return '$lead: $how';
  }
  return driver.caps.contains(DriverCap.approvals)
      ? '$lead: approvals only for what ${info.label} asks about'
      : '$lead: not enforced, ${info.label} acts without asking';
}
