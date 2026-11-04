// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'host.dart';

/// The app's MCP host for the agents it drives. It binds on the first
/// token; the OS frees the loopback socket when the app quits.
final hostServerProvider = Provider<HostServer>((ref) {
  final server = createHostServer();
  ref.onDispose(() => unawaited(server.stop()));
  return server;
});
