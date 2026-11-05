import 'package:every_ai/features/code/git/git_guard.dart';
import 'package:flutter_test/flutter_test.dart';

GitConfigEntry _local(String key, String value) => (scope: 'local', key: key, value: value);
GitConfigEntry _global(String key, String value) => (scope: 'global', key: key, value: value);

void main() {
  test('config list output parses into scoped entries', () {
    final entries = parseConfigList('global\x00user.name\nSam\x00local\x00core.bare\nfalse\x00local\x00flag.only\x00');
    expect(entries, [
      (scope: 'global', key: 'user.name', value: 'Sam'),
      (scope: 'local', key: 'core.bare', value: 'false'),
      (scope: 'local', key: 'flag.only', value: ''),
    ]);
  });

  test('every call turns hooks, fsmonitor, submodules, ext:: and signatures off', () {
    expect(guardFlags('/dev/null'), [
      '-c', 'core.hooksPath=/dev/null', '-c', 'core.fsmonitor=false', '-c', 'submodule.recurse=false', //
      '-c', 'protocol.ext.allow=never', '-c', 'safe.bareRepository=explicit', '-c', 'log.showSignature=false',
    ]);
  });

  test('the repository\'s program keys are overridden; the user\'s own values are used again', () {
    final guard = repoGuard([
      _global('gpg.program', '/opt/homebrew/bin/gpg'),
      _global('credential.helper', 'osxkeychain'),
      _global('credential.https://github.com.helper', '!gh auth git-credential'),
      _local('core.fsmonitor', './watch.sh'),
      _local('filter.s.smudge', './smudge.sh'),
      _local('merge.m.driver', './merge.sh %A'),
      _local('gpg.program', './gpg.sh'),
      _local('gpg.ssh.program', './sign.sh'),
      _local('core.sshcommand', './ssh.sh'),
      _local('core.gitproxy', './proxy.sh'),
      _local('credential.helper', '!./steal.sh'),
      // From a file .git/config includes: git reports it as local.
      _local('core.askpass', './ask.sh'),
    ]);
    expect(guard.refusal, isNull);
    expect(guard.args, [
      '-c', 'filter.s.smudge=', '-c', 'filter.s.required=false', //
      '-c', 'merge.m.driver=git merge-file %A %O %B',
      '-c', 'gpg.program=/opt/homebrew/bin/gpg',
      '-c', 'gpg.ssh.program=ssh-keygen',
      '-c', 'core.sshcommand=ssh',
      '-c', 'protocol.git.allow=never',
      '-c', 'core.askpass=',
      '-c', 'credential.helper=',
      '-c', 'credential.helper=osxkeychain',
      '-c', 'credential.https://github.com.helper=!gh auth git-credential',
    ]);
  });

  test('the user\'s own config and git-lfs or git-crypt values need nothing', () {
    final guard = repoGuard([
      _global('filter.lfs.clean', 'git-lfs clean -- %f'),
      _global('filter.mine.clean', 'my-filter'),
      _global('core.sshcommand', 'ssh -i ~/.ssh/work'),
      _local('filter.lfs.clean', 'git-lfs clean -- %f'),
      _local('filter.lfs.process', 'git-lfs filter-process'),
      _local('filter.git-crypt.clean', '"/opt/homebrew/bin/git-crypt" clean'),
      _local('filter.git-crypt.smudge', '"/opt/homebrew/bin/git-crypt" smudge'),
      _local('diff.git-crypt.textconv', '"/opt/homebrew/bin/git-crypt" diff'),
      _local('core.fsmonitor', 'true'),
      _local('user.name', 'Dev'),
    ]);
    expect(guard.refusal, isNull);
    expect(guard.args, isEmpty);
  });

  test('a filter that cleans files, or one dressed up as git-crypt, is blanked and storing files is refused', () {
    for (final entry in [
      _local('filter.x.clean', './x.sh'),
      _local('filter.x.process', './x.sh'),
      _local('filter.lfs.clean', 'git-lfs clean -- %f; ./x.sh'),
      _local('filter.git-crypt.clean', '"/tmp/git-crypt" clean'),
    ]) {
      final name = entry.key.split('.')[1];
      final guard = repoGuard([entry]);
      expect(guard.refusal, contains('filter "$name"'), reason: entry.value);
      expect(guard.args, [
        '-c', 'filter.$name.clean=', '-c', 'filter.$name.smudge=', '-c', 'filter.$name.process=', //
        '-c', 'filter.$name.required=false',
      ]);
      expect(blocksStoring(entry), isTrue);
    }
    expect([
      for (final c in ['add', 'commit', 'stash', 'apply']) storesFiles(c),
    ], everyElement(isTrue));
    expect(
      [
        for (final c in ['worktree', 'status', 'diff', 'restore', 'switch', 'read-tree']) storesFiles(c),
      ],
      [for (var i = 0; i < 6; i++) false],
    );
  });

  test('hooks set in config are turned off by name; an event added to the user\'s own command is theirs', () {
    final guard = repoGuard([
      _global('hook.scan.command', '/usr/local/bin/gitleaks protect'),
      _local('hook.x.command', './evil.sh'),
      _local('hook.x.event', 'reference-transaction'),
      _local('hook.y.event', 'pre-commit'),
      _local('hook.scan.event', 'post-commit'),
    ]);
    expect(guard.args, ['-c', 'hook.x.enabled=false', '-c', 'hook.y.enabled=false']);
    expect(isRepoProgram(_local('hook.x.command', './evil.sh')), isTrue);
    expect(isRepoProgram(_global('hook.x.command', './evil.sh')), isFalse);
  });

  test('git-lfs programs from the repository turn the lfs filter off and refuse storing files', () {
    for (final entry in [
      _local('lfs.standalonetransferagent', 'x'),
      _local('lfs.customtransfer.x.path', './evil.sh'),
      _local('lfs.extension.e.smudge', './evil.sh %f'),
    ]) {
      final guard = repoGuard([_global('filter.lfs.process', 'git-lfs filter-process'), entry]);
      expect(guard.refusal, contains(entry.key), reason: entry.key);
      expect(guard.args, containsAllInOrder(['-c', 'filter.lfs.process=', '-c', 'filter.lfs.required=false']));
      expect(isRepoProgram(entry), isTrue);
    }
    expect(isRepoProgram(_global('lfs.customtransfer.x.path', '/usr/bin/agent')), isFalse);
  });

  test('the user\'s own hooks folder comes back; a relative one or the repository\'s does not', () {
    expect(repoGuard([_global('core.hookspath', '/Users/sam/.githooks')]).args, [
      '-c',
      'core.hooksPath=/Users/sam/.githooks',
    ]);
    expect(repoGuard([_global('core.hookspath', '~/.githooks')]).args, ['-c', 'core.hooksPath=~/.githooks']);
    expect(repoGuard([_global('core.hookspath', '.githooks')]).args, isEmpty);
    expect(repoGuard([_local('core.hookspath', '/tmp/hooks')]).args, isEmpty);
    expect(isRepoProgram(_local('core.hookspath', '.husky')), isFalse);
  });

  test('the guard reaches git started by another program through the environment', () {
    expect(
      configEnv(['-c', 'core.fsmonitor=false', '-c', 'hook.x.enabled=false', '-c', 'filter.s.smudge='], count: 1),
      {
        'GIT_CONFIG_KEY_1': 'core.fsmonitor',
        'GIT_CONFIG_VALUE_1': 'false',
        'GIT_CONFIG_KEY_2': 'hook.x.enabled',
        'GIT_CONFIG_VALUE_2': 'false',
        'GIT_CONFIG_KEY_3': 'filter.s.smudge',
        'GIT_CONFIG_VALUE_3': '',
        'GIT_CONFIG_COUNT': '4',
      },
    );
  });

  test('program keys are named for the repo check, the user\'s own are not', () {
    expect(isRepoProgram(_local('diff.y.textconv', './t.sh')), isTrue);
    expect(isRepoProgram(_local('diff.external', './t.sh')), isTrue);
    expect(isRepoProgram(_local('remote.origin.receivepack', './r.sh')), isTrue);
    expect(isRepoProgram(_local('core.fsmonitor', 'false')), isFalse);
    expect(isRepoProgram(_global('core.fsmonitor', './watch.sh')), isFalse);
    expect(isRepoProgram(_local('filter.lfs.smudge', 'git-lfs smudge -- %f')), isFalse);
    expect(isRepoProgram((scope: 'worktree', key: 'gpg.program', value: './g.sh')), isTrue);
  });
}
