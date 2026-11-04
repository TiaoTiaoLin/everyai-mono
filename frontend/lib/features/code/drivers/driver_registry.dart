// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../code_providers.dart' show everyaiHarnessProvider;
import '../domain/code_session.dart' show everyaiHarnessName;
import 'acp/acp_agents.dart' show acpCommand;
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
  }) : _acp = acp ?? ((c) => AcpDriver(id: 'acp:$c', label: c, command: c, consentId: _listedFor(fixed, c))),
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

  /// The id of the listed ACP driver that runs the same program as
  /// [command] (by any of its names), whose consent an `acp:<command>` shares.
  static String? _listedFor(Map<String, HarnessDriver> fixed, String command) {
    final exe = acpCommand(command, const []).executable.split('/').last;
    return [
      for (final MapEntry(:key, :value) in fixed.entries)
        if (value is AcpDriver &&
            {value.resolved.executable.split('/').last, ...value.resolved.profile.alsoNamed}.contains(exe))
          key,
    ].firstOrNull;
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
    // ACP agents, by their ACP registry ids (cdn.agentclientprotocol.com
    // registry v1), so a registry-driven list can take these as overrides.
    // Whether one needs the user's consent comes from its profile.
    for (final (id, label, command, hint) in _acpAgents)
      id: AcpDriver(id: id, label: label, command: command, installHint: hint),
  }),
);

/// The ACP agents listed by default: id, label, command, install hint. Each
/// command's profile (`acp/acp_agents.dart`) pins its ACP arguments.
const _acpAgents = [
  ('antigravity', 'Antigravity CLI', 'agy', 'curl -fsSL https://antigravity.google/cli/install.sh | bash'),
  ('gemini', 'Gemini CLI (API key or enterprise)', 'gemini', 'npm i -g @google/gemini-cli'),
  ('github-copilot-cli', 'GitHub Copilot CLI', 'copilot', 'npm i -g @github/copilot'),
  ('kiro', 'Kiro CLI', 'kiro-cli', 'curl -fsSL https://cli.kiro.dev/install | bash'),
  ('kimi', 'Kimi Code CLI', 'kimi', 'curl -fsSL https://code.kimi.com/kimi-code/install.sh | bash'),
  ('qwen-code', 'Qwen Code', 'qwen', 'npm i -g @qwen-code/qwen-code'),
  ('cline', 'Cline CLI', 'cline', 'npm i -g cline'),
  ('goose', 'goose', 'goose', 'brew install block-goose-cli'),
  ('mistral-vibe', 'Mistral Vibe', 'vibe-acp', 'uv tool install mistral-vibe'),
  ('auggie', 'Auggie', 'auggie', 'npm i -g @augmentcode/auggie'),
  ('factory-droid', 'Factory Droid', 'droid', 'npm i -g droid'),
  ('cursor', 'Cursor CLI', 'cursor-agent', 'curl https://cursor.com/install -fsS | bash'),
];

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
