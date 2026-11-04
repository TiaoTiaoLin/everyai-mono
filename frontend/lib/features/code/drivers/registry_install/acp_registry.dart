// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../../../core/preferences.dart';

// The ACP registry (agentclientprotocol.com; format in the registry repo's
// FORMAT.md and agent.schema.json): the agents the app can add, and how each
// one is fetched or run on this computer. Pure, so it builds on the web.
//
// The checks are ported from T3 Code (MIT),
// packages/provider-acp-registry/src/server/AcpRegistrySupport.ts: https
// only, pinned npx/uvx packages, safe command paths, bounded fields, a 1 MiB
// index and the windows-aarch64 fallback.

/// Where the registry's index is published.
const acpRegistryUrl = 'https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json';

/// Preferences key: `{v: 1, fetchedAt, json}`, the last index fetched.
const acpRegistryCacheKey = 'code.acp_registry';

/// The largest index read.
const maxRegistryBytes = 1024 * 1024;

/// How an agent reaches this computer.
enum DistKind {
  /// An archive (or a bare program) downloaded into the app's folder.
  binary,

  /// `npx -y <package>`: Node.js fetches it the first time it starts.
  npx,

  /// `uvx <package>`: uv fetches it the first time it starts.
  uvx;

  /// In plain words, for the list.
  String get label => switch (this) {
    binary => 'Download',
    npx => 'Runs with npx',
    uvx => 'Runs with uvx',
  };
}

/// One platform's download.
@immutable
final class BinaryTarget {
  const BinaryTarget({
    required this.archive,
    required this.cmd,
    this.sha256,
    this.args = const [],
    this.env = const {},
  });

  final String archive;

  /// The SHA-256 the registry gives for [archive] (lower case), or null: the
  /// format leaves it optional.
  final String? sha256;

  /// The program inside the archive, relative and normalized (`bin/agent`).
  final String cmd;
  final List<String> args;
  final Map<String, String> env;
}

/// An npx or uvx launch: the pinned [package] spec as the registry gives it.
@immutable
final class PackageRun {
  const PackageRun({required this.package, this.args = const [], this.env = const {}});

  final String package;
  final List<String> args;
  final Map<String, String> env;
}

/// One registry entry, as far as the app uses it.
@immutable
final class RegistryAgent {
  const RegistryAgent({
    required this.id,
    required this.name,
    required this.version,
    this.description = '',
    this.license,
    this.website,
    this.binary = const {},
    this.npx,
    this.uvx,
  });

  final String id;
  final String name;
  final String version;
  final String description;
  final String? license;
  final String? website;

  /// Downloads by platform key (`darwin-aarch64`).
  final Map<String, BinaryTarget> binary;
  final PackageRun? npx;
  final PackageRun? uvx;
}

/// How one agent runs on one platform ([pickDistribution]).
@immutable
final class Distribution {
  const Distribution.binary(BinaryTarget this.binary) : kind = DistKind.binary, run = null;
  const Distribution.package(this.kind, PackageRun this.run) : binary = null;

  final DistKind kind;
  final BinaryTarget? binary;
  final PackageRun? run;

  List<String> get args => binary?.args ?? run!.args;
  Map<String, String> get env => binary?.env ?? run!.env;
}

/// The registry's platform key for an OS (`macos`, `linux`, `windows`, as
/// `Platform.operatingSystem` names them) and a CPU (`arm64`, `x64`), or
/// null for one it has no builds for.
String? platformKey(String os, String cpu) {
  final o = switch (os) {
    'macos' => 'darwin',
    'linux' => 'linux',
    'windows' => 'windows',
    _ => null,
  };
  final a = switch (cpu) {
    'arm64' => 'aarch64',
    'x64' => 'x86_64',
    _ => null,
  };
  return o == null || a == null ? null : '$o-$a';
}

/// [agent]'s way onto [platform]: its download, else npx, else uvx; null when
/// it has none. Windows on ARM takes an x86_64 download (it emulates one).
Distribution? pickDistribution(RegistryAgent agent, String? platform) {
  for (final key in [?platform, if (platform == 'windows-aarch64') 'windows-x86_64']) {
    if (agent.binary[key] case final t?) return Distribution.binary(t);
  }
  if (agent.npx case final r?) return Distribution.package(DistKind.npx, r);
  if (agent.uvx case final r?) return Distribution.package(DistKind.uvx, r);
  return null;
}

