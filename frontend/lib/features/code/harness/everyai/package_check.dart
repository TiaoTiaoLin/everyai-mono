// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

/// What a bash command installs, and whether each package looks safe to install: the pure half of the bash tool's
/// package check (the registry lookups and the lockfile check are in `package_registry_io.dart`).
///
/// Two failures are refused: a name the registry doesn't have (models make names up, and attackers register the
/// names they make up: "slopsquatting"), and a new or little-used look-alike of a popular package (a typosquat).
/// New or little-used packages, installs from git or a URL and install scripts only get a note. A name already in
/// the project's manifest or lockfile is never refused: that is how the user lets one through.
///
/// The typo checks follow the ideas of PyPI Warehouse's `typosnyper.py` and TypoGard (Taylor et al., "Defending
/// Against Package Typosquatting", NSS 2020): one edit away, the same name without delimiters, the same words in
/// another order, a popular name plus digits. Our own code.
library;

import 'dart:convert';

import '../../domain/shell_readonly.dart' show shellSegments;
import 'package_popular.dart';

/// A package registry.
enum Ecosystem {
  npm('npm'),
  pypi('PyPI'),
  crates('crates.io'),
  gems('RubyGems'),
  pub('pub.dev'),
  go('the Go module proxy'),
  brew('Homebrew');

  const Ecosystem(this.label);

  /// The registry's name in a sentence.
  final String label;
}

/// A package a command installs, by its registry name (version, extras and alias removed; PEP 503 for PyPI).
final class PackageRef {
  const PackageRef(this.ecosystem, this.name, {this.known = false, this.privateIndex = false});

  final Ecosystem ecosystem;
  final String name;

  /// Already in the project's manifest or lockfile: never refused.
  final bool known;

  /// The install may use a private index (a flag, an environment variable or a config file says so), so a name
  /// missing from the public registry isn't proof of a made-up name.
  final bool privateIndex;

  String get key => '${ecosystem.name}:$name';

  @override
  bool operator ==(Object other) => other is PackageRef && other.key == key;

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => key;
}

/// What [installsIn] found in a command.
final class InstallScan {
  const InstallScan({this.packages = const [], this.notes = const [], this.dirs = const [], this.runsManager = false});

  /// The registry packages it installs, in order.
  final List<PackageRef> packages;

  /// Things worth telling the model that need no lookup (an install from git or a URL, a third-party tap).
  final List<String> notes;

  /// The folders the installs run in (after the command's own `cd`s).
  final List<String> dirs;

  /// Whether any part of the command runs a package manager, install or not (so a lockfile may change).
  final bool runsManager;
}

/// What the registry says about a package. A null [PackageInfo] means the lookup failed.
final class PackageInfo {
  const PackageInfo({this.exists = true, this.created, this.downloads, this.installScript = false});

  static const missing = PackageInfo(exists: false);

  final bool exists;

  /// When the package (not the version) was first published, when the registry says.
  final DateTime? created;

  /// npm: last week; crates.io: the last 90 days; RubyGems: all time. Null where the registry has no count.
  final int? downloads;

  /// The latest version runs a preinstall, install or postinstall script (npm).
  final bool installScript;
}

enum VerdictKind { pass, unknown, warn, refuse }

final class PackageVerdict {
  const PackageVerdict(this.kind, [this.text]);

  static const pass = PackageVerdict(VerdictKind.pass);
  static const unknown = PackageVerdict(VerdictKind.unknown);

  final VerdictKind kind;

  /// Why, in a sentence (for warn and refuse).
  final String? text;
}

/// Packages younger than this count as new.
const newPackageAge = Duration(days: 30);

