// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import '../domain/code_session.dart' show everyaiHarnessName;
import '../harness/events.dart';
import '../harness/everyai/everyai.dart' show forkSession;
import '../harness/harness.dart';
import 'driver.dart';

/// The EveryAI harness as a driver: the agent loop in the app. It forwards
/// to [inner] (`everyaiHarnessProvider`'s harness).
final class EveryAIDriver implements HarnessDriver, ForksSessions, AttachesBriefed, AttachesWithMcp {
  EveryAIDriver(this.inner);

  final Harness inner;

  static const _info = DriverInfo(id: everyaiHarnessName, label: 'EveryAI');

  /// What an `EveryAISession` implements (a test checks the markers). No
  /// steer: a message mid-run interrupts and is sent again.
  static const _caps = {
    DriverCap.rewind,
    DriverCap.resume,
    DriverCap.subagents,
    DriverCap.approvals,
    DriverCap.perCallApprovals,
    DriverCap.usage,
    DriverCap.mcp,
    DriverCap.skills,
    DriverCap.images,
    DriverCap.switchModel,
    DriverCap.effort,
  };

  @override
  DriverInfo get info => _info;

  @override
  Set<DriverCap> get caps => {..._caps, if (inner is ForksSessions) DriverCap.fork};

  @override
  Future<DriverStatus> detect() async => const DriverStatus(installed: true);

  /// The app's model catalog serves it.
  @override
  Future<List<DriverModel>> models() async => const [];

  @override
  Future<HarnessSession> start(SessionSpec spec) => inner.start(spec);

  @override
  Future<HarnessSession> fork(String parentConversationId, SessionSpec spec) =>
      forkSession(inner, parentConversationId, spec) ?? inner.start(spec);

  @override
  Future<HarnessSession> attach(String conversationId) => inner.attach(conversationId);

  @override
  Future<HarnessSession> attachWithMcp(String conversationId, Map<String, Object?> mcpConfig) =>
      inner is AttachesWithMcp
      ? (inner as AttachesWithMcp).attachWithMcp(conversationId, mcpConfig)
      : inner.attach(conversationId);

  /// A workflow agent reopened with a fresh host. Without the harness's own
  /// support (the web) it can't reach the host, so it isn't given one.
  @override
  Future<HarnessSession> attachBriefed(
    String conversationId,
    DriverBriefing briefing, {
    Map<String, Object?> mcpConfig = const {},
  }) => inner is AttachesBriefed
      ? (inner as AttachesBriefed).attachBriefed(conversationId, briefing, mcpConfig: mcpConfig)
      : throw const HarnessError("this harness can't reach EveryAI's tools");

  @override
  Future<Map<String, ExecutionStatus>> statuses(List<String> conversationIds) => inner.statuses(conversationIds);
}
