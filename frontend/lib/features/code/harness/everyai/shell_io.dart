// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../session_processes.dart' show sessionEnvVar;

/// The user's login shell, and the environment it sets up (PATH from
/// `~/.zshrc` and friends: pyenv, nvm, Homebrew), captured once per app run
/// (until [reload]). Commands then run in that shell with that environment,
/// the way the user's own terminal would run them, not in the app's launchd
/// environment. The usual install directories ([commonDirs]) go after the
/// shell's PATH, so a CLI is found even when the rc files don't add them.
final class ShellEnv {
  ShellEnv._(this.shell, this.env);

  final String shell;
  final Map<String, String> env;

  static Future<ShellEnv>? _cached;

  static Future<ShellEnv> load() => _cached ??= _capture();

  /// Reads the login shell's environment again (the user installed something).
  static Future<ShellEnv> reload() {
    _cached = null;
    return load();
  }

  static String get _defaultShell {
    final s = Platform.environment['SHELL'];
    if (s != null && s.isNotEmpty && File(s).existsSync()) return s;
    return Platform.isMacOS ? '/bin/zsh' : '/bin/bash';
  }

  static const _marker = '__EVERYAI_ENV__';

  static Future<ShellEnv> _capture() async {
    final shell = _defaultShell;
    try {
      // Interactive + login, so rc files that set PATH run; output before the
      // marker (banners, prompts) is skipped.
      final res = await Process.run(
        shell,
        ['-ilc', 'printf "\\n$_marker\\n"; env -0'],
        stdoutEncoding: utf8,
        environment: {'TERM': 'dumb'},
      ).timeout(const Duration(seconds: 10));
      final out = res.stdout as String;
      final at = out.indexOf('$_marker\n');
      if (at >= 0) {
        final env = <String, String>{};
        for (final entry in out.substring(at + _marker.length + 1).split('\x00')) {
          final eq = entry.indexOf('=');
          if (eq > 0) env[entry.substring(0, eq)] = entry.substring(eq + 1);
        }
        if (env.containsKey('PATH')) return ShellEnv._(shell, _withCommonDirs(_clean(env)));
      }
    } on Object {
      // Fall back to the app's own environment below.
    }
    return ShellEnv._(shell, _withCommonDirs(_clean(Map.of(Platform.environment))));
  }

  static Map<String, String> _withCommonDirs(Map<String, String> env) {
    final windows = Platform.isWindows;
    final key = windows ? env.keys.firstWhere((k) => k.toUpperCase() == 'PATH', orElse: () => 'Path') : 'PATH';
    final home = (windows ? env['USERPROFILE'] : env['HOME']) ?? Platform.environment['HOME'] ?? '';
    return env..[key] = mergePaths(env[key] ?? '', commonDirs(home, env, windows: windows), windows: windows);
  }

  /// Drops what belongs to the capturing shell, not to commands.
  static Map<String, String> _clean(Map<String, String> env) => env
    ..remove('SHLVL')
    ..remove('_')
    ..remove('OLDPWD')
    ..remove('PS1')
    ..['TERM'] = 'dumb'
    ..['PAGER'] = 'cat'
    ..['GIT_PAGER'] = 'cat'
    ..['NO_COLOR'] = '1';
}