/// The verdict on installing [p], given what the registry said ([info]; null when the lookup failed).
PackageVerdict verdictOf(PackageRef p, PackageInfo? info, {required DateTime now}) {
  if (p.known) return PackageVerdict.pass;
  if (info == null) return PackageVerdict.unknown;
  final typo = typoTargetOf(p);
  if (!info.exists) {
    if (p.privateIndex) {
      return PackageVerdict(
        VerdictKind.warn,
        "`${p.name}` isn't on ${p.ecosystem.label}; fine if it comes from your private index.",
      );
    }
    final hint = typo != null
        ? 'Did you mean `$typo`?'
        : 'It may be a made-up name: check the real name (${_lookupHint(p)}) or ask the user.';
    return PackageVerdict(VerdictKind.refuse, "`${p.name}` doesn't exist on ${p.ecosystem.label}. $hint");
  }
  final age = info.created == null ? null : now.difference(info.created!);
  final isNew = age != null && age < newPackageAge;
  final low = _lowUse(p.ecosystem, info.downloads);
  final why = [
    if (isNew) 'first published ${_days(age)}',
    if (low) '${info.downloads} ${_downloadsSpan(p.ecosystem)}',
  ].join(', ');
  if (typo != null && (isNew || low)) {
    return PackageVerdict(
      VerdictKind.refuse,
      '`${p.name}` looks like a typo of the popular `$typo`, and is ${isNew ? 'new' : 'little used'} ($why). '
      'Install `$typo`, or ask the user whether they meant this exact package.',
    );
  }
  final notes = [
    if (isNew || low) '`${p.name}` is ${isNew ? 'new' : 'little used'} ($why); make sure it is the package you meant.',
    if (info.installScript) '`${p.name}` runs an install script.',
  ];
  return notes.isEmpty ? PackageVerdict.pass : PackageVerdict(VerdictKind.warn, notes.join(' '));
}

String _days(Duration age) => age.inDays == 0 ? 'today' : '${age.inDays} days ago';

bool _lowUse(Ecosystem e, int? downloads) {
  if (downloads == null) return false;
  return switch (e) {
    Ecosystem.npm || Ecosystem.crates => downloads < 1000,
    Ecosystem.gems => downloads < 5000,
    _ => false,
  };
}

String _downloadsSpan(Ecosystem e) => switch (e) {
  Ecosystem.npm => 'downloads last week',
  Ecosystem.crates => 'downloads in 90 days',
  _ => 'downloads in all',
};

String _lookupHint(PackageRef p) => switch (p.ecosystem) {
  Ecosystem.npm => '`npm view <name>`',
  Ecosystem.pypi => '`pip index versions <name>`',
  Ecosystem.crates => '`cargo search <name>`',
  Ecosystem.gems => '`gem search <name>`',
  Ecosystem.pub => 'pub.dev',
  Ecosystem.go => 'pkg.go.dev',
  Ecosystem.brew => '`brew search <name>`',
};

// ---------------------------------------------------------------------------------------------------------------
// Typos

Set<String> _split(String names) => {...names.split(' ').where((n) => n.isNotEmpty)};

final _popular = <Ecosystem, Set<String>>{
  Ecosystem.npm: _split(popularNpm),
  Ecosystem.pypi: _split(popularPypi),
  Ecosystem.crates: _split(popularCrates),
  Ecosystem.gems: _split(popularGems),
  Ecosystem.pub: _split(popularPub),
};

/// Whether [p] is on the bundled list of popular names (never looked up).
bool isPopular(PackageRef p) => _popular[p.ecosystem]?.contains(p.name) ?? false;

/// The popular package [p]'s name most likely imitates, or null: one edit away (names of 5+ characters, so `ws`
/// and `qs` don't match everything), the same once `-`, `_`, `.`, `@` and `/` are dropped (`types-node` for
/// `@types/node`), the same words in another order, or a popular name plus digits (`react2`). A popular name
/// itself never matches.
String? typoTargetOf(PackageRef p) {
  final list = _popular[p.ecosystem];
  if (list == null || list.contains(p.name)) return null;
  final n = p.name;
  final flat = _flat(n);
  for (final t in list) {
    if (_flat(t) == flat) return t;
    if (n.length >= 5 && t.length >= 5 && _oneEdit(n, t)) return t;
    if (_sameWords(n, t)) return t;
    if (n.length > t.length && n.startsWith(t) && RegExp(r'^[-_.]?\d+$').hasMatch(n.substring(t.length))) return t;
  }
  return null;
}

