import 'dart:convert';
import 'dart:io';

import 'git_guard.dart';
import 'repo_check.dart';

/// What in the project at [dir] can run code by itself (see [RepoFinding]).
/// Reads files and git's config only; runs nothing from the repository. Never
/// throws: what can't be read is left out.
Future<List<RepoFinding>> checkRepo(String dir) async {
  final out = <RepoFinding>[];
  Future<void> step(Future<void> Function() run) async {
    try {
      await run();
    } on Object {
      // Unreadable: nothing to report from it.
    }
  }

  final fixed = guardFlags(Platform.isWindows ? 'NUL' : '/dev/null');
  Future<ProcessResult> git(List<String> args) => Process.run('git', ['-C', dir, ...fixed, ...args]);

  // git answers with real paths (macOS temp folders are symlinks).
  var root = dir;
  var real = dir;
  await step(() async => real = await Directory(dir).resolveSymbolicLinks());
  await step(() async {
    final where = await git(['rev-parse', '--path-format=absolute', '--git-common-dir', '--show-toplevel']);
    if (where.exitCode != 0) return;
    final [common, top, ...] = const LineSplitter().convert('${where.stdout}');
    root = top;
    final entries = parseConfigList('${(await git(['config', '--list', '--show-scope', '-z'])).stdout}');
    final hooksPath = entries.where((e) => e.key == 'core.hookspath' && isRepoScope(e)).lastOrNull?.value;
    out.addAll(_hooks('$common/hooks', '${_rel(top, common)}/hooks'));
    if (hooksPath != null && hooksPath.isNotEmpty) {
      final abs = hooksPath.startsWith('/') ? hooksPath : '$top/$hooksPath';
      out.add(RepoFinding('git config core.hooksPath', 'hooks run from $hooksPath'));
      out.addAll(_hooks(abs, hooksPath));
    }
    for (final e in entries.where(isRepoProgram)) {
      // The refusal itself only shows when a checkpoint or commit fails, so the note says it up front.
      final off = blocksStoring(e) ? 'EveryAI\'s checkpoints and commits are off while it is set; ' : '';
      out.add(RepoFinding('git config ${e.key}', '${off}runs ${e.value}'));
    }
    if (File('$top/.gitmodules').existsSync()) {
      final mods = await git(['config', '--file', '$top/.gitmodules', '--list', '-z']);
      out.addAll(submoduleFindings('${mods.stdout}'));
    }
  });
  for (final at in {dir, if (root != real) root}) {
    // The repository's top, when the project is a folder inside it.
    final prefix = at == dir
        ? ''
        : real.startsWith('$at/')
        ? '../' * _rel(at, real).split('/').length
        : '$at/';
    await step(() async => out.addAll(fileFindings((p) => _read('$at/$p'), exists: (p) => _exists('$at/$p'), prefix)));
  }
  return out;
}

String? _read(String path) {
  final f = File(path);
  if (!f.existsSync() || f.lengthSync() > 1 << 20) return null;
  return f.readAsStringSync();
}

bool _exists(String path) => FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound;

/// [path] relative to [from] when inside it, else as it is.
String _rel(String from, String path) => path.startsWith('$from/') ? path.substring(from.length + 1) : path;

/// Executable hooks in [folder] (shown as [shown]); `.sample` files and other names never run.
List<RepoFinding> _hooks(String folder, String shown) {
  final d = Directory(folder);
  if (!d.existsSync()) return const [];
  return [
    for (final f in d.listSync().whereType<File>().toList()..sort((a, b) => a.path.compareTo(b.path)))
      if (gitHookNames.contains(f.uri.pathSegments.last) && f.statSync().mode & 0x49 != 0)
        RepoFinding('$shown/${f.uri.pathSegments.last}', 'git runs it ${_firstLines(_read(f.path) ?? '')}'.trim()),
  ];
}

String _firstLines(String text) {
  final lines = const LineSplitter().convert(text).where((l) => l.trim().isNotEmpty && !l.startsWith('#!')).take(3);
  return lines.isEmpty ? '' : '(${lines.join('; ')})';
}

final _okUrl = RegExp(r'^(https?://|ssh://|git://|git@[\w.-]+:|\.\.?/)');