/// Where CLIs are usually installed, for an app started from the Dock whose
/// login shell doesn't put them on PATH: Homebrew, npm's global prefix
/// (`NPM_CONFIG_PREFIX` or `prefix=` in `~/.npmrc`), nvm's default or newest
/// Node, bun, cargo, volta, deno, Cursor's and the user's own bin. Kept
/// whether they exist yet or not, since the env is kept for the whole run
/// and an installer may make one later (`~/.local/bin`); [exists] only
/// picks nvm's version. [read] and [list] read a file and a directory's
/// entries (null or empty when missing). No process runs.
List<String> commonDirs(
  String home,
  Map<String, String> env, {
  bool windows = false,
  bool Function(String dir)? exists,
  String? Function(String file)? read,
  List<String> Function(String dir)? list,
}) {
  final has = exists ?? (d) => Directory(d).existsSync();
  final readFile =
      read ??
      (f) {
        try {
          return File(f).readAsStringSync();
        } on Object {
          return null;
        }
      };
  final entries =
      list ??
      (d) {
        try {
          return [for (final e in Directory(d).listSync()) e.path.split(Platform.pathSeparator).last];
        } on Object {
          return const [];
        }
      };
  String? nonEmpty(String? v) => v == null || v.trim().isEmpty ? null : v.trim();
  if (windows) {
    return [
      if (nonEmpty(env['APPDATA']) case final a?) '$a\\npm',
      if (nonEmpty(env['LOCALAPPDATA']) case final l?) ...['$l\\Programs\\nodejs', '$l\\Volta\\bin', '$l\\pnpm'],
      if (nonEmpty(env['USERPROFILE']) case final u?) ...['$u\\.local\\bin', '$u\\.bun\\bin', '$u\\scoop\\shims'],
    ];
  }
  String expand(String p) => p.startsWith('~/') ? '$home${p.substring(1)}' : p;
  String? npmPrefix() {
    if (nonEmpty(env['NPM_CONFIG_PREFIX'] ?? env['npm_config_prefix']) case final p?) return expand(p);
    for (final line in (readFile('$home/.npmrc') ?? '').split('\n')) {
      final m = RegExp(r'^\s*prefix\s*=\s*(.+?)\s*$').firstMatch(line);
      if (m != null) return expand(m.group(1)!.replaceAll('"', ''));
    }
    return null;
  }

  String? nvmBin() {
    final nvm = nonEmpty(env['NVM_DIR']) ?? '$home/.nvm';
    final versions = '$nvm/versions/node';
    final alias = nonEmpty(readFile('$nvm/alias/default'));
    if (alias != null && RegExp(r'^v?\d+\.\d+\.\d+$').hasMatch(alias)) {
      final dir = '$versions/${alias.startsWith('v') ? alias : 'v$alias'}/bin';
      if (has(dir)) return dir;
    }
    List<int> parts(String v) => [for (final p in v.replaceFirst('v', '').split('.')) int.tryParse(p) ?? 0];
    int newer(String a, String b) {
      final (x, y) = (parts(a), parts(b));
      for (var i = 0; i < 3 && i < x.length && i < y.length; i++) {
        if (x[i] != y[i]) return x[i].compareTo(y[i]);
      }
      return 0;
    }

    final found = entries(versions).where((v) => RegExp(r'^v\d+\.\d+\.\d+$').hasMatch(v)).toList()..sort(newer);
    return found.isEmpty ? null : '$versions/${found.last}/bin';
  }

  return [
    '/opt/homebrew/bin',
    '/usr/local/bin',
    '$home/.local/bin',
    '$home/.npm-global/bin',
    if (npmPrefix() case final p?) '$p/bin',
    ?nvmBin(),
    '$home/.bun/bin',
    '$home/.cargo/bin',
    '$home/.volta/bin',
    '$home/.deno/bin',
    '$home/.cursor/bin',
  ];
}

/// [path] with [extra] directories after it, each kept once (the first
/// time it appears), so the user's own order wins.
String mergePaths(String path, List<String> extra, {bool windows = false}) {
  final sep = windows ? ';' : ':';
  final seen = <String>{};
  return [
    for (final d in [...path.split(sep), ...extra])
      if (d.isNotEmpty && seen.add(windows ? d.toLowerCase() : d)) d,
  ].join(sep);
}

/// What a finished command printed (stdout and stderr interleaved).
final class CommandResult {
  const CommandResult({required this.output, required this.exitCode, this.timedOut = false, this.cancelled = false});
  final String output;
  final int exitCode;
  final bool timedOut;
  final bool cancelled;
}

/// Runs a session's commands: each in a fresh login-environment shell, in
/// the directory the previous one ended in (so `cd` carries over), tagged
/// with the session so Stop can find leftovers.
final class SessionShell {
  SessionShell({required this.root, required this.sessionTag, required this.scratchDir}) : cwd = root;