String _flat(String s) => s.toLowerCase().replaceAll(RegExp(r'[-_.@/]'), '');

bool _sameWords(String a, String b) {
  final wa = a.split(RegExp(r'[-_./]')).where((w) => w.isNotEmpty).toList();
  final wb = b.split(RegExp(r'[-_./]')).where((w) => w.isNotEmpty).toList();
  if (wa.length < 2 || wa.length != wb.length) return false;
  return (List.of(wa)..sort()).join(' ') == (List.of(wb)..sort()).join(' ');
}

/// Whether [a] and [b] are one insertion, deletion, substitution or swap of neighbours apart (Damerau-Levenshtein
/// distance 1).
bool _oneEdit(String a, String b) {
  if (a == b || (a.length - b.length).abs() > 1) return false;
  if (a.length == b.length) {
    final diffs = [
      for (var i = 0; i < a.length; i++)
        if (a[i] != b[i]) i,
    ];
    if (diffs.length == 1) return true;
    return diffs.length == 2 && diffs[1] == diffs[0] + 1 && a[diffs[0]] == b[diffs[1]] && a[diffs[1]] == b[diffs[0]];
  }
  final (s, l) = a.length < b.length ? (a, b) : (b, a);
  var i = 0;
  while (i < s.length && s[i] == l[i]) {
    i++;
  }
  return s.substring(i) == l.substring(i + 1);
}

/// [name] in PEP 503 form: lower case, runs of `-`, `_` and `.` as one `-`.
String pep503(String name) => name.toLowerCase().replaceAll(RegExp(r'[-_.]+'), '-');

// ---------------------------------------------------------------------------------------------------------------
// Parsing

/// The installs in [command], run from [cwd] in a project at [root]. [readFile] reads a file's text (null when it
/// doesn't exist); it serves `pip -r` files, `package.json` for a bare `npm install`, the manifests and lockfiles
/// that make a name [PackageRef.known], and `.npmrc` and other index settings. [env] is the shell's environment.
InstallScan installsIn(
  String command, {
  String cwd = '',
  String? root,
  Map<String, String> env = const {},
  String? Function(String path)? readFile,
}) {
  final scan = _Scan(cwd, root ?? cwd, env, readFile ?? (_) => null);
  final segments = shellSegments(command);
  if (segments == null) {
    // `$(…)`, a subshell or a heredoc: no word list, but a lockfile change still isn't surprising.
    return InstallScan(runsManager: RegExp('\\b(${_managers.join('|')})\\b').hasMatch(command));
  }
  for (final words in segments) {
    scan.segment(words);
  }
  return InstallScan(
    packages: scan.refs.toList(),
    notes: scan.notes.toList(),
    dirs: scan.dirs.toList(),
    runsManager: scan.runsManager,
  );
}

const _managers = [
  'npm', 'pnpm', 'yarn', 'bun', 'npx', 'bunx', 'pip', 'pip3', 'uv', 'uvx', 'pipx', 'poetry', 'pipenv', 'cargo', //
  'gem', 'bundle', 'dart', 'flutter', 'go', 'brew', 'corepack',
];

final _assignment = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=');
final _python = RegExp(r'^python[\d.]*$');
final _pipName = RegExp(r'^pip[\d.]*$');
final _remote = RegExp(r'^(git\+|git:|github:|gitlab:|bitbucket:|gist:|https?:|ssh:|hg\+|svn\+|bzr\+)');

final class _Scan {
  _Scan(this.cwd, this.root, Map<String, String> env, this.read) : env = {...env};

  String cwd;
  final String root;
  final Map<String, String> env;
  final String? Function(String path) read;

  final refs = <PackageRef>{};
  final notes = <String>{};
  final dirs = <String>{};
  var runsManager = false;
  final _texts = <String, String?>{};

  String? _text(String path) => _texts.putIfAbsent(path, () => read(path));

  String get _home => env['HOME'] ?? '';

