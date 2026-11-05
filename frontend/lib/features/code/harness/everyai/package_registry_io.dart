// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

/// The bash tool's package check, IO half: registry lookups ([RegistryLookup]), the check before a command runs
/// ([PackageGuard.check]) and the lockfile check after it ([PackageGuard.lockNotes]). The verdicts are in
/// `package_check.dart`.
///
/// Lookups go straight from the app to the public registries (free, and they work without our server). Hosts are
/// constants and names are checked before they go into a path. Only names, numbers and dates reach the model, never
/// a registry's descriptions or READMEs (anyone can write those).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../../../core/config/version.dart';
import 'package_check.dart';

/// Looks a package up on its registry. Null means the lookup failed (offline, timed out, an error).
abstract interface class PackageLookup {
  Future<PackageInfo?> info(PackageRef p);
}

/// [PackageLookup] on the public registries, with a cache for the session: answers (found or missing) are kept,
/// failures aren't, so the next command tries again.
final class RegistryLookup implements PackageLookup {
  RegistryLookup(this.client, {this.timeout = const Duration(seconds: 3)});

  final http.Client client;

  /// Per request.
  final Duration timeout;

  final _cache = <String, Future<PackageInfo?>>{};

  static final _headers = {'User-Agent': 'EveryAI/$appVersion (package check)', 'Accept': 'application/json'};

  @override
  Future<PackageInfo?> info(PackageRef p) {
    final key = p.key;
    if (_cache[key] case final hit?) return hit;
    final f = _fetch(p).then<PackageInfo?>((v) => v, onError: (Object _) => null);
    _cache[key] = f;
    unawaited(
      f.then((v) {
        if (v == null) _cache.remove(key);
      }),
    );
    return f;
  }

  /// The JSON at [url], or null when the registry says it doesn't exist (404/410). Anything else throws.
  Future<Map<String, Object?>?> _json(Uri url) async {
    final r = await client.get(url, headers: _headers).timeout(timeout);
    if (r.statusCode == 404 || r.statusCode == 410) return null;
    if (r.statusCode != 200) throw HttpException('${r.statusCode}', uri: url);
    return (jsonDecode(r.body) as Map).cast<String, Object?>();
  }

  Future<PackageInfo?> _fetch(PackageRef p) async {
    final n = p.name;
    switch (p.ecosystem) {
      case Ecosystem.npm:
        // The download count is small for every package; the full packument (for the first publish date and
        // install scripts) can run to megabytes for a popular one, so it's only fetched for little-used names.
        final d = await _json(Uri.https('api.npmjs.org', '/downloads/point/last-week/$n'));
        final downloads = (d?['downloads'] as num?)?.toInt();
        if (downloads != null && downloads >= 1000) return PackageInfo(downloads: downloads);
        final doc = await _json(Uri.parse('https://registry.npmjs.org/${n.replaceAll('/', '%2F')}'));
        if (doc == null) return PackageInfo.missing;
        final latest = (doc['dist-tags'] as Map?)?['latest'];
        final version = (doc['versions'] as Map?)?[latest] as Map?;
        final scripts = version?['scripts'] as Map?;
        return PackageInfo(
          created: _date((doc['time'] as Map?)?['created']),
          downloads: downloads ?? 0,
          installScript:
              version?['hasInstallScript'] == true ||
              (scripts != null && const ['preinstall', 'install', 'postinstall'].any(scripts.containsKey)),
        );
      case Ecosystem.pypi:
        final doc = await _json(Uri.https('pypi.org', '/pypi/$n/json'));
        if (doc == null) return PackageInfo.missing;
        DateTime? first;
        for (final files in ((doc['releases'] as Map?) ?? const {}).values) {
          for (final f in (files as List? ?? const [])) {
            final t = _date((f as Map?)?['upload_time_iso_8601']);
            if (t != null && (first == null || t.isBefore(first))) first = t;
          }
        }
        return PackageInfo(created: first);
      case Ecosystem.crates:
        final doc = await _json(Uri.https('crates.io', '/api/v1/crates/$n'));
        if (doc == null) return PackageInfo.missing;
        final c = doc['crate'] as Map?;
        return PackageInfo(created: _date(c?['created_at']), downloads: (c?['recent_downloads'] as num?)?.toInt());
      case Ecosystem.gems:
        final doc = await _json(Uri.https('rubygems.org', '/api/v1/gems/$n.json'));
        if (doc == null) return PackageInfo.missing;
        return PackageInfo(downloads: (doc['downloads'] as num?)?.toInt());
      case Ecosystem.pub:
        final doc = await _json(Uri.https('pub.dev', '/api/packages/$n'));
        if (doc == null) return PackageInfo.missing;
        DateTime? first;
        for (final v in (doc['versions'] as List? ?? const [])) {
          final t = _date((v as Map?)?['published']);
          if (t != null && (first == null || t.isBefore(first))) first = t;
        }
        return PackageInfo(created: first);
      case Ecosystem.go:
        // `go install golang.org/x/tools/cmd/goimports` names a package inside a module: try the parent paths too.
        final parts = n.split('/');
        for (var k = parts.length; k >= 2 && parts.length - k < 4; k--) {
          final path = parts.take(k).join('/').replaceAllMapped(RegExp('[A-Z]'), (m) => '!${m[0]!.toLowerCase()}');
          if (await _json(Uri.https('proxy.golang.org', '/$path/@latest')) != null) return const PackageInfo();
        }
        return PackageInfo.missing;
      case Ecosystem.brew:
        return const PackageInfo();
    }
  }

