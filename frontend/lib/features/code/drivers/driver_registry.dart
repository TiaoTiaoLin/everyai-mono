// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/preferences.dart';
import '../code_providers.dart' show everyaiHarnessProvider;
import '../domain/code_session.dart' show everyaiHarnessName;
import 'acp/acp_driver.dart';
import 'claude/claude_driver.dart';
import 'codex/codex_driver.dart';
import 'driver.dart';
import 'driver_process.dart' show loadShellEnv, noAnswerProblem, reloadShellEnv;
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
