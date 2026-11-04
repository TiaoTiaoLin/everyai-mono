// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'host.dart';

// Web and mobile never run an outside agent, so there is nothing to host.

List<Map<String, Object?>> get hostToolSpecs => const [];

HostServer createHostServer({
  required Duration idleLimit,
  required Duration heldLimit,
  required Duration keepAlive,
  DateTime Function()? now,
  HostTimer? timer,
}) => const _NoHost();

final class _NoHost implements HostServer {
  const _NoHost();

  @override
  Future<HostToken> mint(String sessionId, HostTools tools) =>
      throw UnsupportedError('EveryAI can host tools on desktop only.');

  @override
  void touch(String token) {}

  @override
  Future<void> revoke(String token) async {}

  @override
  Future<void> revokeSession(String sessionId) async {}

  @override
  Future<void> stop() async {}
}
