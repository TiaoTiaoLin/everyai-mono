// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import '../domain/agent_mode.dart' show isClientTool;
import '../harness/events.dart';
import '../harness/harness.dart';
import 'driver.dart';

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
