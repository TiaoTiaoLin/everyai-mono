// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import '../../harness/events.dart';
import '../../harness/harness.dart';
import '../driver.dart';
import '../driver_process.dart';

/// A coding CLI the app runs in a terminal pane and doesn't read events
/// from (`terminal:<command>`). Not built yet.
final class TerminalDriver implements HarnessDriver {
  TerminalDriver({required this.id, required this.label, required this.command, this.args = const [], this.which});

  final String id;
  final String label;
  final String command;
  final List<String> args;

  /// Replaces the PATH lookup in [detect] (tests).
  final Future<String?> Function(String command)? which;

  @override
  DriverInfo get info => DriverInfo(id: id, label: label);

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
