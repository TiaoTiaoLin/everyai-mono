// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import '../../harness/events.dart';
import '../../harness/harness.dart';
import '../driver.dart';
import '../driver_process.dart';

/// An agent that speaks the Agent Client Protocol over stdio (Gemini CLI,
/// OpenCode's `acp`, any `acp:<command>`): [command] [args] in the
/// session's worktree. Not built yet.
final class AcpDriver implements HarnessDriver {
  AcpDriver({
    required this.id,
    required this.label,
    required this.command,
    this.args = const [],
    this.needsConsent = false,
    this.which,
  });

  final String id;
  final String label;
  final String command;
  final List<String> args;
  final bool needsConsent;

  /// Replaces the PATH lookup in [detect] (tests).
  final Future<String?> Function(String command)? which;

  @override
  DriverInfo get info => DriverInfo(id: id, label: label, needsConsent: needsConsent);

  /// Filled in once its sessions are built.
  @override
  Set<DriverCap> get caps => const {};

  @override
  Future<DriverStatus> detect() => notBuiltYet(command, which: which);

  @override
  Future<List<DriverModel>> models() async => const [];

  @override
  Future<HarnessSession> start(SessionSpec spec) async =>
      throw HarnessError('${info.label} sessions are not built yet.');

  @override
  Future<HarnessSession> attach(String conversationId) async =>
      throw HarnessError('${info.label} sessions are not built yet.');

  @override
  Future<Map<String, ExecutionStatus>> statuses(List<String> conversationIds) async => const {};
}