  static DateTime? _date(Object? v) => v is String ? DateTime.tryParse(v) : null;
}

/// What [PackageGuard.check] found.
final class PackageCheck {
  const PackageCheck({this.refusal, this.notes = const [], this.scan = const InstallScan()});

  /// The tool's error when the install is refused.
  final String? refusal;

  /// Warnings to add to the command's output.
  final List<String> notes;

  final InstallScan scan;
}

/// The lockfiles before a command ran: path → text (a size and date for a big file), null when absent.
typedef LockSnapshot = Map<String, String?>;

/// The package check of one session (one per session, so its lookups are cached across model switches).
final class PackageGuard {
  PackageGuard(
    this.lookup, {
    Map<String, String>? env,
    DateTime Function()? clock,
    this.wait = const Duration(seconds: 5),
  }) : env = env ?? Platform.environment,
       _clock = clock ?? DateTime.now;

  final PackageLookup lookup;

  /// The shell's environment (index settings, HOME for `~/.npmrc`).
  final Map<String, String> env;

  /// The longest a command waits for its lookups, in all.
  final Duration wait;

  final DateTime Function() _clock;

  /// The most packages looked up for one command.
  static const maxLookups = 10;

  static String? _read(String path) {
    try {
      final f = File(path);
      return f.existsSync() && f.lengthSync() < 5 << 20 ? f.readAsStringSync() : null;
    } on Object {
      return null;
    }
  }

  /// Checks what [command] (run in [cwd], in the project at [root]) installs.
  Future<PackageCheck> check(String command, {required String cwd, required String root}) async {
    final scan = installsIn(command, cwd: cwd, root: root, env: env, readFile: _read);
    final notes = [...scan.notes];
    final todo = [
      for (final p in scan.packages)
        if (!p.known && !isPopular(p) && p.ecosystem != Ecosystem.brew) p,
    ];
    if (todo.length > maxLookups) {
      notes.add('Checked the first $maxLookups of ${todo.length} packages on their registries.');
    }
    final refs = todo.take(maxLookups).toList();
    final infos = await Future.wait([
      for (final p in refs)
        lookup.info(p).timeout(wait, onTimeout: () => null).then<PackageInfo?>((v) => v, onError: (Object _) => null),
    ]);
    final now = _clock();
    final refused = <String>[];
    final unknown = <String>[];
    for (var i = 0; i < refs.length; i++) {
      final v = verdictOf(refs[i], infos[i], now: now);
      switch (v.kind) {
        case VerdictKind.refuse:
          refused.add(v.text!);
        case VerdictKind.warn:
          notes.add(v.text!);
        case VerdictKind.unknown:
          unknown.add('`${refs[i].name}`');
        case VerdictKind.pass:
      }
    }
    if (unknown.isNotEmpty) {
      notes.add("Couldn't check ${unknown.join(', ')} on the registry (offline, or it didn't answer).");
    }
    if (refused.isEmpty) return PackageCheck(notes: notes, scan: scan);
    return PackageCheck(
      refusal:
          "Error: refused by EveryAI's package check, nothing was installed. ${refused.join(' ')} This check is on "
          'in every mode. If the user wants this exact package, they can add it to the project themselves (a name '
          'in the manifest or lockfile installs) or run the install in the Terminal pane.',
      notes: notes,
      scan: scan,
    );
  }

  static const lockfiles = [
    'package-lock.json', 'npm-shrinkwrap.json', 'pnpm-lock.yaml', 'yarn.lock', 'bun.lock', 'uv.lock', //
    'poetry.lock', 'Pipfile.lock', 'Cargo.lock', 'Gemfile.lock', 'pubspec.lock',
  ];

  /// The lockfiles in [cwd], [root] and the folders [scan] installs in, before the command runs. Their text is only
  /// read when the command runs a package manager; otherwise a size and date tell whether one changed.
  LockSnapshot snapshot(String cwd, String root, InstallScan scan) => {
    for (final d in {cwd, root, ...scan.dirs})
      for (final f in lockfiles) '$d/$f': _lockState('$d/$f', text: scan.runsManager),
  };

