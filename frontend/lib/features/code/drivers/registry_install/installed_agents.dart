// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../../../core/preferences.dart';
import '../../git/git_service.dart';
import '../acp/acp_agents.dart';
import '../acp/acp_driver.dart';
import '../driver.dart';
import '../driver_registry.dart';
import 'acp_registry.dart';
import 'registry_install_stub.dart' if (dart.library.io) 'registry_install_io.dart' as impl;

export 'acp_registry.dart' show DistKind, InstallError, RegistryAgent;

/// Preferences key: `{v: 1, agents: {id: InstalledAgent}}`, the agents added
/// from the ACP registry. Each record holds all a start needs, so they run
/// without the registry.
const installedAgentsKey = 'code.acp_installed';

/// The largest download, and the most an archive may unpack to.
const maxAgentDownload = 1024 * 1024 * 1024;
const maxAgentUnpacked = 2 * 1024 * 1024 * 1024;

/// One agent added from the registry.
@immutable
final class InstalledAgent {
  const InstalledAgent({
    required this.id,
    required this.name,
    required this.version,
    required this.kind,
    this.description = '',
    this.exe,
    this.package,
    this.home,
    this.args = const [],
    this.env = const {},
    this.sha256Checked = false,
  });

  /// The registry id (the driver is `registry:<id>`).
  final String id;
  final String name;
  final String version;
  final DistKind kind;
  final String description;

  /// The downloaded program's absolute path ([DistKind.binary]).
  final String? exe;

  /// The pinned package spec ([DistKind.npx], [DistKind.uvx]).
  final String? package;

  /// The app's own folder for it (`agents/<id>`), where an npx or uvx
  /// agent's runner starts from instead of the project, so a repo's own
  /// `.npmrc`, `node_modules` or uv config can't pick what runs.
  final String? home;
  final List<String> args;
  final Map<String, String> env;

  /// Whether the download matched a checksum the registry gave.
  final bool sha256Checked;

  /// Its driver's id.
  String get driverId => 'registry:$id';

  Map<String, Object?> toJson() => {
    'name': name,
    'description': description,
    'version': version,
    'kind': kind.name,
    'exe': ?exe,
    'package': ?package,
    'home': ?home,
    'args': args,
    'env': env,
    'sha256Checked': sha256Checked,
  };

  static InstalledAgent? fromJson(String id, Object? json) {
    if (json case {'name': final String name, 'version': final String version, 'kind': final String kind}
        when DistKind.values.any((k) => k.name == kind)) {
      final m = json as Map<String, Object?>;
      // A runner agent needs its own folder to start from (records made
      // before it had one are added again).
      if (kind != DistKind.binary.name && m['home'] is! String) return null;
      return InstalledAgent(
        id: id,
        name: name,
        version: version,
        kind: DistKind.values.byName(kind),
        description: m['description'] as String? ?? '',
        exe: m['exe'] as String?,
        package: m['package'] as String?,
        home: m['home'] as String?,
        args: [...?(m['args'] as List<Object?>?)?.whereType<String>()],
        env: {
          for (final MapEntry(:key, :value) in ((m['env'] as Map<String, Object?>?) ?? const {}).entries)
            if (value is String) key: value,
        },
        sha256Checked: m['sha256Checked'] == true,
      );
    }
    return null;
  }
}

/// The stored agents, by registry id; none when the record can't be read.
Map<String, InstalledAgent> readInstalledAgents(Preferences prefs) {
  final raw = prefs[installedAgentsKey];
  if (raw == null) return const {};
  try {
    if (jsonDecode(raw) case {'v': 1, 'agents': final Map<String, Object?> all}) {
      return {for (final MapEntry(:key, :value) in all.entries) key: ?InstalledAgent.fromJson(key, value)};
    }
  } on Object {
    // Read as none.
  }
  return const {};
}

void _writeInstalledAgents(Preferences prefs, Map<String, InstalledAgent> agents) =>
    prefs[installedAgentsKey] = jsonEncode({
      'v': 1,
      'agents': {for (final a in agents.values) a.id: a.toJson()},
    });

/// [agents] as the driver layer [DriverRegistry.setInstalled] takes.
Map<String, ({Object key, HarnessDriver Function() make})> installedDrivers(
  Map<String, InstalledAgent> agents,
  Map<String, HarnessDriver> fixed,
) => {for (final a in agents.values) a.driverId: (key: jsonEncode(a.toJson()), make: () => registryDriver(a, fixed))};