/// Findings from `git config --file .gitmodules --list -z` output: the count, then entries that look made to
/// trick git (an odd transport, an option-like URL or path, a path climbing out with `..`).
List<RepoFinding> submoduleFindings(String z) {
  final byName = <String, Map<String, String>>{};
  for (final entry in z.split('\x00')) {
    final nl = entry.indexOf('\n');
    final key = nl < 0 ? entry : entry.substring(0, nl);
    final m = RegExp(r'^submodule\.(.+)\.(url|path)$').firstMatch(key);
    if (m == null) continue;
    byName.putIfAbsent(m[1]!, () => {})[m[2]!] = nl < 0 ? '' : entry.substring(nl + 1);
  }
  if (byName.isEmpty) return const [];
  return [
    RepoFinding(
      '.gitmodules',
      '${byName.length} submodule${byName.length == 1 ? '' : 's'}; EveryAI never fetches them',
    ),
    for (final MapEntry(key: name, value: v) in byName.entries)
      if (_oddSubmodule(name, v['path'] ?? '', v['url'] ?? ''))
        RepoFinding('.gitmodules', 'odd submodule "$name": path ${v['path'] ?? ''}, url ${v['url'] ?? ''}'),
  ];
}

bool _oddSubmodule(String name, String path, String url) =>
    !_okUrl.hasMatch(url) ||
    url.startsWith('-') ||
    path.startsWith('-') ||
    name.startsWith('-') ||
    path.split('/').contains('..') ||
    name.split('/').contains('..');

final _folderOpen = RegExp(r'"runOn"\s*:\s*"folderOpen"');
final _jsonString = r'"(?:[^"\\]|\\.)*"';
final _devCommand = RegExp(
  '"(initializeCommand|onCreateCommand|updateContentCommand|postCreateCommand|postStartCommand|postAttachCommand)"'
  '\\s*:\\s*($_jsonString|\\[[^\\]]*\\]|\\{[^}]*\\})',
);
final _taskCommand = RegExp('"command"\\s*:\\s*($_jsonString)');
const _installScripts = ['preinstall', 'install', 'postinstall', 'preprepare', 'prepare', 'postprepare'];

/// Findings from the project's own files, read through [read] (relative paths; null when missing) and [exists];
/// [prefix] goes in front of the paths shown.
List<RepoFinding> fileFindings(
  String? Function(String path) read,
  String prefix, {
  required bool Function(String path) exists,
}) {
  final out = <RepoFinding>[];
  if (read('.envrc') case final envrc?) {
    out.add(RepoFinding('$prefix.envrc', 'direnv runs it on entering the folder ${_firstLines(envrc)}'.trim()));
  }
  if (read('.vscode/tasks.json') case final tasks? when _folderOpen.hasMatch(tasks)) {
    final cmd = _taskCommand.firstMatch(tasks);
    out.add(
      RepoFinding('$prefix.vscode/tasks.json', 'a task runs when the folder opens${cmd == null ? '' : ': ${cmd[1]}'}'),
    );
  }
  for (final p in ['.devcontainer/devcontainer.json', '.devcontainer.json']) {
    for (final m in _devCommand.allMatches(read(p) ?? '')) {
      out.add(
        RepoFinding(
          '$prefix$p',
          '${m[1]} ${m[1] == 'initializeCommand' ? '(runs on this computer)' : '(runs in the container)'}: ${m[2]}',
        ),
      );
    }
  }
  if (read('package.json') case final pkg?) {
    try {
      final scripts = (jsonDecode(pkg) as Map<String, Object?>)['scripts'];
      if (scripts is Map<String, Object?>) {
        for (final k in _installScripts) {
          if (scripts[k] case final String cmd) out.add(RepoFinding('${prefix}package.json', 'script "$k": $cmd'));
        }
      }
    } on FormatException {
      // Not JSON: npm won't run it either.
    } on TypeError {
      // Not an object.
    }
  }
  for (final p in ['.opencode/plugin', '.opencode/plugins']) {
    if (exists(p)) out.add(RepoFinding('$prefix$p', 'OpenCode loads these plugins (code) when it starts here'));
  }
  for (final p in ['.mcp.json', '.gemini/settings.json', 'opencode.json', 'opencode.jsonc']) {
    if (exists(p)) out.add(RepoFinding('$prefix$p', 'an agent CLI config that can start programs'));
  }
  for (final p in ['.claude/settings.json', '.claude/settings.local.json']) {
    if (exists(p)) {
      out.add(
        RepoFinding('$prefix$p', 'Claude Code settings that can run hooks; EveryAI starts Claude Code without it'),
      );
    }
  }
  return out;
}