  final String root;
  final String sessionTag;

  /// Where wrapper state (the last directory) is kept.
  final String scratchDir;
  String cwd;

  final _background = <String, BackgroundShell>{};
  int _nextBg = 1;
  final _running = <Process>{};

  Iterable<BackgroundShell> get background => _background.values;

  /// Processes this session started that are still alive: its commands and
  /// background shells, and everything under them.
  Future<Set<int>> processes() async {
    final roots = [for (final p in _running) p.pid, for (final b in _background.values) b.pid];
    final out = <int>{};
    for (final r in roots) {
      out
        ..add(r)
        ..addAll(await _descendants(r));
    }
    return out;
  }

  BackgroundShell? backgroundShell(String id) => _background[id];

  Future<Map<String, String>> _env() async => {...(await ShellEnv.load()).env, sessionEnvVar: sessionTag};

  String _cwdFile(String id) => '$scratchDir/.cwd-$id';

  /// The script run for [command]: in the current directory, and it records
  /// the directory it ends in.
  String _wrap(String command, String cwdFile) {
    final quoted = cwd.replaceAll("'", r"'\''");
    return "cd '$quoted' 2>/dev/null || cd ~\n"
        '{\n$command\n} < /dev/null 2>&1\n'
        '__everyai_status=\$?\n'
        "pwd -P > '${cwdFile.replaceAll("'", r"'\''")}' 2>/dev/null\n"
        'exit \$__everyai_status\n';
  }

  /// Runs [command] to completion, or until [timeout] (then the whole
  /// process tree is killed) or [cancel] completes.
  Future<CommandResult> run(String command, {required Duration timeout, Future<void>? cancel}) async {
    Directory(scratchDir).createSync(recursive: true);
    final id = '${DateTime.now().microsecondsSinceEpoch}';
    final cwdFile = _cwdFile(id);
    final env = await _env();
    final shell = (await ShellEnv.load()).shell;
    final process = await Process.start(
      shell,
      ['-c', _wrap(command, cwdFile)],
      environment: env,
      workingDirectory: Directory(cwd).existsSync() ? cwd : root,
    );
    _running.add(process);
    final out = _CappedBuffer(4 * 1024 * 1024);
    final done = Completer<void>();
    var pending = 2;
    void closed() {
      if (--pending == 0 && !done.isCompleted) done.complete();
    }

    process.stdout.transform(const Utf8Decoder(allowMalformed: true)).listen(out.add, onDone: closed);
    process.stderr.transform(const Utf8Decoder(allowMalformed: true)).listen(out.add, onDone: closed);
    var timedOut = false, cancelled = false;
    final exit = await Future.any<int?>([
      process.exitCode,
      Future<int?>.delayed(timeout, () {
        timedOut = true;
        return null;
      }),
      if (cancel != null)
        cancel.then((_) {
          cancelled = true;
          return null;
        }),
    ]);
    if (exit == null) await killTree(process.pid);
    final code = exit ?? await process.exitCode.timeout(const Duration(seconds: 3), onTimeout: () => -9);
    await done.future.timeout(const Duration(seconds: 2), onTimeout: () {});
    _running.remove(process);
    final ended = File(cwdFile);
    if (ended.existsSync()) {
      final dir = ended.readAsStringSync().trim();
      if (dir.isNotEmpty && Directory(dir).existsSync()) cwd = dir;
      ended.deleteSync();
    }
    return CommandResult(output: out.text, exitCode: code, timedOut: timedOut, cancelled: cancelled);
  }

  /// Starts [command] in the background; its output collects in the
  /// returned shell until it ends or is killed.
  Future<BackgroundShell> start(String command, {String description = ''}) async {
    Directory(scratchDir).createSync(recursive: true);
    final id = 'bg_${_nextBg++}';
    final env = await _env();
    final shell = (await ShellEnv.load()).shell;
    final process = await Process.start(
      shell,
      ['-c', _wrap(command, _cwdFile(id))],
      environment: env,
      workingDirectory: Directory(cwd).existsSync() ? cwd : root,
    );
    final bg = BackgroundShell._(id, command, description, process);
    _background[id] = bg;
    return bg;
  }