/// The ACP driver for [agent]. When the app lists the same agent already
/// ([fixed], by registry id or [registryAliases]), it runs with that
/// entry's profile and on that entry's consent switch. Otherwise it gets the
/// profile its program's name picks (the generic one for an unknown agent),
/// and an unknown agent needs the user's consent.
AcpDriver registryDriver(
  InstalledAgent agent,
  Map<String, HarnessDriver> fixed, {
  @visibleForTesting Future<String?> Function(String command)? which,
  @visibleForTesting Future<Map<String, String>> Function()? loginEnv,
  @visibleForTesting AcpConnect? connect,
}) {
  final listedId = registryAliases[agent.id] ?? agent.id;
  final listed = fixed[listedId];
  final AcpProfile profile;
  final bool consent;
  if (listed is AcpDriver) {
    profile = listed.resolved.profile;
    consent = listed.info.needsConsent;
  } else {
    profile = acpProfileOf(agent.exe ?? '');
    consent = !profile.known;
  }
  final runner = agent.kind != DistKind.binary;
  return AcpDriver(
    id: agent.driverId,
    label: agent.name,
    command: switch (agent.kind) {
      DistKind.binary => agent.exe ?? '',
      DistKind.npx => 'npx',
      DistKind.uvx => 'uvx',
    },
    args: agent.args,
    // `--prefix` makes npm read its project config and local packages from
    // the agent's own folder, not the project the session runs in;
    // `--no-config` keeps uv off the project's uv.toml and pyproject.toml.
    prefix: switch (agent.kind) {
      DistKind.binary => const [],
      DistKind.npx => ['--prefix', ?agent.home, '-y', ?agent.package],
      DistKind.uvx => ['--no-config', ?agent.package],
    },
    profile: profile.withEnv(agent.env),
    knownVersion: agent.version,
    needsConsent: consent,
    consentId: listed is AcpDriver ? listedId : null,
    which: which,
    loginEnv: loginEnv,
    connect: connect,
    // The first start fetches the package.
    initTimeout: runner ? const Duration(minutes: 5) : const Duration(seconds: 60),
  );
}

/// Downloads and removes registry agents. Nothing it fetches runs while it
/// installs; npx and uvx agents aren't fetched at all (their runner does that
/// the first time a session starts).
final class AgentInstaller {
  AgentInstaller({
    http.Client? client,
    Future<String> Function()? dataDir,
    String? Function()? platform,
    Future<void> Function(String path)? makeExecutable,
    Future<void> Function(String path)? makeDir,
    this.maxDownload = maxAgentDownload,
    this.maxUnpacked = maxAgentUnpacked,
  }) : _client = client ?? http.Client(),
       _dataDir = dataDir ?? GitService.dataDir,
       _platform = platform ?? impl.currentPlatformKey,
       _makeExecutable = makeExecutable ?? impl.chmodExecutable,
       _makeDir = makeDir ?? impl.makeDir;

  final http.Client _client;
  final Future<String> Function() _dataDir;
  final String? Function() _platform;
  final Future<void> Function(String path) _makeExecutable;
  final Future<void> Function(String path) _makeDir;
  final int maxDownload;
  final int maxUnpacked;

  /// How [agent] would reach this computer, or null when it can't.
  Distribution? distributionOf(RegistryAgent agent) => pickDistribution(agent, _platform());

  Future<String> _root() async => '${await _dataDir()}/agents';

  /// Installs [agent]: a download is fetched into `agents/<id>/<version>/`
  /// and checked against the registry's checksum, refused without one
  /// unless [allowUnchecked]; an npx or uvx agent is only recorded.
  Future<InstalledAgent> install(RegistryAgent agent, {bool allowUnchecked = false}) async {
    final d = distributionOf(agent);
    if (d == null) throw InstallError("${agent.name} doesn't run on this computer.");
    final base = (id: agent.id, name: agent.name, version: agent.version, description: agent.description);
    switch (d) {
      case Distribution(:final binary?):
        if (binary.sha256 == null && !allowUnchecked) {
          throw InstallError("${agent.name}'s download has no published checksum.");
        }
        final exe = await impl.installBinary(
          root: await _root(),
          id: agent.id,
          version: agent.version,
          target: binary,
          client: _client,
          makeExecutable: _makeExecutable,
          maxDownload: maxDownload,
          maxUnpacked: maxUnpacked,
        );
        return InstalledAgent(
          id: base.id,
          name: base.name,
          version: base.version,
          description: base.description,
          kind: DistKind.binary,
          exe: exe,
          args: binary.args,
          env: binary.env,
          sha256Checked: binary.sha256 != null,
        );
      case Distribution(:final kind, :final run?):
        final home = '${await _root()}/${agent.id}';
        await _makeDir(home);
        return InstalledAgent(
          id: base.id,
          name: base.name,
          version: base.version,
          description: base.description,
          kind: kind,
          package: run.package,
          home: home,
          args: run.args,
          env: run.env,
        );
      default:
        throw StateError('unreachable');
    }
  }

