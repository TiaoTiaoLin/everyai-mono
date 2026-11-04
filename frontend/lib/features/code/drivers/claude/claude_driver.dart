// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import '../../harness/events.dart';
import '../../harness/harness.dart';
import '../driver.dart';
import '../driver_process.dart';

/// Claude Code (`claude`), on the user's own subscription or key. Not built
/// yet.
final class ClaudeDriver implements HarnessDriver {
  ClaudeDriver({this.which});

  /// Replaces the PATH lookup in [detect] (tests).
  final Future<String?> Function(String command)? which;

  @override
  DriverInfo get info => const DriverInfo(id: 'claude-code', label: 'Claude Code', needsConsent: true);

  /// Filled in once its sessions are built.
  @override
  Set<DriverCap> get caps => const {};

  @override
  Future<DriverStatus> detect() => notBuiltYet('claude', which: which);

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
