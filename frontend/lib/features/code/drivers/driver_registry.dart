// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/preferences.dart';
import '../code_providers.dart' show everyaiHarnessProvider;
import '../domain/code_session.dart' show everyaiHarnessName;
import 'acp/acp_agents.dart' show acpCommand;
import 'acp/acp_driver.dart';
import 'claude/claude_driver.dart';
import 'codex/codex_driver.dart';
import 'driver.dart';
import 'driver_process.dart' show loadShellEnv, noAnswerProblem, reloadShellEnv;
import 'everyai_driver.dart';
import 'opencode/opencode_driver.dart';
import 'registry_install/installed_agents.dart' show installedDrivers, readInstalledAgents;
import 'terminal/terminal_driver.dart';

/// Every harness the app knows, by the name stored with its sessions: the
/// [fixed] ones, the agents added from the ACP registry ([installed],
/// `registry:<id>`), plus `acp:<command>` and `terminal:<command>` made on
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

  /// The agents added from the ACP registry, by id; see [setInstalled].
  Map<String, HarnessDriver> get installed => Map.unmodifiable(_installed);
  var _installed = <String, HarnessDriver>{};
  var _installedKeys = <String, Object>{};

  /// Replaces [installed] with [drivers], each with a [key] for what it was
  /// made from. One whose key didn't change keeps its old instance, so its
  /// open sessions stay where they are.
  void setInstalled(Map<String, ({Object key, HarnessDriver Function() make})> drivers) {
    final next = <String, HarnessDriver>{};
    for (final MapEntry(key: id, value: (:key, :make)) in drivers.entries) {
      next[id] = _installedKeys[id] == key ? _installed[id]! : make();
    }
    _installed = next;
    _installedKeys = {for (final e in drivers.entries) e.key: e.value.key};
  }

  /// The driver stored as [id], or null when this app doesn't have it.
  HarnessDriver? resolve(String id) {
    if (fixed[id] case final d?) return d;
    if (_installed[id] case final d?) return d;
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
  Iterable<HarnessDriver> get listed => [...fixed.values, ..._installed.values];
}

/// Every planned driver. All but the EveryAI harness are stubs until their
/// own files are built.
final driverRegistryProvider = Provider<DriverRegistry>((ref) {
  final registry = DriverRegistry({
    everyaiHarnessName: EveryAIDriver(ref.read(everyaiHarnessProvider)),
    'claude-code': ClaudeDriver(),
    'codex': CodexDriver(),
    'opencode': OpenCodeDriver(),
    // ACP agents, by their ACP registry ids (cdn.agentclientprotocol.com
    // registry v1), so a registry-driven list can take these as overrides.
    // Whether one needs the user's consent comes from its profile.
    for (final (id, label, command, hint) in _acpAgents)
      id: AcpDriver(id: id, label: label, command: command, installHint: hint),
  });
  // Read here, so the first check and its kept copy already list them.
  return registry..setInstalled(installedDrivers(readInstalledAgents(ref.read(preferencesProvider)), registry.fixed));
});

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
  // The install line from x.ai/news/grok-build-cli.
  ('grok', 'Grok Build', 'grok', 'curl -fsSL https://x.ai/cli/install.sh | bash'),
];

/// Whether each listed driver can run here, by id. The last check is kept
/// in Preferences ([harnessStatusesKey]), so a launch shows it at once and
/// looks again in the background; [DriverStatuses.refresh] looks again (the
/// shell starts the first check after the first frame, on desktop).
final driverStatusesProvider = AsyncNotifierProvider<DriverStatuses, Map<String, DriverStatus>>(DriverStatuses.new);

/// Preferences key: `{v: 1, checkedAt, statuses: {id: DriverStatus}}`.
const harnessStatusesKey = 'code.harnesses';

final class DriverStatuses extends AsyncNotifier<Map<String, DriverStatus>> {
  DriverStatuses({
    this.timeout = const Duration(seconds: 30),
    this.concurrency = 4,
    Future<void> Function()? loadShell,
    Future<void> Function()? reloadShell,
  }) : _loadShell = loadShell ?? loadShellEnv,
       _reloadShell = reloadShell ?? reloadShellEnv;

  /// How long one driver's check may take: above the longest a driver's
  /// own steps wait in a row (Codex: `--version` 4 s, then two 10 s
  /// requests), so only a check that truly hangs runs out.
  final Duration timeout;

  /// How many drivers are checked at once. A check that ran out keeps its
  /// slot (its processes may still run) for up to another [timeout].
  final int concurrency;
  final Future<void> Function() _loadShell;
  final Future<void> Function() _reloadShell;

