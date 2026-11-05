// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';

import '../domain/agent_mode.dart' show askUserQuestionTool, presentPlanTool;
import '../domain/phases.dart' show bugCheckTool;
import 'host_checks.dart' show checkTool, diffStatsTool;
import 'host_report.dart' show reportIssueTool;
import 'host_server_stub.dart' if (dart.library.io) 'host_server_io.dart' as impl;

// EveryAI as an MCP server for the agents it drives (Claude Code, Codex, …):
// a loopback-only endpoint at `http://127.0.0.1:<port>/mcp` that gives a
// session's agent our own tools (question cards, plan approval, project
// memory, saved plans, checks, run_script). Each session gets its own
// bearer token, which its briefing hands to the agent; the token dies with
// the session.

/// Why a pending call was given up before [HostTools] answered it. The
/// implementation withdraws its card then; a later answer is ignored.
enum HostEnd { timedOut, sessionClosed, clientGone, cancelled }

/// One tool call from a session's agent.
final class HostCall {
  HostCall({required this.id, required this.sessionId, required this.name, required this.args, required this.ended});

  /// Unique for the server's lifetime (not the client's JSON-RPC id).
  final String id;
  final String sessionId;
  final String name;
  final Map<String, Object?> args;

  /// Completes only when the call is abandoned.
  final Future<HostEnd> ended;
}

/// A tool's answer: text for the model, and whether it is an error.
typedef HostResult = ({String text, bool isError});

/// What a session offers through the server; the session controller
/// implements it and dispatches by [HostCall.name] (one of [hostToolSpecs]).
/// The server checks only the token: a call that runs something (bug_check,
/// check) must pass the session's own permission decision first
/// (`hostRunRefusal`), since it runs in the app outside the agent's sandbox.
abstract interface class HostTools {
  Future<HostResult> call(HostCall call);
}

/// Where a session's agent reaches the server, and with what (the
/// briefing's `mcpUrl` and `mcpToken`).
typedef HostToken = ({Uri url, String token});

/// Starts or stops a timer; tests inject one they fire by hand.
typedef HostTimer = Timer Function(Duration after, void Function() fire);

/// The app's one MCP host. It listens only while a token is live.
abstract interface class HostServer {
  /// A new token for [sessionId], whose calls go to [tools]. Binds the
  /// server on first use. With [only], the token sees just those of
  /// [hostToolSpecs] (same order); tools/call refuses the rest.
  Future<HostToken> mint(String sessionId, HostTools tools, {Set<String>? only});

  /// Marks [token] as used now, so it doesn't expire while the session idles
  /// (call it at each turn). False when it already expired: the agent then
  /// needs a new token, and maybe a new URL, so restart it with a fresh mint.
  bool touch(String token);

  /// Ends [token] and its pending calls; the server stops with the last one.
  Future<void> revoke(String token);

  /// [revoke] for every token of [sessionId] (the session closed).
  Future<void> revokeSession(String sessionId);

  /// Ends every token and closes the server.
  Future<void> stop();
}

/// The server: [idleLimit] without use ends a token (the server closes with
/// the last one), [heldLimit] without an
/// answer ends a [heldHostTools] call, and a keep-alive goes out every
/// [keepAlive] while a call waits.
HostServer createHostServer({
  Duration idleLimit = const Duration(hours: 12),
  Duration heldLimit = const Duration(seconds: 300),
  Duration keepAlive = const Duration(seconds: 15),
  DateTime Function()? now,
  HostTimer? timer,
}) => impl.createHostServer(idleLimit: idleLimit, heldLimit: heldLimit, keepAlive: keepAlive, now: now, timer: timer);

/// The tools a session token sees, MCP-shaped, in a fixed order (an agent's
/// prompt cache keeps them). Empty where the server can't run.
List<Map<String, Object?>> get hostToolSpecs => impl.hostToolSpecs;

/// What a workflow agent's token sees: the proof tools and nothing that
/// forks, starts a workflow or asks the user (the lead does that). No memory:
/// they read it in their instructions, and the lead decides what is kept.
const workflowHostTools = {bugCheckTool, checkTool, diffStatsTool, reportIssueTool};

/// The calls that wait for the user, so they get [createHostServer]'s
/// `heldLimit`.
const heldHostTools = {askUserQuestionTool, presentPlanTool};

/// Lists the plans approved in earlier sessions, or returns one.
const savedPlansTool = 'saved_plans';

/// [savedPlansTool]'s spec (MCP shape).
const savedPlansSpec = <String, Object?>{
  'name': savedPlansTool,
  'description':
      'The plans the user approved in earlier sessions of this project (kept in .everyai/plans/). Without a name, '
      'lists them newest first with their titles; with a name from that list, returns that plan in full. Read one '
      'when the task continues earlier work.',
  'inputSchema': {
    'type': 'object',
    'properties': {
      'name': {'type': 'string', 'description': 'A file name from the list, e.g. "2026-11-04-dark-mode.md"'},
    },
    'additionalProperties': false,
  },
  'annotations': {'readOnlyHint': true, 'destructiveHint': false},
};
