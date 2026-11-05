import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'git_guard.dart';
import 'git_models.dart';
import 'git_service.dart' show GitError;

export 'repo_check_io.dart' show checkRepo;

/// Subcommands that run no repository program (with [guardFlags] on), so they skip the config read.
const _plain = {
  'rev-parse', 'config', 'symbolic-ref', 'check-ref-format', 'show-ref', 'for-each-ref', 'update-ref', //
  'rev-list', 'branch', 'remote', 'log', 'read-tree', 'write-tree', 'check-ignore', 'merge-file',
};

/// The full argument list for an EveryAI git call in [dir]: [guardFlags], the overrides for programs the
/// repository's own config names ([repoGuard]), then [args], diffs with [diffFlags]. Throws [GitError] when the
/// repository can't be guarded.
Future<List<String>> guardedArgs(String dir, List<String> args) async {
  final fixed = guardFlags(Platform.isWindows ? 'NUL' : '/dev/null');
  final cmd = args.isEmpty ? '' : args.first;
  final call = [
    if (cmd == 'diff' || cmd == 'show') ...[cmd, ...diffFlags, ...args.skip(1)] else ...args,
  ];
  if (_plain.contains(cmd)) return ['-C', dir, ...fixed, ...call];
  final res = await Process.run('git', ['-C', dir, ...fixed, 'config', '--list', '--show-scope', '-z']);
  if (res.exitCode != 0) {
    final err = '${res.stderr}'.trim();
    // --show-scope came in git 2.26; without it the repository's config can't be told from the user's.
    if (err.contains('show-scope')) throw const GitError('EveryAI needs git 2.26 or later: update git and try again.');
    throw GitError('git config: $err');
  }
  final guard = repoGuard(parseConfigList('${res.stdout}'));
  if (guard.refusal case final why?) throw GitError(why);
  return ['-C', dir, ...fixed, ...guard.args, ...call];
}

/// Runs git in [dir] the way EveryAI's own calls do: nothing the repository defines runs (see `git_guard.dart`).
Future<ProcessResult> runGit(String dir, List<String> args, {Map<String, String>? env}) async =>
    Process.run('git', await guardedArgs(dir, args), environment: env);

Future<ProcessResult> _git(String dir, List<String> args, {Map<String, String>? env, bool check = true}) async {
  final res = await runGit(dir, args, env: env);
  if (check && res.exitCode != 0) {
    final err = '${res.stderr}'.trim();
    throw GitError('git ${args.first}: ${err.isEmpty ? '${res.stdout}'.trim() : err}');
  }
  return res;
}

Future<String> _out(String dir, List<String> args, {Map<String, String>? env}) async =>
    '${(await _git(dir, args, env: env)).stdout}'.trim();

Future<String> dataDir() async => (await getApplicationSupportDirectory()).path;

Future<List<String>> worktrees(String dir) async {
  try {
    final res = await _git(dir, ['worktree', 'list', '--porcelain'], check: false);
    if (res.exitCode != 0) return const [];
    return worktreePaths('${res.stdout}');
  } on Object {
    return const [];
  }
}

/// The paths in `git worktree list --porcelain` output (prunable and bare entries left out).
List<String> worktreePaths(String porcelain) {
  final out = <String>[];
  for (final block in porcelain.split(RegExp(r'\n\s*\n'))) {
    final lines = block.split('\n');
    final path = lines.firstWhere((l) => l.startsWith('worktree '), orElse: () => '');
    if (path.isEmpty || lines.any((l) => l == 'bare' || l.startsWith('prunable'))) continue;
    out.add(path.substring('worktree '.length).trim());
  }
  return out;
}

Future<String?> repoRoot(String dir) async {
  try {
    final res = await _git(dir, ['rev-parse', '--show-toplevel'], check: false);
    if (res.exitCode != 0) return null;
    final root = '${res.stdout}'.trim();
    // A dotfiles repo at the home folder or above isn't the project's: snapshots
    // and worktrees of it would copy the whole home folder.
    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty && (home == root || home.startsWith('$root/'))) return null;
    return root;
  } on ProcessException {
    return null;
  }
}