  String _resolve(String p) {
    if (p.startsWith('~/') || p == '~') p = '$_home${p.substring(1)}';
    final full = p.startsWith('/') ? p : '$cwd/$p';
    final out = <String>[];
    for (final part in full.split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        if (out.isNotEmpty) out.removeLast();
      } else {
        out.add(part);
      }
    }
    return '/${out.join('/')}';
  }

  void segment(List<String> words) {
    var w = words;
    final local = <String, String>{};
    while (w.isNotEmpty) {
      final h = w.first;
      if (_assignment.hasMatch(h)) {
        final eq = h.indexOf('=');
        local[h.substring(0, eq)] = h.substring(eq + 1);
        w = w.sublist(1);
      } else if (const {'sudo', 'env', 'time', 'command', 'exec', 'nohup'}.contains(h)) {
        w = w.sublist(1);
        while (w.isNotEmpty && w.first.startsWith('-')) {
          w = w.sublist(const {'-u', '-g', '-C', '-S'}.contains(w.first) && w.length > 1 ? 2 : 1);
        }
      } else {
        break;
      }
    }
    if (w.isEmpty) return;
    final saved = {...env};
    env.addAll(local);
    try {
      _command(w.first.split('/').last, w.sublist(1));
    } finally {
      env
        ..clear()
        ..addAll(saved);
    }
  }

  void _command(String prog, List<String> a) {
    if (prog == 'cd') {
      if (a.isEmpty) {
        cwd = _home;
      } else if (a.first != '-') {
        cwd = _resolve(a.first);
      }
      return;
    }
    if (_managers.contains(prog) || _pipName.hasMatch(prog)) runsManager = true;
    String? at(int i) => i < a.length ? a[i] : null;
    if (_python.hasMatch(prog) && at(0) == '-m' && (at(1) == 'pip' || at(1) == 'pip3')) {
      runsManager = true;
      return _pip(a.sublist(2));
    }
    switch (prog) {
      case _ when _pipName.hasMatch(prog):
        _pip(a);
      case 'uv':
        switch (at(0)) {
          case 'pip':
            _pip(a.sublist(1));
          case 'add':
            _pyAdd(a.sublist(1));
          case 'tool' when at(1) == 'run' || at(1) == 'install':
            _runner(Ecosystem.pypi, a.sublist(2));
        }
      case 'uvx':
        _runner(Ecosystem.pypi, a);
      case 'pipx' when at(0) == 'install' || at(0) == 'run':
        _runner(Ecosystem.pypi, a.sublist(1));
      case 'poetry' when at(0) == 'add':
        _pyAdd(a.sublist(1));
      case 'npx' || 'bunx':
        _runner(Ecosystem.npm, a);
      case 'npm' || 'pnpm' || 'yarn' || 'bun':
        _js(prog, a);
      case 'cargo' when at(0) == 'add' || at(0) == 'install':
        _cargo(a.sublist(1));
      case 'gem' when at(0) == 'install':
        _gem(a.sublist(1));
      case 'dart' || 'flutter' when at(0) == 'pub' && at(1) == 'add':
        _pub(a.sublist(2));
      case 'go' when at(0) == 'get' || at(0) == 'install':
        _go(a.sublist(1));
      case 'brew' when at(0) == 'install':
        for (final n in _positional(a.sublist(1), const {})) {
          final parts = n.split('/');
          if (parts.length == 3) notes.add('`$n` comes from the third-party Homebrew tap ${parts[0]}/${parts[1]}.');
        }
    }
  }

  /// The arguments of [args] that aren't flags; [values] are the flags that take the next word, given to [onValue].
  List<String> _positional(
    List<String> args,
    Set<String> values, {
    void Function(String flag, String value)? onValue,
    int? limit,
  }) {
    final out = <String>[];
    var flags = true;
    for (var i = 0; i < args.length; i++) {
      final a = args[i];
      if (flags && a == '--') {
        flags = false;
      } else if (flags && a.startsWith('-') && a.length > 1) {
        final eq = a.indexOf('=');
        if (eq > 0) {
          onValue?.call(a.substring(0, eq), a.substring(eq + 1));
        } else if (values.contains(a) && i + 1 < args.length) {
          onValue?.call(a, args[++i]);
        }
      } else {
        out.add(a);
        if (limit != null && out.length >= limit) break;
      }
    }
    return out;
  }

  void _add(PackageRef p) {
    refs.add(p);
    dirs.add(cwd);
  }

  void _remoteNote(String spec) => notes.add('`$spec` installs from git or a URL, not the registry.');

  // Python ------------------------------------------------------------------------------------------------------

  static const _pipValues = {
    '-r', '--requirement', '-c', '--constraint', '-i', '--index-url', '--extra-index-url', '-f', '--find-links', //
    '-t', '--target', '--prefix', '--root', '--python', '-e', '--editable', '--platform', '--python-version',
    '--implementation', '--abi', '--only-binary', '--no-binary', '--upgrade-strategy', '--src', '--cache-dir',
    '--trusted-host', '--index', '--default-index', '--progress-bar', '--report', '--log', '-p', '--group',
    '--optional', '--extra', '--package', '--project', '--directory', '-G', '-E', '--extras', '--source', '--with',
    '--from', '--spec', '--pip-args', '--suffix',
  };

  static const _pyIndexFlags = {
    '-i', '--index-url', '--extra-index-url', '-f', '--find-links', '--index', '--default-index', '--source', //
  };

  bool _pyPrivate = false;

  void _pyIndex(String flag, String value) {
    if (_pyIndexFlags.contains(flag)) _pyPrivate = true;
  }

  bool get _pyPrivateNow {
    if (_pyPrivate) return true;
    for (final k in const ['PIP_INDEX_URL', 'PIP_EXTRA_INDEX_URL', 'UV_INDEX_URL', 'UV_EXTRA_INDEX_URL', 'UV_INDEX']) {
      if (env[k]?.isNotEmpty ?? false) return true;
    }
    if (env['UV_DEFAULT_INDEX']?.isNotEmpty ?? false) return true;
    for (final d in {cwd, root}) {
      if (_text('$d/uv.toml') != null || _text('$d/pip.conf') != null) return true;
      final py = _text('$d/pyproject.toml') ?? '';
      if (py.contains('tool.uv.index') || py.contains('tool.poetry.source')) return true;
    }
    for (final f in const ['.config/pip/pip.conf', '.pip/pip.conf', 'Library/Application Support/pip/pip.conf']) {
      if (_home.isNotEmpty && (_text('$_home/$f')?.contains('index-url') ?? false)) return true;
    }
    return false;
  }

  void _pip(List<String> a) {
    if (a.isEmpty || a.first != 'install') return;
    _pyPrivate = false;
    final files = <String>[];
    final names = _positional(
      a.sublist(1),
      _pipValues,
      onValue: (f, v) {
        _pyIndex(f, v);
        if (f == '-r' || f == '--requirement') files.add(v);
        if ((f == '-e' || f == '--editable') && _remote.hasMatch(v)) _remoteNote(v);
      },
    );
    for (final n in names) {
      _addPy(n);
    }
    for (final f in files) {
      _requirements(_resolve(f), nested: false);
    }
  }

  void _pyAdd(List<String> a) {
    _pyPrivate = false;
    for (final n in _positional(a, _pipValues, onValue: _pyIndex)) {
      _addPy(n);
    }
  }

  void _requirements(String path, {required bool nested}) {
    final text = _text(path);
    if (text == null) return;
    final dir = path.substring(0, path.lastIndexOf('/'));
    var count = 0;
    for (var line in const LineSplitter().convert(text)) {
      final hash = line.indexOf(' #');
      if (hash >= 0) line = line.substring(0, hash);
      line = line.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final words = line.split(RegExp(r'\s+'));
      if (words.first.startsWith('-')) {
        if (words.length > 1) _pyIndex(words.first, words[1]);
        if ((words.first == '-r' || words.first == '--requirement') && !nested && words.length > 1) {
          _requirements(words[1].startsWith('/') ? words[1] : '$dir/${words[1]}', nested: true);
        }
        continue;
      }
      if (++count > 30) break;
      _addPy(line, fromFile: true);
    }
  }

  void _addPy(String spec, {bool fromFile = false}) {
    if (_remote.hasMatch(spec) || spec.contains('://') || RegExp(r'\s@\s|^[\w.-]+\s*@').hasMatch(spec)) {
      if (!spec.startsWith('.') && !spec.startsWith('/')) _remoteNote(spec);
      return;
    }
    if (spec.startsWith('.') ||
        spec.startsWith('/') ||
        spec.startsWith('~') ||
        RegExp(r'\.(whl|zip|tar\.gz)$').hasMatch(spec)) {
      return;
    }
    final name = spec.split(RegExp(r'[\[<>=!~;\s(]')).first.trim();
    if (!RegExp(r'^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$').hasMatch(name)) return;
    final n = pep503(name);
    _add(
      PackageRef(
        Ecosystem.pypi,
        n,
        known: _known(Ecosystem.pypi, n, lockOnly: fromFile),
        privateIndex: _pyPrivateNow,
      ),
    );
  }

  // JavaScript --------------------------------------------------------------------------------------------------

  static const _jsValues = {
    '--registry', '--prefix', '--cache', '-w', '--workspace', '--tag', '--filter', '-F', '--cwd', '-C', '--dir', //
    '--omit', '--include', '--install-strategy', '--userconfig', '--loglevel',
  };

  static const _runnerValues = {..._jsValues, '-p', '--package', '--call', '-c'};

  bool _jsFlagPrivate = false;

  void _jsValue(String flag, String value) {
    if (flag == '--registry') _jsFlagPrivate = true;
  }

  bool _npmPrivate(String name) {
    if (_jsFlagPrivate) return true;
    if (env['npm_config_registry']?.isNotEmpty ?? false) return true;
    if (env['NPM_CONFIG_REGISTRY']?.isNotEmpty ?? false) return true;
    final scope = name.startsWith('@') ? name.substring(0, name.indexOf('/')) : null;
    for (final d in {cwd, root, if (_home.isNotEmpty) _home}) {
      final rc = _text('$d/.npmrc');
      if (rc == null) continue;
      for (final line in const LineSplitter().convert(rc)) {
        final l = line.trim();
        if (l.startsWith('registry=') && !l.contains('registry.npmjs.org')) return true;
        if (scope != null && l.startsWith('$scope:registry=')) return true;
      }
    }
    return false;
  }

  void _js(String prog, List<String> a) {
    if (a.isEmpty) return;
    var sub = a.first;
    var rest = a.sublist(1);
    if (sub == 'dlx' && (prog == 'pnpm' || prog == 'yarn')) return _runner(Ecosystem.npm, rest);
    if (sub == 'global' && prog == 'yarn' && rest.isNotEmpty) {
      sub = rest.first;
      rest = rest.sublist(1);
    }
    if (!const {'install', 'i', 'in', 'add', 'a', 'isntall'}.contains(sub)) return;
    _jsFlagPrivate = false;
    final names = _positional(rest, _jsValues, onValue: _jsValue);
    if (names.isEmpty) {
      if (sub != 'add') _bareJs();
      return;
    }
    for (final n in names) {
      _addNpm(n);
    }
  }

  static const _jsLocks = ['package-lock.json', 'npm-shrinkwrap.json', 'yarn.lock', 'pnpm-lock.yaml', 'bun.lock'];

  /// A bare `npm install`: the dependencies in package.json the lockfile doesn't have yet (the ones just added).
  void _bareJs() {
    final text = _text('$cwd/package.json');
    if (text == null) return;
    Map<String, Object?> json;
    try {
      json = (jsonDecode(text) as Map).cast<String, Object?>();
    } on Object {
      return;
    }
    final lock = [for (final f in _jsLocks) ?_text('$cwd/$f')].join('\n');
    var count = 0;
    for (final field in const ['dependencies', 'devDependencies', 'optionalDependencies']) {
      if (json[field] case final Map<Object?, Object?> deps) {
        for (final MapEntry(:key, :value) in deps.entries) {
          if (key is! String || value is! String) continue;
          if (lock.isNotEmpty && _mentions(lock, key, Ecosystem.npm)) continue;
          if (++count > 30) return;
          _addNpm(value.startsWith('npm:') ? value.substring(4) : '$key@$value', fromFile: true);
        }
      }
    }
  }

  void _addNpm(String spec, {bool fromFile = false}) {
    final alias = spec.indexOf('@npm:');
    if (alias > 0) spec = spec.substring(alias + 5);
    if (_remote.hasMatch(spec) || (spec.contains('/') && !spec.startsWith('@') && !spec.startsWith('.'))) {
      if (!spec.startsWith('/') && !spec.startsWith('~')) _remoteNote(spec);
      return;
    }
    if (RegExp(r'^(\.|/|~|file:|link:|workspace:|portal:|patch:)').hasMatch(spec) ||
        RegExp(r'\.(tgz|tar\.gz|tar)$').hasMatch(spec)) {
      return;
    }
    final at = spec.indexOf('@', spec.startsWith('@') ? 1 : 0);
    final name = (at > 0 ? spec.substring(0, at) : spec).toLowerCase();
    final version = at > 0 ? spec.substring(at + 1) : '';
    if (RegExp('^(file|link|workspace|portal|patch):').hasMatch(version)) return;
    if (_remote.hasMatch(version) || version.contains('://') || version.contains('/')) {
      _remoteNote(spec);
      return;
    }
    if (!RegExp(r'^(@[a-z0-9][\w.~-]*/)?[a-z0-9][\w.~-]*$').hasMatch(name)) return;
    _add(
      PackageRef(
        Ecosystem.npm,
        name,
        known: _known(Ecosystem.npm, name, lockOnly: fromFile),
        privateIndex: _npmPrivate(name),
      ),
    );
  }

  /// `npx pkg args…`, `uvx pkg`, `pipx run pkg`: the first word is the package (or `-p`/`--from`/`--spec`
  /// name it, and then the first word is the command); the rest are its arguments.
  void _runner(Ecosystem e, List<String> a) {
    final named = <String>[];
    _jsFlagPrivate = false;
    _pyPrivate = false;
    final words = _positional(
      a,
      e == Ecosystem.npm ? _runnerValues : _pipValues,
      limit: 1,
      onValue: (f, v) {
        if (const {'-p', '--package', '--from', '--with', '--spec'}.contains(f)) named.add(v);
        e == Ecosystem.npm ? _jsValue(f, v) : _pyIndex(f, v);
      },
    );
    for (final n in [...named, if (named.isEmpty) ...words]) {
      e == Ecosystem.npm ? _addNpm(n) : _addPy(n);
    }
  }

  // Rust, Ruby, Dart, Go ------------------------------------------------------------------------------------------

  void _cargo(List<String> a) {
    var private = false;
    var notRegistry = false;
    final names = _positional(
      a,
      const {
        '--features',
        '-F',
        '--git',
        '--path',
        '--registry',
        '--rename',
        '--version',
        '--vers',
        '-p',
        '--package',
        '--branch',
        '--tag',
        '--rev',
        '--root',
        '--target',
        '--manifest-path',
        '--index',
        '--target-dir',
        '-j',
        '--jobs',
        '--profile', //
      },
      onValue: (f, v) {
        if (f == '--registry' || f == '--index') private = true;
        if (f == '--git') _remoteNote(v);
        if (f == '--git' || f == '--path') notRegistry = true;
      },
    );
    if (notRegistry) return;
    for (final config in {'$cwd/.cargo', '$root/.cargo', if (_home.isNotEmpty) '$_home/.cargo'}) {
      final text = _text('$config/config.toml') ?? '';
      if (text.contains('replace-with') || text.contains('[registries')) private = true;
    }
    for (final spec in names) {
      final name = spec.split('@').first.toLowerCase();
      if (!RegExp(r'^[a-z0-9_-]+$').hasMatch(name)) continue;
      _add(PackageRef(Ecosystem.crates, name, known: _known(Ecosystem.crates, name), privateIndex: private));
    }
  }

  void _gem(List<String> a) {
    var private = false;
    final names = _positional(
      a,
      const {
        '-v', '--version', '-s', '--source', '-i', '--install-dir', '-n', '--bindir', '--platform', '-g', '--file', //
      },
      onValue: (f, v) {
        if (f == '-s' || f == '--source') private = true;
      },
    );
    for (final spec in names) {
      if (spec.endsWith('.gem') || spec.contains('/')) continue;
      final name = spec.split(':').first;
      if (!RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(name)) continue;
      _add(PackageRef(Ecosystem.gems, name, known: _known(Ecosystem.gems, name), privateIndex: private));
    }
  }

  void _pub(List<String> a) {
    var private = env['PUB_HOSTED_URL']?.isNotEmpty ?? false;
    var notRegistry = false;
    final names = _positional(
      a,
      const {'--path', '--git-url', '--git-ref', '--git-path', '--hosted-url', '--sdk', '--directory', '-C'},
      onValue: (f, v) {
        if (f == '--hosted-url') private = true;
        if (f == '--git-url') _remoteNote(v);
        if (f == '--git-url' || f == '--path' || f == '--sdk') notRegistry = true;
      },
    );
    if (notRegistry) return;
    for (var spec in names) {
      if (spec.contains('{')) continue;
      spec = spec.replaceFirst(RegExp('^(dev|override):'), '');
      final name = spec.split(':').first;
      if (!RegExp(r'^[a-z0-9_]+$').hasMatch(name)) continue;
      _add(PackageRef(Ecosystem.pub, name, known: _known(Ecosystem.pub, name), privateIndex: private));
    }
  }

  void _go(List<String> a) {
    final private = const ['GOPRIVATE', 'GONOPROXY', 'GOPROXY'].any((k) => env[k]?.isNotEmpty ?? false);
    for (final spec in _positional(a, const {'-modfile', '-C', '-o', '-tags'})) {
      final name = spec.split('@').first;
      if (name.startsWith('.') || name.startsWith('/') || !name.split('/').first.contains('.')) continue;
      if (!RegExp(r'^[A-Za-z0-9._~/-]+$').hasMatch(name)) continue;
      _add(PackageRef(Ecosystem.go, name, known: _known(Ecosystem.go, name), privateIndex: private));
    }
  }

  // Manifests -----------------------------------------------------------------------------------------------------

  static const _manifests = {
    Ecosystem.npm: ['package.json'],
    Ecosystem.pypi: ['requirements.txt', 'requirements-dev.txt', 'pyproject.toml', 'Pipfile', 'setup.py', 'setup.cfg'],
    Ecosystem.crates: ['Cargo.toml'],
    Ecosystem.gems: ['Gemfile'],
    Ecosystem.pub: ['pubspec.yaml'],
    Ecosystem.go: ['go.mod'],
  };

  static const _locks = {
    Ecosystem.npm: _jsLocks,
    Ecosystem.pypi: ['uv.lock', 'poetry.lock', 'Pipfile.lock'],
    Ecosystem.crates: ['Cargo.lock'],
    Ecosystem.gems: ['Gemfile.lock'],
    Ecosystem.pub: ['pubspec.lock'],
    Ecosystem.go: ['go.sum'],
  };

  /// Whether [name] is in a lockfile (or, unless [lockOnly], a manifest) in the folder or the project root. Names
  /// read from a file the command installs from count by the lockfile only: the file itself may be where a made-up
  /// name was just written.
  bool _known(Ecosystem e, String name, {bool lockOnly = false}) {
    for (final d in {cwd, root}) {
      for (final f in [...?_locks[e], if (!lockOnly) ...?_manifests[e]]) {
        final text = _text('$d/$f');
        if (text != null && _mentions(text, name, e)) return true;
      }
    }
    return false;
  }
}

/// Whether [text] names the package [name] as a whole word (PyPI: any of `-_.` between its parts).
bool _mentions(String text, String name, Ecosystem e) {
  final body = e == Ecosystem.pypi ? name.split('-').map(RegExp.escape).join('[-_.]') : RegExp.escape(name);
  return RegExp('(?<![\\w.-])$body(?![\\w.-])', caseSensitive: e != Ecosystem.pypi).hasMatch(text);
}