/// The agents in a registry index. An entry that breaks a rule is left out
/// (the others stay); a body over [maxRegistryBytes] or one that isn't an
/// index throws a [FormatException].
List<RegistryAgent> parseRegistry(String body) {
  if (utf8.encode(body).length > maxRegistryBytes) throw const FormatException('The agent list is too large.');
  final json = jsonDecode(body);
  if (json case {'agents': final List<Object?> agents}) {
    return [for (final a in agents.take(500)) ?_agent(a)];
  }
  throw const FormatException("This isn't an agent list.");
}

final _id = RegExp(r'^[a-z0-9][a-z0-9._-]{0,127}$');
// Versions become folder names, so `.` and `..` never pass.
final _version = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$');
const _exact = r'v?[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?';
final _npxPackage = RegExp('^(?:@[^/@\\s]+/[^@\\s]+|[a-z0-9][a-z0-9._-]*)@$_exact\$', caseSensitive: false);
final _uvxPackage = RegExp('^[a-z0-9][a-z0-9._-]*(?:@|==)$_exact\$', caseSensitive: false);
final _sha = RegExp(r'^[a-f0-9]{64}$', caseSensitive: false);
final _envName = RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,255}$');

/// Thrown inside the parser for an entry that breaks a rule.
final class _Bad implements Exception {}

RegistryAgent? _agent(Object? raw) {
  if (raw is! Map<String, Object?>) return null;
  try {
    final dist = raw['distribution'];
    if (dist is! Map<String, Object?>) throw _Bad();
    final binary = <String, BinaryTarget>{};
    if (dist['binary'] case final Object b) {
      if (b is! Map<String, Object?>) throw _Bad();
      for (final MapEntry(:key, :value) in b.entries) {
        if (value is! Map<String, Object?>) throw _Bad();
        final sha = value['sha256'];
        if (sha != null && (sha is! String || !_sha.hasMatch(sha))) throw _Bad();
        binary[key] = BinaryTarget(
          archive: _https(value['archive']) ?? (throw _Bad()),
          sha256: (sha as String?)?.toLowerCase(),
          cmd: normalizeCommandPath(_string(value['cmd'], 1024)) ?? (throw _Bad()),
          args: _args(value['args']),
          env: _env(value['env']),
        );
      }
    }
    final npx = _run(dist['npx'], _npxPackage);
    final uvx = _run(dist['uvx'], _uvxPackage);
    if (binary.isEmpty && npx == null && uvx == null) throw _Bad();
    final id = _string(raw['id'], 128);
    final version = _string(raw['version'], 128).trim();
    final name = _string(raw['name'], 160).trim();
    if (!_id.hasMatch(id) || !_version.hasMatch(version) || name.isEmpty) throw _Bad();
    return RegistryAgent(
      id: id,
      name: name,
      version: version,
      description: raw['description'] == null ? '' : _string(raw['description'], 1024),
      license: raw['license'] == null ? null : _string(raw['license'], 256),
      website: _https(raw['website']) ?? _https(raw['repository']),
      binary: binary,
      npx: npx,
      uvx: uvx,
    );
  } on _Bad {
    return null;
  }
}

String _string(Object? v, int max) => v is String && v.length <= max ? v : throw _Bad();

/// [v] when it is an https URL without credentials, else null.
String? _https(Object? v) {
  if (v is! String || v.length > 2048) return null;
  final u = Uri.tryParse(v);
  return u != null && u.scheme == 'https' && u.host.isNotEmpty && u.userInfo.isEmpty ? v : null;
}

List<String> _args(Object? v) => switch (v) {
  null => const [],
  final List<Object?> l when l.length <= 64 => [for (final a in l) _string(a, 1024)],
  _ => throw _Bad(),
};

Map<String, String> _env(Object? v) => switch (v) {
  null => const {},
  final Map<String, Object?> m when m.length <= 64 && m.keys.every(_envName.hasMatch) => {
    for (final MapEntry(:key, :value) in m.entries) key: _string(value, 1024),
  },
  _ => throw _Bad(),
};

PackageRun? _run(Object? v, RegExp pinned) {
  if (v == null) return null;
  if (v case {'package': final String package} when package.length <= 256 && pinned.hasMatch(package)) {
    return PackageRun(package: package, args: _args(v['args']), env: _env(v['env']));
  }
  throw _Bad();
}

/// [command] as a path inside the agent's folder (`./dist\agent.cmd` →
/// `dist/agent.cmd`), or null when it would leave it: absolute, a drive
/// letter, or a `.`/`..` part.
String? normalizeCommandPath(String command) {
  final n = command.trim().replaceAll(r'\', '/').replaceFirst(RegExp(r'^\./'), '');
  final parts = n.split('/').where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty ||
      n.startsWith('/') ||
      RegExp(r'^[A-Za-z]:').hasMatch(n) ||
      parts.any((p) => p == '.' || p == '..')) {
    return null;
  }
  return parts.join('/');
}