  /// Kills every command still running (foreground and background).
  Future<void> killAll() async {
    for (final p in [..._running]) {
      await killTree(p.pid);
    }
    for (final b in _background.values) {
      await b.kill();
    }
  }
}

/// A command left running in the background.
final class BackgroundShell {
  BackgroundShell._(this.id, this.command, this.description, this._process) {
    _process.stdout.transform(const Utf8Decoder(allowMalformed: true)).listen(_add);
    _process.stderr.transform(const Utf8Decoder(allowMalformed: true)).listen(_add);
    unawaited(
      _process.exitCode.then((c) {
        exitCode = c;
        _changes.add(null);
      }),
    );
  }

  final String id;
  final String command;
  final String description;
  final Process _process;
  final _out = _CappedBuffer(2 * 1024 * 1024);
  final _changes = StreamController<void>.broadcast();
  final startedAt = DateTime.now();

  /// Set once it ended.
  int? exitCode;

  /// How much output was read so far (by `bash_output`).
  int readTo = 0;

  int get pid => _process.pid;
  bool get running => exitCode == null;
  String get output => _out.text;

  /// Fires on new output and on exit.
  Stream<void> get changes => _changes.stream;

  void _add(String s) {
    _out.add(s);
    _changes.add(null);
  }

  /// Output since the last read, and moves the read mark.
  String takeNew() {
    final all = _out.text;
    final from = readTo.clamp(0, all.length);
    readTo = all.length;
    return all.substring(from);
  }

  Future<void> kill() async {
    if (!running) return;
    await killTree(_process.pid);
  }
}

/// Signals [pid] and every process below it: TERM, then KILL for whatever
/// is left a moment later.
Future<void> killTree(int pid) async {
  final pids = await _descendants(pid);
  final all = [pid, ...pids];
  for (final p in all.reversed) {
    Process.killPid(p, ProcessSignal.sigterm);
  }
  await Future<void>.delayed(const Duration(milliseconds: 600));
  for (final p in all.reversed) {
    Process.killPid(p, ProcessSignal.sigkill);
  }
}

Future<List<int>> _descendants(int root) async {
  if (Platform.isWindows) return const [];
  try {
    final res = await Process.run('ps', ['-A', '-o', 'pid=,ppid=']);
    final children = <int, List<int>>{};
    for (final line in const LineSplitter().convert(res.stdout as String)) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length < 2) continue;
      final pid = int.tryParse(parts[0]), ppid = int.tryParse(parts[1]);
      if (pid == null || ppid == null) continue;
      children.putIfAbsent(ppid, () => []).add(pid);
    }
    final out = <int>[];
    final queue = [root];
    while (queue.isNotEmpty) {
      for (final c in children[queue.removeLast()] ?? const <int>[]) {
        out.add(c);
        queue.add(c);
      }
    }
    return out;
  } on Object {
    return const [];
  }
}

/// Text that keeps its first half and its newest output once over [cap].
final class _CappedBuffer {
  _CappedBuffer(this.cap);
  final int cap;
  final _head = StringBuffer();
  final _tail = <String>[];
  int _tailLength = 0;
  bool _cut = false;

  void add(String s) {
    if (_head.length < cap ~/ 2) {
      final room = cap ~/ 2 - _head.length;
      if (s.length <= room) {
        _head.write(s);
        return;
      }
      _head.write(s.substring(0, room));
      s = s.substring(room);
    }
    _tail.add(s);
    _tailLength += s.length;
    while (_tailLength > cap ~/ 2 && _tail.length > 1) {
      _tailLength -= _tail.removeAt(0).length;
      _cut = true;
    }
  }

  String get text => _cut ? '$_head\n[… output cut …]\n${_tail.join()}' : '$_head${_tail.join()}';
}
