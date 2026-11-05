/// Keeps EveryAI's own git calls from running code the repository defines.
///
/// A repository's `.git/config` and hooks can name programs git runs on the
/// commonest calls (`add`, `diff`, `worktree add`, `commit`, `push`): hooks,
/// `core.fsmonitor`, filters, merge drivers, `core.sshCommand`, gpg and
/// credential helpers. Anything that can write a file in the repo (the agent
/// in Full auto, an outside lead, an install script like husky's `prepare`)
/// can set them, and EveryAI's next checkpoint would run them outside every
/// approval. So every call EveryAI makes gets [guardFlags], and the calls that
/// can reach a program also get [repoGuard]'s overrides for what the repo's
/// own config (scope local or worktree; included files take their includer's
/// scope) sets. The user's global and system config are theirs and stay.
///
/// Diffs also need `--no-ext-diff --no-textconv` (a blank `diff.external` or
/// textconv is an error, so the flags are the only way); see [diffFlags].
library;

/// One `git config --list --show-scope` entry.
typedef GitConfigEntry = ({String scope, String key, String value});

/// Parses `git config --list --show-scope -z` output (`scope\0key\nvalue\0` per entry).
List<GitConfigEntry> parseConfigList(String z) {
  final parts = z.split('\x00');
  return [
    for (var i = 0; i + 1 < parts.length; i += 2)
      if (parts[i + 1].indexOf('\n') case final nl)
        (
          scope: parts[i],
          key: nl < 0 ? parts[i + 1] : parts[i + 1].substring(0, nl),
          value: nl < 0 ? '' : parts[i + 1].substring(nl + 1),
        ),
  ];
}

/// Flags on every EveryAI git call. [nullPath] is a hooks folder that can't
/// exist (`/dev/null`, `NUL` on Windows). `-c` beats repository and worktree
/// config and reaches child gits (receive-pack on a local push) through the
/// environment.
List<String> guardFlags(String nullPath) => [
  '-c', 'core.hooksPath=$nullPath', //
  '-c', 'core.fsmonitor=false',
  '-c', 'submodule.recurse=false',
  '-c', 'protocol.ext.allow=never',
  '-c', 'safe.bareRepository=explicit',
  '-c', 'log.showSignature=false',
];

/// What `git diff` (and `show`) also gets: no external diff tool, no textconv.
const diffFlags = ['--no-ext-diff', '--no-textconv'];

/// The hooks git knows; a file with another name in a hooks folder never runs.
const gitHookNames = [
  'applypatch-msg', 'pre-applypatch', 'post-applypatch', 'pre-commit', 'pre-merge-commit', 'prepare-commit-msg', //
  'commit-msg', 'post-commit', 'pre-rebase', 'post-checkout', 'post-merge', 'pre-push', 'post-rewrite',
  'reference-transaction', 'pre-auto-gc', 'push-to-checkout', 'fsmonitor-watchman', 'p4-changelist',
  'p4-prepare-changelist', 'p4-post-changelist', 'p4-pre-submit', 'post-index-change', 'sendemail-validate',
];

/// Whether [e] comes from the repository (its `.git/config`, a worktree's
/// config, or a file either includes) rather than the user.
bool isRepoScope(GitConfigEntry e) => e.scope == 'local' || e.scope == 'worktree';

/// Single-value program keys the repository may not set, with git's own
/// default. The user's global value wins over the default.
const _programDefaults = {
  'core.sshcommand': 'ssh',
  'core.askpass': '',
  'core.alternaterefscommand': '',
  'gpg.program': 'gpg',
  'gpg.openpgp.program': 'gpg',
  'gpg.x509.program': 'gpgsm',
  'gpg.ssh.program': 'ssh-keygen',
  'gpg.ssh.defaultkeycommand': '',
};

final _filterKey = RegExp(r'^filter\.(.+)\.(clean|smudge|process)$');
final _mergeDriver = RegExp(r'^merge\.(.+)\.driver$');
final _remotePack = RegExp(r'^remote\.(.+)\.(receivepack|uploadpack)$');
final _credentialHelper = RegExp(r'^credential\.(.+\.)?helper$');
final _diffProgram = RegExp(r'^diff\.(.+)\.(textconv|command)$');