/// Why an install or removal didn't happen, in plain words.
/// How long a download may go without a byte before it is given up.
const downloadIdleTimeout = Duration(seconds: 60);

final class InstallError implements Exception {
  const InstallError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Whether an archive entry [name] (with [link], its link target, taken
/// from the entry's own folder as package:archive gives hard links too)
/// would land outside the folder it is unpacked in.
bool leavesFolder(String name, String? link) {
  bool outside(String path) {
    final n = path.replaceAll(r'\', '/');
    if (n.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(n)) return true;
    var depth = 0;
    for (final part in n.split('/')) {
      if (part == '..') {
        if (--depth < 0) return true;
      } else if (part.isNotEmpty && part != '.') {
        depth++;
      }
    }
    return false;
  }

  if (outside(name) || name.replaceAll(r'\', '/').split('/').contains('..')) return true;
  if (link == null || link.isEmpty) return false;
  final l = link.replaceAll(r'\', '/');
  if (l.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(l)) return true;
  final dir = name.replaceAll(r'\', '/').split('/')..removeLast();
  return outside([...dir, l].join('/'));
}

/// The registry's agents, from the network or the last copy.
@immutable
final class RegistryList {
  const RegistryList(this.agents, {this.fetchedAt, this.note});

  final List<RegistryAgent> agents;

  /// When this copy was fetched; null when there is none.
  final DateTime? fetchedAt;

  /// Why it isn't fresh, in plain words ("Offline: …"), or null.
  final String? note;
}

/// Fetches the registry's index and keeps the last copy in Preferences
/// ([acpRegistryCacheKey]), so the list shows offline.
final class AcpRegistryClient {
  AcpRegistryClient(
    this._prefs, {
    http.Client? client,
    DateTime Function()? now,
    this.maxAge = const Duration(hours: 1),
    this.url = acpRegistryUrl,
  }) : _client = client ?? http.Client(),
       _now = now ?? DateTime.now;

  final Preferences _prefs;
  final http.Client _client;
  final DateTime Function() _now;

  /// How old the kept copy may be before [load] fetches again.
  final Duration maxAge;
  final String url;

  /// The kept copy when it is younger than [maxAge] (unless [force]), else a
  /// fresh fetch; when that fails, the kept copy with a [RegistryList.note].
  Future<RegistryList> load({bool force = false}) async {
    final kept = _read();
    if (!force && kept != null && _now().difference(kept.at) < maxAge) {
      return RegistryList(parseRegistry(kept.json), fetchedAt: kept.at);
    }
    try {
      final body = await _fetch();
      final agents = parseRegistry(body);
      final at = _now();
      _prefs[acpRegistryCacheKey] = jsonEncode({'v': 1, 'fetchedAt': at.toIso8601String(), 'json': body});
      return RegistryList(agents, fetchedAt: at);
    } on Object catch (e) {
      if (kept == null) return RegistryList(const [], note: "Couldn't load the agent list: ${_why(e)}");
      return RegistryList(
        parseRegistry(kept.json),
        fetchedAt: kept.at,
        note: "Couldn't reach the agent list, so this is the copy from ${_ago(_now().difference(kept.at))}.",
      );
    }
  }

  Future<String> _fetch() async {
    final res = await _client.send(http.Request('GET', Uri.parse(url))).timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) throw http.ClientException('HTTP ${res.statusCode}');
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in res.stream.timeout(const Duration(seconds: 30))) {
      bytes.add(chunk);
      if (bytes.length > maxRegistryBytes) throw const FormatException('The agent list is too large.');
    }
    return utf8.decode(bytes.takeBytes());
  }

  ({String json, DateTime at})? _read() {
    final raw = _prefs[acpRegistryCacheKey];
    if (raw == null) return null;
    try {
      if (jsonDecode(raw) case {'v': 1, 'fetchedAt': final String at, 'json': final String json}) {
        final when = DateTime.tryParse(at);
        if (when != null) return (json: json, at: when);
      }
    } on Object {
      // Read as no copy.
    }
    return null;
  }
}

String _why(Object e) => switch (e) {
  FormatException(:final message) => message,
  http.ClientException(:final message) => message,
  TimeoutException() => 'it took too long',
  _ => '$e',
};

String _ago(Duration d) => switch (d.inMinutes) {
  < 1 => 'just now',
  < 60 => '${d.inMinutes} min ago',
  _ when d.inHours < 48 => '${d.inHours} h ago',
  _ => '${d.inDays} days ago',
};
