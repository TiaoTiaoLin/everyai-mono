// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../code_providers.dart' show everyaiHarnessProvider;
import '../domain/code_session.dart' show everyaiHarnessName;
import 'acp/acp_driver.dart';
import 'claude/claude_driver.dart';
import 'codex/codex_driver.dart';
import 'driver.dart';
import 'everyai_driver.dart';
import 'opencode/opencode_driver.dart';
import 'terminal/terminal_driver.dart';

/// Every harness the app knows, by the name stored with its sessions: the
/// [fixed] ones, plus `acp:<command>` and `terminal:<command>` made on
/// demand.
final class DriverRegistry {
  DriverRegistry(
    this.fixed, {
    HarnessDriver Function(String command)? acp,
    HarnessDriver Function(String command)? terminal,
  }) : _acp = acp ?? ((c) => AcpDriver(id: 'acp:$c', label: c, command: c)),
       _terminal = terminal ?? ((c) => TerminalDriver(id: 'terminal:$c', label: c, command: c));

  final Map<String, HarnessDriver> fixed;
  final HarnessDriver Function(String command) _acp;
  final HarnessDriver Function(String command) _terminal;
  final _made = <String, HarnessDriver>{};

  /// The driver stored as [id], or null when this app doesn't have it.
  HarnessDriver? resolve(String id) {
    if (fixed[id] case final d?) return d;
    for (final (prefix, make) in [('acp:', _acp), ('terminal:', _terminal)]) {
      if (id.startsWith(prefix) && id.length > prefix.length) {
        return _made[id] ??= make(id.substring(prefix.length));
      }
    }
    return null;
  }

  /// The ones offered when a session starts.
  Iterable<HarnessDriver> get listed => fixed.values;
}

/// Every planned driver. All but the EveryAI harness are stubs until their
/// own files are built.
final driverRegistryProvider = Provider<DriverRegistry>(
  (ref) => DriverRegistry({
    everyaiHarnessName: EveryAIDriver(ref.read(everyaiHarnessProvider)),
    'claude-code': ClaudeDriver(),
    'codex': CodexDriver(),
    'opencode': OpenCodeDriver(),
    'gemini': AcpDriver(
      id: 'gemini',
      label: 'Gemini CLI',
      command: 'gemini',
      args: const ['--acp'],
      needsConsent: true,
    ),
  }),
);

/// Whether each listed driver can run here, by id; looked up once and kept
/// (invalidate it to look again). A check that fails shows as its problem.
final driverStatusesProvider = FutureProvider<Map<String, DriverStatus>>((ref) async {
  final drivers = ref.read(driverRegistryProvider).listed.toList();
  final found = await Future.wait([
    for (final d in drivers)
      d.detect().then<DriverStatus>((s) => s, onError: (Object e) => DriverStatus(problem: '$e')),
  ]);
  return {for (final (i, d) in drivers.indexed) d.info.id: found[i]};
});