  /// Makes [agent]'s own folder again (after [remove] took a download).
  Future<void> makeHome(InstalledAgent agent) async {
    if (agent.home case final home?) await _makeDir(home);
  }

  /// Deletes `agents/<id>/`.
  Future<void> remove(String id) async => impl.removeAgentFiles(await _root(), id);
}

/// The installer (tests replace it).
final agentInstallerProvider = Provider<AgentInstaller>((ref) => AgentInstaller());

/// The registry client (tests replace it).
final acpRegistryClientProvider = Provider<AcpRegistryClient>(
  (ref) => AcpRegistryClient(ref.read(preferencesProvider)),
);

/// The registry's agents, fetched when the kept copy is over an hour old.
/// Dropped when the list closes, so opening it again reads it again.
final acpRegistryProvider = FutureProvider.autoDispose<RegistryList>(
  (ref) => ref.read(acpRegistryClientProvider).load(),
);

/// Runs after an agent is added, updated or removed: the harness check of
/// that driver alone, so Start Session offers it (tests replace it).
final rescanHarnessesProvider = Provider<void Function(String driverId)>(
  (ref) =>
      (id) => unawaited(ref.read(driverStatusesProvider.notifier).recheck(id)),
);

/// The registry ids an install, update or remove is running for.
final agentsInFlightProvider = NotifierProvider<AgentsInFlight, Set<String>>(AgentsInFlight.new);

final class AgentsInFlight extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  /// Marks [id] as being worked on; false when it already is.
  bool claim(String id) {
    if (state.contains(id)) return false;
    state = {...state, id};
    return true;
  }

  void release(String id) => state = {...state}..remove(id);
}

/// The agents added from the ACP registry, by registry id.
final installedAgentsProvider = NotifierProvider<InstalledAgents, Map<String, InstalledAgent>>(InstalledAgents.new);

final class InstalledAgents extends Notifier<Map<String, InstalledAgent>> {
  @override
  Map<String, InstalledAgent> build() => readInstalledAgents(ref.read(preferencesProvider));

  /// Installs [agent], or updates it to the registry's version.
  Future<void> install(RegistryAgent agent, {bool allowUnchecked = false}) => _alone(agent.id, () async {
    final rec = await ref.read(agentInstallerProvider).install(agent, allowUnchecked: allowUnchecked);
    // A binary that became an npx agent leaves no download behind.
    if (state[agent.id]?.kind == DistKind.binary && rec.kind != DistKind.binary) {
      await ref.read(agentInstallerProvider).remove(agent.id);
      await ref.read(agentInstallerProvider).makeHome(rec);
    }
    _save({...state, agent.id: rec}, agent.id);
  });

  /// Removes [id]'s files and record.
  Future<void> remove(String id) => _alone(id, () async {
    await ref.read(agentInstallerProvider).remove(id);
    _save({...state}..remove(id), id);
  });

  /// Runs [action] for [id] unless a session of it is open or another
  /// install, update or remove of it is still running.
  Future<void> _alone(String id, Future<void> Function() action) async {
    if (busy(id)) throw InstallError('Close its sessions first.');
    final flight = ref.read(agentsInFlightProvider.notifier);
    if (!flight.claim(id)) throw InstallError('This agent is already being installed or removed.');
    try {
      await action();
    } finally {
      if (ref.mounted) flight.release(id);
    }
  }

  /// Whether a session of [id] is open in this app run.
  bool busy(String id) => switch (ref.read(driverRegistryProvider).resolve('registry:$id')) {
    final AcpDriver d => d.busy,
    _ => false,
  };

  void _save(Map<String, InstalledAgent> next, String id) {
    state = next;
    _writeInstalledAgents(ref.read(preferencesProvider), next);
    final registry = ref.read(driverRegistryProvider);
    registry.setInstalled(installedDrivers(next, registry.fixed));
    ref.read(rescanHarnessesProvider)('registry:$id');
  }
}