  /// When the last check finished; null before the first.
  DateTime? get checkedAt => _checkedAt;
  DateTime? _checkedAt;
  Future<Map<String, DriverStatus>>? _inFlight;
  bool _inFlightReloads = false;
  Map<String, DriverStatus> _last = const {};

  @override
  FutureOr<Map<String, DriverStatus>> build() {
    final cached = _readCache();
    if (cached == null) return _scan(reloadShell: false);
    Future.microtask(() {
      if (ref.mounted) unawaited(refresh());
    });
    return cached;
  }

  /// Checks every driver again ([reloadShell]: reads the login shell's PATH
  /// again first, for something installed since). One check runs at a time;
  /// a second call shares it, unless it asks for a reload the running one
  /// didn't do: then it runs one more check after it.
  Future<Map<String, DriverStatus>> refresh({bool reloadShell = false}) async {
    final found = await _scan(reloadShell: reloadShell);
    if (ref.mounted) state = AsyncData(found);
    return found;
  }

  /// [refresh] when the last check is older than [age] (the app came back
  /// to the front).
  Future<void> refreshIfStale({Duration age = const Duration(minutes: 10)}) async {
    if (_inFlight == null && (_checkedAt == null || DateTime.now().difference(_checkedAt!) >= age)) await refresh();
  }

  Future<Map<String, DriverStatus>> _scan({required bool reloadShell}) {
    final running = _inFlight;
    if (running != null && (_inFlightReloads || !reloadShell)) return running;
    _inFlightReloads = reloadShell;
    late final Future<Map<String, DriverStatus>> mine;
    mine = (running == null ? _check(reloadShell) : running.then((_) => _check(true), onError: (_) => _check(true)))
        .whenComplete(() {
          if (identical(_inFlight, mine)) _inFlight = null;
        });
    return _inFlight = mine;
  }

  Future<Map<String, DriverStatus>> _check(bool reloadShell) async {
    // Before any driver's clock starts, so a slow rc file costs none of them time.
    await (reloadShell ? _reloadShell() : _loadShell()).then((_) {}, onError: (_) {});
    final drivers = ref.read(driverRegistryProvider).listed.toList();
    final previous = _last;
    final found = [for (final _ in drivers) Completer<DriverStatus>()];
    var next = 0;
    Future<void> worker() async {
      while (next < drivers.length) {
        final i = next++;
        final d = drivers[i];
        // Out of time: what was known stays as it was; nothing known reads
        // as not installed, so a harness is never offered on a guess.
        final timer = Timer(timeout, () => found[i].complete(previous[d.info.id] ?? _noAnswer));
        final settled = _detect(d)
            .then<DriverStatus>((s) => s, onError: (Object e) => DriverStatus(problem: "Couldn't check: $e"));
        // The slot is free when the check settles (or one more [timeout]
        // after it ran out), so a hung check can't hold the rest back.
        final s = await settled.timeout(timeout * 2, onTimeout: () => _noAnswer);
        timer.cancel();
        if (!found[i].isCompleted) found[i].complete(s);
      }
    }

    unawaited(Future.wait([for (var w = 0; w < concurrency && w < drivers.length; w++) worker()]));
    final results = await Future.wait([for (final f in found) f.future]);
    final out = {for (final (i, d) in drivers.indexed) d.info.id: results[i]};
    _last = out;
    _checkedAt = DateTime.now();
    if (ref.mounted) {
      ref.read(preferencesProvider)[harnessStatusesKey] = jsonEncode({
        'v': 1,
        'checkedAt': _checkedAt!.toIso8601String(),
        'statuses': {for (final e in out.entries) e.key: e.value.toJson()},
      });
    }
    return out;
  }

  static const _noAnswer = DriverStatus(problem: noAnswerProblem);

  // Typed, since a driver's future may be a Future<Never> (it throws), and a
  // sync throw becomes an error like an async one.
  static Future<DriverStatus> _detect(HarnessDriver d) async => await d.detect();

  /// The kept check, without drivers this version no longer lists; null
  /// when there is none (or it can't be read).
  Map<String, DriverStatus>? _readCache() {
    final raw = ref.read(preferencesProvider)[harnessStatusesKey];
    if (raw == null) return null;
    try {
      if (jsonDecode(raw) case {'v': 1, 'checkedAt': final String at, 'statuses': final Map<String, Object?> all}) {
        final ids = {for (final d in ref.read(driverRegistryProvider).listed) d.info.id};
        _checkedAt = DateTime.tryParse(at);
        return _last = {
          for (final MapEntry(:key, :value) in all.entries)
            if (ids.contains(key) && value is Map<String, Object?>) key: DriverStatus.fromJson(value),
        };
      }
    } on Object {
      // Read as no check.
    }
    return null;
  }
}
