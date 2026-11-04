// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'host.dart' show HostResult;

bool get hostScriptsAvailable => false;

Future<HostResult> hostRunScript(
  String root,
  String stateDir,
  Map<String, Object?> args, {
  Future<void>? cancel,
}) async => (text: 'Error: scripts run on desktop only.', isError: true);