// git-lfs's and git-crypt's own values (`git lfs install --local` and
// `git-crypt unlock` write them into the repository's config). git-crypt
// writes the absolute path it ran from, so only system install folders count.
final _knownFilter = RegExp(
  r'^(git-lfs (clean|smudge) -- %f|git-lfs filter-process'
  r'|"?((/usr|/usr/local|/opt/homebrew|/opt/local)/bin/|/nix/store/[^/" ]+/bin/)?git-crypt"? (clean|smudge|diff))$',
);

/// Whether the repository's [e] names a program git may run: hooks aside, the
/// keys [repoGuard] overrides plus the ones [guardFlags] and [diffFlags] turn
/// off. git-lfs and git-crypt filters don't count.
bool isRepoProgram(GitConfigEntry e) {
  if (!isRepoScope(e)) return false;
  final k = e.key;
  if (k == 'core.fsmonitor') return !const {'', 'false', 'true', 'no', 'yes', 'off', 'on', '0', '1'}.contains(e.value);
  if (_filterKey.hasMatch(k) || _diffProgram.hasMatch(k)) return !_knownFilter.hasMatch(e.value.trim());
  return _programDefaults.containsKey(k) ||
      k == 'core.gitproxy' ||
      k == 'diff.external' ||
      _mergeDriver.hasMatch(k) ||
      _remotePack.hasMatch(k) ||
      _credentialHelper.hasMatch(k);
}

/// The `-c` overrides that keep the repository's own program keys from
/// running, or a [refusal] in plain words when that can't be done safely: a
/// filter that cleans files (blanking it would commit them raw, which for an
/// encryption filter means plaintext).
({List<String> args, String? refusal}) repoGuard(List<GitConfigEntry> entries) {
  final args = <String>[];
  final user = [
    for (final e in entries)
      if (!isRepoScope(e)) e,
  ];
  String? userValue(String key) => user.where((e) => e.key == key).lastOrNull?.value;
  final seen = <String>{};
  var credentials = false;
  for (final e in entries.where(isRepoProgram)) {
    final k = e.key;
    if (_filterKey.firstMatch(k) case final m?) {
      if (m[2] != 'smudge') {
        return (
          args: const [],
          refusal:
              'This repository\'s git config runs a program on files (filter "${m[1]}"), so EveryAI\'s checkpoints, '
              'diffs and commits are off here. Remove it from .git/config to turn them back on.',
        );
      }
      // A smudge-only filter: checkouts write the stored file as it is.
      if (seen.add(k)) args.addAll(['-c', '$k=', '-c', 'filter.${m[1]}.required=false']);
    } else if (_mergeDriver.firstMatch(k) case final m?) {
      if (seen.add(k)) args.addAll(['-c', 'merge.${m[1]}.driver=git merge-file %A %O %B']);
    } else if (_credentialHelper.hasMatch(k)) {
      credentials = true;
    } else if (k == 'core.gitproxy') {
      // gitProxy's first match wins and the command line comes last, so it can't be overridden: git:// is off instead.
      if (seen.add(k)) args.addAll(['-c', 'protocol.git.allow=never']);
    } else if (_programDefaults[k] case final fallback?) {
      if (seen.add(k)) args.addAll(['-c', '$k=${userValue(k) ?? fallback}']);
    }
    // fsmonitor, diff.external and diff.<x>.textconv|command: guardFlags and diffFlags. remote.<r>.receivepack and
    // uploadpack: the first value wins, so `-c` can't change them; they run here only for a remote that is a folder
    // on this computer, which push refuses.
  }
  if (credentials) {
    // An empty helper clears the list; the user's own come back in order.
    args.addAll(['-c', 'credential.helper=']);
    for (final e in user) {
      if (_credentialHelper.hasMatch(e.key) && e.value.isNotEmpty) args.addAll(['-c', '${e.key}=${e.value}']);
    }
  }
  return (args: args, refusal: null);
}
