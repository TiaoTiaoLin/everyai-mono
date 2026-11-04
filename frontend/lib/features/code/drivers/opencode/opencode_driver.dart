// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import '../../harness/events.dart';
import '../../harness/harness.dart';
import '../driver.dart';
import '../driver_process.dart';

/// OpenCode (`opencode`) through its local server. Not built yet.
final class OpenCodeDriver implements HarnessDriver {
  OpenCodeDriver({this.which});

  /// Replaces the PATH lookup in [detect] (tests).
  final Future<String?> Function(String command)? which;

  @override
  DriverInfo get info => const DriverInfo(id: 'opencode', label: 'OpenCode');

  /// Filled in once its sessions are built.
  @override
  Set<DriverCap> get caps => const {};

  @override
  Future<DriverStatus> detect() => notBuiltYet('opencode', which: which);

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
