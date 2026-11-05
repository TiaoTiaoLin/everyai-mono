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

  test('a filter that cleans files, or one dressed up as git-crypt, is refused', () {
    for (final entry in [
      _local('filter.x.clean', './x.sh'),
      _local('filter.x.process', './x.sh'),
      _local('filter.lfs.clean', 'git-lfs clean -- %f; ./x.sh'),
      _local('filter.git-crypt.clean', '"/tmp/git-crypt" clean'),
    ]) {
      final guard = repoGuard([entry]);
      expect(guard.refusal, contains('filter "${entry.key.split('.')[1]}"'), reason: entry.value);
      expect(guard.args, isEmpty);
    }
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