  static String? _lockState(String path, {required bool text}) {
    try {
      final f = File(path);
      if (!f.existsSync()) return null;
      final s = f.statSync();
      return text && s.size < 5 << 20 ? f.readAsStringSync() : '\u0000${s.size}:${s.modified.millisecondsSinceEpoch}';
    } on Object {
      return null;
    }
  }

  /// Registry addresses a lockfile may point at without a note.
  static const _registries = [
    'https://registry.npmjs.org/', 'https://registry.yarnpkg.com/', 'https://pypi.org/', //
    'https://files.pythonhosted.org/', 'registry+https://github.com/rust-lang/crates.io-index',
    'sparse+https://index.crates.io/', 'https://index.crates.io/', 'https://static.crates.io/', 'https://rubygems.org',
    'https://pub.dev', 'https://pub.dartlang.org',
  ];

  static final _url = RegExp(r'''(?:registry\+|sparse\+|git\+)?[a-z][a-z0-9+.-]*://[^\s"'<>,)}\]]+''');
  static final _sourceLine = RegExp(r'\b(resolved|tarball|url|registry|source|remote|git)\b', caseSensitive: false);

  /// Notes on what [command] changed in the lockfiles of [before]: addresses off the registry or over plain http,
  /// new npm packages that run install scripts, and a lockfile changed by a command that runs no package manager.
  List<String> lockNotes(LockSnapshot before, InstallScan scan, String command) {
    final notes = <String>[];
    final offRegistry = <String>{};
    final plain = <String>{};
    final scripts = <String>{};
    final changed = <String>[];
    for (final MapEntry(key: path, value: old) in before.entries) {
      final now = _lockState(path, text: old == null ? scan.runsManager : !old.startsWith('\u0000'));
      if (now == old || now == null) continue;
      final name = path.substring(path.lastIndexOf('/') + 1);
      changed.add(name);
      if (now.startsWith('\u0000')) continue;
      final had = (old == null || old.startsWith('\u0000')) ? const <String>{} : old.split('\n').toSet();
      for (final line in now.split('\n')) {
        if (had.contains(line)) continue;
        if (name == 'package-lock.json' || name == 'npm-shrinkwrap.json'
            ? !line.contains('"resolved"')
            : !_sourceLine.hasMatch(line)) {
          continue;
        }
        for (final m in _url.allMatches(line)) {
          final u = m[0]!;
          final host = Uri.tryParse(u.replaceFirst(RegExp(r'^(registry|sparse|git)\+'), ''))?.host ?? '';
          if (host.isEmpty || host == 'localhost' || host == '127.0.0.1' || command.contains(host)) continue;
          if (u.startsWith('http://')) {
            plain.add(host);
          } else if (!_registries.any(u.startsWith)) {
            offRegistry.add(host);
          }
        }
      }
      if (name == 'package-lock.json') scripts.addAll(_newInstallScripts(old, now));
    }
    if (plain.isNotEmpty) notes.add('The lockfile now downloads over plain http from ${plain.join(', ')}.');
    if (offRegistry.isNotEmpty) {
      notes.add(
        'The lockfile now downloads from ${offRegistry.join(', ')}, not the registry; make sure that is meant.',
      );
    }
    if (scripts.isNotEmpty) {
      final list = scripts.take(10).join(', ');
      notes.add(
        'New packages that run install scripts: $list${scripts.length > 10 ? ' and ${scripts.length - 10} more' : ''}.',
      );
    }
    if (changed.isNotEmpty && !scan.runsManager) {
      notes.add(
        '${changed.toSet().join(', ')} changed, though this command runs no package manager; check what it added '
        '(git diff).',
      );
    }
    return notes;
  }

  /// npm packages with `hasInstallScript` in [now]'s `packages` that weren't there (with it) in [old].
  static Iterable<String> _newInstallScripts(String? old, String now) {
    Set<String> withScripts(String? text) {
      if (text == null || text.startsWith('\u0000')) return const {};
      try {
        final packages = (jsonDecode(text) as Map)['packages'] as Map?;
        return {
          for (final MapEntry(:key, :value) in (packages ?? const {}).entries)
            if (value is Map && value['hasInstallScript'] == true) key as String,
        };
      } on Object {
        return const {};
      }
    }

    final had = withScripts(old);
    return withScripts(now)
        .where((k) => !had.contains(k))
        .map((k) => k.contains('node_modules/') ? k.substring(k.lastIndexOf('node_modules/') + 13) : k);
  }

  /// [notes] as the one block added to the command's output.
  static String block(List<String> notes) => notes.isEmpty ? '' : '\n[EveryAI package check] ${notes.join(' ')}';
}
