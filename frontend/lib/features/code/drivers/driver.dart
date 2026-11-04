// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter/foundation.dart';

import '../harness/harness.dart';

export '../harness/harness.dart' show DriverBriefing;

/// What a harness can do. A cap missing from [HarnessDriver.caps] is
/// unsupported, and the app falls back (see `driver_policy.dart`).
enum DriverCap {
  /// Takes a message into the running turn (`SteersRuns`).
  steer,

  /// Starts a session from another's history (`ForksSessions`).
  fork,

  /// Moves the conversation back to an earlier turn (`rewindTo`).
  rewind,

  /// Reopens a session after the app restarts (`attach`).
  resume,

  /// Runs subagents of its own.
  subagents,

  /// Asks before running actions.
  approvals,

  /// Takes one answer per pending action (`PerCallApprovals`).
  perCallApprovals,

  /// Reports what its model calls cost.
  usage,

  /// Uses the session's MCP servers.
  mcp,

  /// Uses Agent Skills.
  skills,

  /// Reads pictures sent with a message.
  images,

  /// Changes model mid-session (`switchLlm`).
  switchModel,

  /// Takes a reasoning effort.
  effort,
}

/// Who a driver is: [id] is the name stored with its sessions
/// (`CodeSessionInfo.harness`). [needsConsent]: the user agrees to the
/// vendor's terms before the app drives it (a subscription CLI).
@immutable
final class DriverInfo {
  const DriverInfo({required this.id, required this.label, this.needsConsent = false});

  final String id;
  final String label;
  final bool needsConsent;
}

/// Whether a driver can run on this computer: its program was found at
/// [path] with [version], [signedIn] (null: unknown), and what is in the
/// way ([problem], null when nothing is).
@immutable
final class DriverStatus {
  const DriverStatus({this.installed = false, this.path, this.version, this.signedIn, this.problem});

  final bool installed;
  final String? path;
  final String? version;
  final bool? signedIn;
  final String? problem;

  DriverStatus withProblem(String? problem) =>
      DriverStatus(installed: installed, path: path, version: version, signedIn: signedIn, problem: problem);
}

/// A model a driver offers, with the reasoning [efforts] it takes.
@immutable
final class DriverModel {
  const DriverModel({required this.id, required this.label, this.isDefault = false, this.efforts = const []});

  final String id;
  final String label;
  final bool isDefault;
  final List<String> efforts;
}

/// A harness the Code workspace can run sessions on: the EveryAI harness,
/// or a coding CLI the app drives (Claude Code, Codex, OpenCode, ACP agents,
/// a plain terminal).
///
/// Drivers speak the app's [HarnessEvent]s (OpenHands shapes, see
/// `driver_events.dart`), so the transcript, mirror and permissions stay
/// one:
/// - a shell command is a `TerminalAction {command}`, a file edit a
///   `FileEditorAction {command, path}` (or `WriteFileAction`/`EditAction`
///   `{path}`, `ApplyPatchAction {paths}` with every file the patch
///   touches), a read a `ReadFileAction {path}`, `GrepAction` or
///   `GlobAction`, an MCP call an `MCPToolAction`; anything else keeps its
///   own kind and always asks the user, and so does a call missing the
///   field its kind's rules read (`command`, `path`, `paths`). The native tool name goes in
///   `tool_name`, and must not be one of the app's client tool names.
/// - an approval is the call without a result plus a `waiting_for_confirmation`
///   state change; `respond(callIds)` maps back to the native reply. A driver
///   whose refusals don't park the run makes `resume()` a no-op.
/// - what a model call cost is a `UsageReport`.
abstract interface class HarnessDriver implements Harness {
  DriverInfo get info;

  /// What it can do before a session exists. At run time the session's own
  /// markers (`PerCallApprovals`, `SteersRuns`, …) decide.
  Set<DriverCap> get caps;

  Future<DriverStatus> detect();

  /// Its own models; empty when the app's catalog serves it.
  Future<List<DriverModel>> models();
}