Future<bool> hasCommits(String repoRoot) async {
  try {
    return (await _git(repoRoot, ['rev-parse', '--verify', '--quiet', 'HEAD^{commit}'], check: false)).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

Future<SessionWorktree> createWorktree({
  required String repoRoot,
  required String slug,
  required String worktreesDir,
  required String hooksDir,
}) async {
  final baseBranch = await _out(repoRoot, ['branch', '--show-current']);
  final baseCommit = await _out(repoRoot, ['rev-parse', 'HEAD']);
  final path = '$worktreesDir/$slug';
  final branch = 'everyai/$slug';
  await Directory(worktreesDir).create(recursive: true);
  await _git(repoRoot, ['worktree', 'add', '-q', '-b', branch, path, baseCommit]);
  final w = SessionWorktree(
    repoRoot: repoRoot,
    path: path,
    branch: branch,
    baseBranch: baseBranch,
    baseCommit: baseCommit,
  );
  await _installHooks(w, hooksDir);
  return w;
}

/// Points the worktree at EveryAI's hooks: commit-msg strips AI-credit
/// lines; every hook then runs the repository's own one. They are for the
/// agent's own git commands: EveryAI's calls run no hooks (`git_guard.dart`).
Future<void> _installHooks(SessionWorktree w, String hooksDir) async {
  // Without guardFlags, whose hooksPath would come back (`git config` runs nothing).
  final configured = await Process.run('git', ['-C', w.repoRoot, 'config', '--get', 'core.hooksPath']);
  final common = await _out(w.repoRoot, ['rev-parse', '--path-format=absolute', '--git-common-dir']);
  final custom = '${configured.stdout}'.trim();
  // A relative hooksPath (husky) is relative to the checkout the hook runs in.
  final original = custom.isEmpty
      ? "'$common/hooks'"
      : custom.startsWith('/')
      ? "'$custom'"
      : '"\$(git rev-parse --show-toplevel)/$custom"';
  final dir = Directory('$hooksDir/${w.slug}');
  await dir.create(recursive: true);
  for (final name in _hookNames) {
    final strip = name == 'commit-msg'
        ? 'grep -Eiv \'$_brandingPattern\' "\$1" > "\$1.everyai"; mv "\$1.everyai" "\$1"\n'
        : '';
    final f = File('${dir.path}/$name');
    await f.writeAsString(
      '#!/bin/sh\n# EveryAI session hook${name == 'commit-msg' ? ': keeps AI credits out of commit messages' : ''}.\n'
      '$strip'
      'orig=$original/$name\n'
      '[ -x "\$orig" ] && exec "\$orig" "\$@"\n'
      'exit 0\n',
    );
    await Process.run('chmod', ['+x', f.path]);
  }
  await _git(w.repoRoot, ['config', 'extensions.worktreeConfig', 'true']);
  await _git(w.path, ['config', '--worktree', 'core.hooksPath', dir.path]);
}

/// The POSIX ERE twin of `brandingLine`.
const _brandingPattern =
    r'^[[:space:]]*(co-authored-by|signed-off-by)[[:space:]]*:.*(openhands|all-hands|claude|anthropic|everyai|openai|chatgpt|gpt-|copilot|cursor|gemini|codex|\[bot\])'
    r'|generated (with|by) .*(openhands|claude|everyai|copilot|chatgpt|codex|cursor|gemini)'
    '|🤖';

const _hookNames = [
  'applypatch-msg', 'pre-applypatch', 'post-applypatch', 'pre-commit', 'pre-merge-commit', 'prepare-commit-msg', //
  'commit-msg', 'post-commit', 'pre-rebase', 'post-checkout', 'post-merge', 'pre-push', 'post-rewrite',
  'reference-transaction', 'pre-auto-gc', 'push-to-checkout',
];

/// Runs [run] with a throwaway index holding the whole working tree
/// (untracked files included), so the user's staging area is untouched.
Future<T> _withSnapshot<T>(SessionWorktree w, Future<T> Function(Map<String, String> env) run) async {
  final tmp = await Directory.systemTemp.createTemp('everyai-index');
  final env = {'GIT_INDEX_FILE': '${tmp.path}/index'};
  try {
    // A repository with no commit yet starts from nothing.
    final head = await _git(w.path, ['rev-parse', '--verify', '-q', 'HEAD'], check: false);
    await _git(w.path, head.exitCode == 0 ? ['read-tree', 'HEAD'] : ['read-tree', '--empty'], env: env);
    await _git(w.path, ['add', '-A'], env: env);
    return await run(env);
  } finally {
    await tmp.delete(recursive: true);
  }
}

Future<GitBaseline?> baseline(String dir) async {
  final root = await repoRoot(dir);
  if (root == null) return null;
  // No commit yet (a fresh `git init`): everything the session makes is new.
  final commit = await hasCommits(root) ? (await _out(root, ['rev-parse', 'HEAD'])).trim() : _emptyTree;
  final branch = (await _git(root, ['symbolic-ref', '--short', '-q', 'HEAD'], check: false)).stdout.toString().trim();
  final view = SessionWorktree(repoRoot: root, path: dir, branch: branch, baseBranch: branch, baseCommit: commit);
  final tree = await _withSnapshot(view, (env) async => (await _out(dir, ['write-tree'], env: env)).trim());
  return GitBaseline(repoRoot: root, dir: dir, branch: branch, commit: commit, tree: tree);
}

Future<List<FileChange>> changes(SessionWorktree w) => _withSnapshot(w, (env) async {
  final status = await _out(w.path, ['diff', '--cached', '-M', '--name-status', w.baseCommit], env: env);
  final numstat = await _out(w.path, ['diff', '--cached', '-M', '--numstat', w.baseCommit], env: env);
  final counts = <String, (int, int)>{};
  for (final line in const LineSplitter().convert(numstat)) {
    final parts = line.split('\t');
    if (parts.length < 3) continue;
    counts[parts.last] = (int.tryParse(parts[0]) ?? 0, int.tryParse(parts[1]) ?? 0);
  }
  return [
    for (final line in const LineSplitter().convert(status))
      if (line.split('\t') case [final code, ..., final path])
        FileChange(
          path,
          switch (code[0]) {
            'A' => ChangeKind.added,
            'D' => ChangeKind.deleted,
            'R' => ChangeKind.renamed,
            _ => ChangeKind.modified,
          },
          added: counts[path]?.$1 ?? 0,
          removed: counts[path]?.$2 ?? 0,
        ),
  ];
});

Future<List<FileDiff>> diff(SessionWorktree w) => _withSnapshot(w, (env) async {
  final res = await _git(w.path, ['diff', '--cached', '-M', '--no-color', w.baseCommit], env: env);
  return parseUnifiedDiff('${res.stdout}');
});

Future<List<FileDiff>> uncommittedDiff(SessionWorktree w) => _withSnapshot(w, (env) async {
  final res = await _git(w.path, ['diff', '--cached', '-M', '--no-color', 'HEAD'], env: env);
  return parseUnifiedDiff('${res.stdout}');
});

Future<List<String>> commitSubjects(SessionWorktree w) async {
  final out = await _out(w.path, ['log', '--format=%s', '${w.baseCommit}..HEAD']);
  return [
    for (final l in const LineSplitter().convert(out))
      if (l.trim().isNotEmpty) l.trim(),
  ];
}

Future<String> remoteUrl(SessionWorktree w) async {
  final res = await _git(w.path, ['remote', 'get-url', 'origin'], check: false);
  return res.exitCode == 0 ? '${res.stdout}'.trim() : '';
}

Future<bool> isDirty(SessionWorktree w) async => (await _out(w.path, ['status', '--porcelain'])).isNotEmpty;

Future<String> headCommit(SessionWorktree w) => _out(w.path, ['rev-parse', 'HEAD']);

Future<BranchPr?> prFor(SessionWorktree w) async {
  try {
    final res = await Process.run('gh', [
      'pr',
      'view',
      w.branch,
      '--json',
      'number,url,state,headRefOid',
    ], workingDirectory: w.path);
    // Non-zero: no pull request for the branch, no remote, or gh isn't signed in.
    return res.exitCode == 0 ? parsePrView('${res.stdout}') : null;
  } on ProcessException {
    return null;
  }
}

Future<bool> ghReady(String dir) async {
  try {
    final res = await Process.run('gh', ['auth', 'status'], workingDirectory: dir);
    return res.exitCode == 0;
  } on ProcessException {
    return false;
  }
}

Future<Set<String>> ignoredAmong(String dir, List<String> paths) async {
  if (paths.isEmpty) return const {};
  try {
    final p = await Process.start('git', await guardedArgs(dir, ['check-ignore', '--stdin', '-z']));
    p.stdin.write('${paths.join('\x00')}\x00');
    await p.stdin.close();
    final (out, _, code) = await (p.stdout.transform(utf8.decoder).join(), p.stderr.drain<void>(), p.exitCode).wait;
    // 1: none ignored; 128: not a repository.
    if (code != 0) return const {};
    return {
      for (final path in out.split('\x00'))
        if (path.isNotEmpty) path,
    };
  } on Object {
    return const {};
  }
}

Future<void> revertHunk(SessionWorktree w, FileDiff file, int hunk) async {
  final p = await Process.start('git', await guardedArgs(w.path, ['apply', '-R', '--whitespace=nowarn', '-']));
  p.stdin.write(file.patchFor(hunk));
  await p.stdin.close();
  final err = await p.stderr.transform(utf8.decoder).join();
  if (await p.exitCode != 0) throw GitError("Couldn't revert that change: ${err.trim()}");
}

/// Stages [paths] (everything when null).
Future<void> _stage(SessionWorktree w, List<String>? paths) => _git(w.path, [
  'add',
  '-A',
  if (paths != null) ...['--', ...paths],
]);

Future<bool> _hasStaged(SessionWorktree w) async =>
    (await _git(w.path, ['diff', '--cached', '--quiet'], check: false)).exitCode != 0;

/// Commits [paths] (everything when null); false when there was nothing to commit.
Future<bool> commitAll(SessionWorktree w, String message, {List<String>? paths}) async {
  await _stage(w, paths);
  if (!await _hasStaged(w)) return false;
  // EveryAI's own commits skip the hooks, the session's commit-msg one too: its job is done here.
  await _git(w.path, [
    'commit',
    '-q',
    '-m',
    stripBranding(message),
    if (paths != null) ...['--', ...paths],
  ]);
  return true;
}

/// Switches to new branch [branch] (the changes come along) and commits [paths] there (everything when null);
/// returns the commit, or null when there was nothing to commit. A name git refuses, a branch that exists, an
/// empty commit and a failed commit all leave the checkout on the branch it was on, with no new branch.
Future<String?> commitOnNewBranch(SessionWorktree w, String branch, String message, {List<String>? paths}) async {
  final name = branch.trim();
  if ((await _git(w.path, ['check-ref-format', '--branch', name], check: false)).exitCode != 0 ||
      name.startsWith('-')) {
    throw GitError('"$name" is not a branch name git accepts.');
  }
  if ((await _git(w.path, ['show-ref', '--verify', '--quiet', 'refs/heads/$name'], check: false)).exitCode == 0) {
    throw GitError('There is a branch called $name already.');
  }
  await _stage(w, paths);
  if (!await _hasStaged(w)) return null;
  final before = await _out(w.path, ['branch', '--show-current']);
  await _git(w.path, ['switch', '-q', '-c', name]);
  try {
    await _git(w.path, [
      'commit',
      '-q',
      '-m',
      stripBranding(message),
      if (paths != null) ...['--', ...paths],
    ]);
  } on Object {
    // Back where it was, the new branch gone, so the same try can run again.
    await _git(w.path, before.isEmpty ? ['switch', '-q', '--detach', '-'] : ['switch', '-q', before], check: false);
    await _git(w.path, ['branch', '-q', '-D', name], check: false);
    rethrow;
  }
  return headCommit(w);
}

/// The tree of everything in the folder right now (untracked files too, ignored ones not).
Future<String> snapshotTree(SessionWorktree w) =>
    _withSnapshot(w, (env) async => (await _out(w.path, ['write-tree'], env: env)).trim());

/// The paths whose content differs between snapshot [tree] and the folder now.
Future<List<String>> changedSince(SessionWorktree w, String tree) => _withSnapshot(w, (env) async {
  final out = await _out(w.path, ['diff', '--cached', '--name-only', '--no-renames', '-z', tree], env: env);
  return [
    for (final p in out.split('\x00'))
      if (p.isNotEmpty) p,
  ];
});

/// Whether any of [paths] has changes not committed.
Future<bool> isDirtyAmong(SessionWorktree w, List<String> paths) async =>
    paths.isNotEmpty && (await _out(w.path, ['status', '--porcelain', '--', ...paths])).isNotEmpty;

Future<String> checkpoint(SessionWorktree w, int turn) => _withSnapshot(w, (env) async {
  final tree = await _out(w.path, ['write-tree'], env: env);
  final sha = await _out(w.path, ['commit-tree', tree, '-p', 'HEAD', '-m', 'EveryAI checkpoint before turn $turn']);
  final ref = 'refs/everyai/${w.slug}/turn-$turn';
  await _git(w.path, ['update-ref', ref, sha]);
  return ref;
});

Future<void> restoreCheckpoint(SessionWorktree w, String ref) async {
  // Nothing is touched without a checkpoint to restore from: cleaning first
  // would delete untracked files and then have nothing to put back.
  try {
    await _git(w.path, ['rev-parse', '--verify', '--quiet', '$ref^{commit}']);
  } on Object {
    throw const GitError('There is no checkpoint for that turn, so the files were left as they are.');
  }
  // Untracked files the checkpoint has are restored from it below.
  await _git(w.path, ['clean', '-fdq']);
  await _git(w.path, ['restore', '--source=$ref', '--worktree', '--', ':/']);
}

Future<({int ahead, int behind})> aheadBehind(SessionWorktree w) async {
  final counts = await _out(w.path, ['rev-list', '--left-right', '--count', '${w.baseBranch}...HEAD']);
  final [behind, ahead] = counts.split(RegExp(r'\s+')).map(int.parse).toList();
  return (ahead: ahead, behind: behind);
}

Future<String> squashMerge(SessionWorktree w, String message) async {
  final dirty = await _out(w.repoRoot, ['status', '--porcelain', '--untracked-files=no']);
  if (dirty.isNotEmpty) {
    throw const GitError('Your main checkout has uncommitted changes. Commit or stash them, then merge again.');
  }
  final current = await _out(w.repoRoot, ['branch', '--show-current']);
  if (current != w.baseBranch) {
    throw GitError('Your main checkout is on $current. Switch it to ${w.baseBranch} to merge this session.');
  }
  await commitAll(w, message);
  await _git(w.repoRoot, ['merge', '--squash', '-q', w.branch]);
  final staged = await _git(w.repoRoot, ['diff', '--cached', '--quiet'], check: false);
  if (staged.exitCode == 0) throw const GitError('There is nothing to merge: the session made no changes.');
  await _git(w.repoRoot, ['commit', '-q', '-m', stripBranding(message)]);
  return _out(w.repoRoot, ['rev-parse', 'HEAD']);
}

/// Pushes the session branch. Not to a folder on this computer: git runs that repository's own hooks (and a
/// `receivepack` the repository sets) here, with none of EveryAI's flags.
Future<void> push(SessionWorktree w) async {
  final res = await _git(w.path, [
    '-c',
    'protocol.file.allow=never',
    'push',
    '-q',
    '-u',
    'origin',
    w.branch,
  ], check: false);
  if (res.exitCode == 0) return;
  final err = '${res.stderr}'.trim();
  if (err.contains("transport 'file' not allowed")) {
    throw const GitError(
      'EveryAI doesn\'t push to a folder on this computer, since the repository there can run its own hooks. '
      'Push from a terminal instead.',
    );
  }
  throw GitError('git push: $err');
}

Future<String> createPr(SessionWorktree w, {required String title, required String body}) async {
  final ProcessResult res;
  try {
    res = await Process.run('gh', [
      'pr',
      'create',
      '--head',
      w.branch,
      '--base',
      w.baseBranch,
      '--title',
      title,
      '--body',
      body,
    ], workingDirectory: w.path);
  } on ProcessException {
    throw const GitError('Creating a pull request needs the GitHub CLI: install gh and run `gh auth login`.');
  }
  if (res.exitCode != 0) throw GitError("Couldn't create the pull request: ${'${res.stderr}'.trim()}");
  return '${res.stdout}'.trim().split('\n').last;
}

Future<void> removeWorktree(SessionWorktree w, {required String hooksDir, bool deleteBranch = true}) async {
  await _git(w.repoRoot, ['worktree', 'remove', '--force', w.path], check: false);
  await _git(w.repoRoot, ['worktree', 'prune'], check: false);
  if (deleteBranch) await _git(w.repoRoot, ['branch', '-q', '-D', w.branch], check: false);
  final refs = await _git(w.repoRoot, ['for-each-ref', '--format=%(refname)', 'refs/everyai/${w.slug}/'], check: false);
  for (final ref in const LineSplitter().convert('${refs.stdout}')) {
    if (ref.isNotEmpty) await _git(w.repoRoot, ['update-ref', '-d', ref], check: false);
  }
  final hooks = Directory('$hooksDir/${w.slug}');
  if (hooks.existsSync()) await hooks.delete(recursive: true);
}

// ------------------------------------------------------------------ forks

/// Dependency folders a fork borrows from its parent instead of reinstalling.
const _borrowed = ['node_modules', '.venv', 'venv'];

Future<ForkCopy?> forkCopy(String dir, {required String worktreesDir, required String slug}) async {
  final root = await repoRoot(dir);
  if (root == null) return null;
  // A fresh `git init` with no commit yet still gets a fork: its base has no parent.
  final head = await hasCommits(root) ? (await _out(root, ['rev-parse', 'HEAD'])).trim() : null;
  final view = SessionWorktree(repoRoot: root, path: dir, branch: '', baseBranch: '', baseCommit: head ?? _emptyTree);
  final tree = await _withSnapshot(view, (env) async => (await _out(dir, ['write-tree'], env: env)).trim());
  final base = (await _out(root, [
    '-c', 'user.name=EveryAI', '-c', 'user.email=agent@everyai.invalid', //
    'commit-tree', tree, if (head != null) ...['-p', head], '-m', 'EveryAI fork base',
  ])).trim();
  final wt = '$worktreesDir/$slug';
  await Directory(worktreesDir).create(recursive: true);
  await _git(root, ['worktree', 'add', '-q', '--detach', wt, base]);
  // Asked of git: [dir] may reach the repository through a symlink.
  var rel = (await _out(dir, ['rev-parse', '--show-prefix'])).trim();
  if (rel.endsWith('/')) rel = rel.substring(0, rel.length - 1);
  final path = rel.isEmpty ? wt : '$wt/$rel';
  final links = <String>[];
  for (final (from, to, prefix) in [(dir, path, rel), if (rel.isNotEmpty) (root, wt, '')]) {
    for (final name in _borrowed) {
      if (Directory('$from/$name').existsSync() &&
          !FileSystemEntity.isLinkSync('$from/$name') &&
          !Directory('$to/$name').existsSync()) {
        await Link('$to/$name').create('$from/$name');
        links.add(prefix.isEmpty ? name : '$prefix/$name');
      }
    }
  }
  return ForkCopy(repoRoot: root, root: wt, path: path, base: base, links: links);
}

Future<List<int>?> _blob(String root, String rev, String path) async {
  final res = await Process.run('git', await guardedArgs(root, ['show', '$rev:$path']), stdoutEncoding: null);
  return res.exitCode == 0 ? res.stdout as List<int> : null;
}

bool _sameBytes(List<int>? a, List<int>? b) {
  if (a == null || b == null) return a == b;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _binary(List<int>? b) => b != null && b.take(8000).contains(0);

Future<ForkMerge> mergeFork(ForkCopy copy, {required String slug, bool merge = true}) async {
  final ref = 'refs/everyai/forks/$slug';
  final wt = copy.root;
  // Everything the fork left, minus the borrowed dependency links.
  await _git(wt, ['add', '-A', '--', '.', for (final l in copy.links) ':(exclude)$l']);
  await _git(wt, [
    '-c', 'user.name=EveryAI', '-c', 'user.email=agent@everyai.invalid', //
    'commit', '-q', '--no-verify', '-m', 'EveryAI fork',
  ], check: false);
  final tip = (await _out(wt, ['rev-parse', 'HEAD'])).trim();
  await _git(copy.repoRoot, ['update-ref', ref, tip]);
  final merged = <String>[];
  final conflicts = <String>[];
  if (merge && tip != copy.base) {
    final changed = await _out(copy.repoRoot, ['diff', '--name-status', '--no-renames', copy.base, tip]);
    final tmp = await Directory.systemTemp.createTemp('everyai-merge');
    try {
      for (final line in const LineSplitter().convert(changed)) {
        final parts = line.split('\t');
        if (parts.length < 2) continue;
        final path = parts.last;
        final target = File('${copy.repoRoot}/$path');
        final ours = target.existsSync() ? await target.readAsBytes() : null;
        final base = await _blob(copy.repoRoot, copy.base, path);
        final theirs = await _blob(copy.repoRoot, tip, path);
        if (_sameBytes(ours, theirs)) {
          merged.add(path);
        } else if (_sameBytes(ours, base)) {
          // Only the fork changed it.
          if (theirs == null) {
            if (target.existsSync()) await target.delete();
          } else {
            await target.parent.create(recursive: true);
            await target.writeAsBytes(theirs);
          }
          merged.add(path);
        } else if (ours == null || theirs == null || _binary(ours) || _binary(theirs) || _binary(base)) {
          // Both changed it and it can't be merged line by line: the parent's version stays.
          conflicts.add(path);
        } else {
          final b = File('${tmp.path}/base')..writeAsBytesSync(base ?? const []);
          final t = File('${tmp.path}/theirs')..writeAsBytesSync(theirs);
          final res = await Process.run('git', [
            ...guardFlags(Platform.isWindows ? 'NUL' : '/dev/null'),
            'merge-file',
            '-p',
            '-L',
            'yours',
            '-L',
            'fork base',
            '-L',
            'fork',
            target.path,
            b.path,
            t.path,
          ], stdoutEncoding: null);
          if (res.exitCode < 0) {
            conflicts.add(path);
            continue;
          }
          await target.writeAsBytes(res.stdout as List<int>);
          (res.exitCode == 0 ? merged : conflicts).add(path);
        }
      }
    } finally {
      await tmp.delete(recursive: true);
    }
  }
  await _git(copy.repoRoot, ['worktree', 'remove', '--force', wt], check: false);
  return (merged: merged, conflicts: conflicts, ref: ref);
}

/// Git's empty tree, the base for a repository with no commit yet.
const _emptyTree = '4b825dc642cb6eb9a060e54bf8d69288fbee4904';
