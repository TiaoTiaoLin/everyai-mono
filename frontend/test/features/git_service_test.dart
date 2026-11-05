import 'dart:io';

import 'package:every_ai/features/code/git/git_service.dart';
import 'package:flutter_test/flutter_test.dart';

Future<String> _git(String dir, List<String> args) async {
  final r = await Process.run('git', ['-C', dir, ...args]);
  if (r.exitCode != 0) fail('git ${args.join(' ')}: ${r.stderr}');
  return '${r.stdout}'.trim();
}

void main() {
  late Directory tmp;
  late String repo;
  late String hooks;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('everyai-git');
    repo = '${tmp.path}/app';
    hooks = '${tmp.path}/hooks';
    await Directory('$repo/lib').create(recursive: true);
    await _git(repo, ['init', '-q', '-b', 'main']);
    await _git(repo, ['config', 'user.name', 'Dev']);
    await _git(repo, ['config', 'user.email', 'dev@example.com']);
    File('$repo/lib/a.txt').writeAsStringSync('one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n');
    File('$repo/README.md').writeAsStringSync('# App\n');
    await _git(repo, ['add', '-A']);
    await _git(repo, ['commit', '-q', '-m', 'Initial commit']);
  });
  tearDown(() => tmp.delete(recursive: true));

  Future<SessionWorktree> start() => GitService.createWorktree(
    repoRoot: repo,
    slug: sessionSlug('Add a decrement method!', '01a18b2c-afed-74e3-b3b0-654b4168401e'),
    worktreesDir: '${tmp.path}/worktrees/app',
    hooksDir: hooks,
  );

  test('an in-place session diffs against its starting snapshot, not HEAD', () async {
    // Work the user already had going: an edit and an untracked file.
    File('$repo/README.md').writeAsStringSync('# App\n\nDraft notes\n');
    File('$repo/notes.txt').writeAsStringSync('mine\n');
    final base = (await GitService.baseline(repo))!;
    expect(base.branch, 'main');
    expect(await GitService.diff(base.diffView), isEmpty);

    // What the session does.
    File('$repo/lib/a.txt').writeAsStringSync('one\n');
    File('$repo/lib/new.py').writeAsStringSync('print(1)\n');
    final files = await GitService.diff(base.diffView);
    expect(files.map((f) => f.path).toSet(), {'lib/a.txt', 'lib/new.py'});
    // The checkout itself is untouched: no commit, the user's index as it was.
    expect((await Process.run('git', ['-C', repo, 'rev-list', '--count', 'HEAD'])).stdout.toString().trim(), '1');
    expect((await Process.run('git', ['-C', repo, 'diff', '--cached', '--name-only'])).stdout.toString().trim(), '');
  });

  test('a repository with no commits yet is not branched from', () async {
    expect(await GitService.hasCommits(repo), isTrue);
    final fresh = '${tmp.path}/fresh';
    await Directory(fresh).create();
    await _git(fresh, ['init', '-q']);
    expect(await GitService.repoRoot(fresh), isNotNull);
    expect(await GitService.hasCommits(fresh), isFalse);
  });

  test('a session gets its own branch and checkout; the main checkout is untouched', () async {
    final w = await start();
    expect(w.branch, 'everyai/${w.slug}');
    expect(w.slug, startsWith('add-a-decrement-method-'));
    expect(w.baseBranch, 'main');
    expect(await _git(w.path, ['branch', '--show-current']), w.branch);
    File('${w.path}/lib/a.txt').writeAsStringSync('ONE\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nTEN\n');
    File('${w.path}/lib/new.txt').writeAsStringSync('fresh\n');
    expect(File('$repo/lib/new.txt').existsSync(), isFalse);
    expect(await _git(repo, ['status', '--porcelain']), isEmpty);

    final changes = await GitService.changes(w);
    expect(
      {for (final c in changes) c.path: c.kind},
      {'lib/a.txt': ChangeKind.modified, 'lib/new.txt': ChangeKind.added},
    );
    // The diff includes the untracked file but leaves the real index alone.
    final diff = await GitService.diff(w);
    final a = diff.firstWhere((f) => f.path == 'lib/a.txt');
    expect(a.hunks, hasLength(2));
    expect(await _git(w.path, ['diff', '--cached', '--name-only']), isEmpty);

    // Reverting the second hunk keeps the first.
    await GitService.revertHunk(w, a, 1);
    expect(File('${w.path}/lib/a.txt').readAsStringSync(), startsWith('ONE\n'));
    expect(File('${w.path}/lib/a.txt').readAsStringSync(), endsWith('nine\nten\n'));
  });

  test('uncommitted changes, branch commits and the remote, for /commit and /pr', () async {
    final w = await start();
    expect(await GitService.uncommittedDiff(w), isEmpty);
    expect(await GitService.commitSubjects(w), isEmpty);
    expect(await GitService.remoteUrl(w), isEmpty);
    File('${w.path}/lib/new.txt').writeAsStringSync('fresh\n');
    expect([for (final f in await GitService.uncommittedDiff(w)) f.path], ['lib/new.txt']);
    expect(await GitService.commitAll(w, 'Add new.txt'), isTrue);
    expect(await GitService.uncommittedDiff(w), isEmpty);
    expect(await GitService.commitSubjects(w), ['Add new.txt']);
    // Still in the diff since the session's base.
    expect([for (final f in await GitService.diff(w)) f.path], ['lib/new.txt']);
    await _git(repo, ['remote', 'add', 'origin', 'git@github.com:acme/app.git']);
    expect(await GitService.remoteUrl(w), 'git@github.com:acme/app.git');
  });

  test('commitOnNewBranch carries the dirty tree to a new branch; a bad or taken name changes nothing', () async {
    final w = await start();
    File('${w.path}/lib/new.txt').writeAsStringSync('fresh\n');
    final before = await _git(w.path, ['rev-parse', 'HEAD']);
    await expectLater(GitService.commitOnNewBranch(w, 'bad name~', 'x'), throwsA(isA<GitError>()));
    await expectLater(GitService.commitOnNewBranch(w, w.branch, 'x'), throwsA(isA<GitError>()));
    await expectLater(GitService.commitOnNewBranch(w, 'main', 'x'), throwsA(isA<GitError>()));
    expect(await _git(w.path, ['rev-parse', 'HEAD']), before);
    expect(await _git(w.path, ['branch', '--show-current']), w.branch);
    expect(await GitService.isDirty(w), isTrue);

    final sha = await GitService.commitOnNewBranch(w, 'everyai/fix-1', 'Add new.txt');
    expect(await _git(w.path, ['branch', '--show-current']), 'everyai/fix-1');
    expect(sha, await _git(w.path, ['rev-parse', 'HEAD']));
    expect(await _git(w.path, ['log', '-1', '--format=%s']), 'Add new.txt');
    expect(await GitService.isDirty(w), isFalse);
  });

  test('a commit with paths leaves other work alone; nothing to commit does not switch branches', () async {
    final w = await start();
    File('${w.path}/lib/mine.txt').writeAsStringSync('wip\n');
    File('${w.path}/lib/new.txt').writeAsStringSync('fresh\n');
    final tree = await GitService.snapshotTree(w);
    File('${w.path}/lib/new.txt').writeAsStringSync('fresh, changed\n');
    File('${w.path}/lib/more.txt').writeAsStringSync('more\n');
    expect((await GitService.changedSince(w, tree))..sort(), ['lib/more.txt', 'lib/new.txt']);
    expect(await GitService.isDirtyAmong(w, ['lib/new.txt']), isTrue);
    expect(await GitService.isDirtyAmong(w, []), isFalse);

    expect(await GitService.commitAll(w, 'Just new', paths: ['lib/new.txt']), isTrue);
    expect(await _git(w.path, ['show', '--name-only', '--format=', 'HEAD']), 'lib/new.txt');
    expect(await GitService.isDirtyAmong(w, ['lib/new.txt']), isFalse);
    expect(await _git(w.path, ['status', '--porcelain']), contains('lib/mine.txt'));

    // Nothing of those paths is left: the branch is not created and the checkout stays.
    expect(await GitService.commitOnNewBranch(w, 'everyai/none', 'x', paths: ['lib/new.txt']), isNull);
    expect(await _git(w.path, ['branch', '--show-current']), w.branch);
    expect(await _git(w.path, ['branch', '--list', 'everyai/none']), isEmpty);
    final sha = await GitService.commitOnNewBranch(w, 'everyai/more', 'More', paths: ['lib/more.txt']);
    expect(sha, await _git(w.path, ['rev-parse', 'HEAD']));
    expect(await _git(w.path, ['show', '--name-only', '--format=', 'HEAD']), 'lib/more.txt');
  });

  test('a commit that fails after the switch goes back and removes the new branch', () async {
    final w = await start();
    File('${w.path}/lib/new.txt').writeAsStringSync('fresh\n');
    // EveryAI's commits run no hooks, so the failure is git's own: an empty author name.
    await _git(repo, ['config', 'user.name', '']);
    await expectLater(GitService.commitOnNewBranch(w, 'everyai/hooked', 'x'), throwsA(isA<GitError>()));
    expect(await _git(w.path, ['branch', '--show-current']), w.branch);
    expect(await _git(w.path, ['branch', '--list', 'everyai/hooked']), isEmpty);
    expect(await GitService.isDirty(w), isTrue);
  });

  test('the commit hook strips AI credits and still runs the repo\'s own hook', () async {
    // The project's own commit-msg hook appends a marker.
    File('$repo/.git/hooks/commit-msg').writeAsStringSync('#!/bin/sh\necho "Reviewed-by: repo-hook" >> "\$1"\n');
    await Process.run('chmod', ['+x', '$repo/.git/hooks/commit-msg']);
    final w = await start();
    File('${w.path}/README.md').writeAsStringSync('# App\n\nMore.\n');
    await _git(w.path, ['add', '-A']);
    await _git(w.path, [
      'commit',
      '-q',
      '-m',
      'docs: expand the readme\n\nSays more.\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)\n'
          'Co-authored-by: openhands <openhands@all-hands.dev>\nCo-Authored-By: Claude <noreply@anthropic.com>\n'
          'Co-authored-by: Sam <sam@example.com>',
    ]);
    final message = await _git(w.path, ['log', '-1', '--format=%B']);
    expect(message, contains('docs: expand the readme'));
    expect(message, contains('Co-authored-by: Sam <sam@example.com>'));
    expect(message, contains('Reviewed-by: repo-hook'));
    expect(message, isNot(contains('openhands')));
    expect(message, isNot(contains('Claude')));
    expect(await _git(w.path, ['log', '-1', '--format=%an']), 'Dev');
    // The main checkout keeps its normal hooks.
    expect(await Process.run('git', ['-C', repo, 'config', '--get', 'core.hooksPath']).then((r) => r.exitCode), 1);
  });

  test('checkpoints restore the working tree, untracked files included', () async {
    final w = await start();
    File('${w.path}/lib/new.txt').writeAsStringSync('turn one\n');
    final ref = await GitService.checkpoint(w, 2);
    File('${w.path}/lib/new.txt').writeAsStringSync('turn two\n');
    File('${w.path}/lib/a.txt').deleteSync();
    File('${w.path}/later.txt').writeAsStringSync('made later\n');
    await GitService.restoreCheckpoint(w, ref);
    expect(File('${w.path}/lib/new.txt').readAsStringSync(), 'turn one\n');
    expect(File('${w.path}/lib/a.txt').existsSync(), isTrue);
    expect(File('${w.path}/later.txt').existsSync(), isFalse);
    // HEAD and the index are untouched.
    expect(await _git(w.path, ['rev-parse', 'HEAD']), w.baseCommit);
  });

  test('a missing checkpoint leaves the files alone', () async {
    final w = await start();
    File('${w.path}/made.txt').writeAsStringSync('new\n');
    await expectLater(GitService.restoreCheckpoint(w, 'refs/everyai/${w.slug}/turn-9'), throwsA(isA<GitError>()));
    expect(File('${w.path}/made.txt').readAsStringSync(), 'new\n');
  });

  test('squash merge lands one commit on the base branch, then the session is removed', () async {
    final w = await start();
    File('${w.path}/lib/new.txt').writeAsStringSync('feature\n');
    expect(await GitService.commitAll(w, 'wip'), isTrue);
    File('${w.path}/README.md').writeAsStringSync('# App\n\nDocs.\n');
    expect((await GitService.aheadBehind(w)).ahead, 1);

    // A dirty main checkout is refused.
    File('$repo/README.md').writeAsStringSync('dirty\n');
    await expectLater(GitService.squashMerge(w, 'feat: add new'), throwsA(isA<GitError>()));
    await _git(repo, ['checkout', '--', 'README.md']);

    final sha = await GitService.squashMerge(w, 'feat: add new');
    expect(await _git(repo, ['log', '-1', '--format=%H %s']), '$sha feat: add new');
    expect(await _git(repo, ['rev-list', '--count', 'HEAD']), '2');
    expect(File('$repo/lib/new.txt').readAsStringSync(), 'feature\n');
    expect(File('$repo/README.md').readAsStringSync(), contains('Docs.'));

    await GitService.checkpoint(w, 1);
    await GitService.removeWorktree(w, hooksDir: hooks);
    expect(Directory(w.path).existsSync(), isFalse);
    expect(await _git(repo, ['branch', '--list', w.branch]), isEmpty);
    expect(await _git(repo, ['for-each-ref', 'refs/everyai/']), isEmpty);
  });

  test('unified diffs parse into files and hunks', () {
    final files = parseUnifiedDiff(
      'diff --git a/x.txt b/x.txt\nindex 1..2 100644\n--- a/x.txt\n+++ b/x.txt\n@@ -1,2 +1,2 @@\n-a\n+b\n c\n'
      '@@ -10 +10 @@ ctx\n-y\n+z\ndiff --git a/n.txt b/n.txt\nnew file mode 100644\n--- /dev/null\n+++ b/n.txt\n'
      '@@ -0,0 +1 @@\n+hi\n',
    );
    expect(files.map((f) => f.path), ['x.txt', 'n.txt']);
    expect(files.first.hunks.map((h) => (h.oldStart, h.added, h.removed)), [(1, 1, 1), (10, 1, 1)]);
    expect(files.first.patchFor(1), contains('@@ -10 +10 @@ ctx\n-y\n+z\n'));
    expect(files.first.patchFor(1), isNot(contains('-a')));
  });

  test('AI credit lines are recognised, people are not', () {
    expect(
      stripBranding('fix: x\n\nbody\n\nCo-authored-by: openhands <openhands@all-hands.dev>\n'),
      'fix: x\n\nbody\n',
    );
    expect(stripBranding('fix: x\n\nCo-authored-by: Sam <sam@example.com>\n'), contains('Sam'));
    expect(stripBranding('Add y\n\nSigned-off-by: Dev <dev@example.com>\n'), contains('Signed-off-by: Dev'));
  });

  test('a fork works on a copy of the uncommitted folder and merges back file by file', () async {
    // Uncommitted work in the parent, and a dependency folder.
    File('$repo/lib/a.txt').writeAsStringSync('ONE\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n');
    File('$repo/lib/draft.txt').writeAsStringSync('draft\n');
    Directory('$repo/node_modules/x').createSync(recursive: true);
    File('$repo/.gitignore').writeAsStringSync('node_modules/\n');
    final copy = (await GitService.forkCopy('$repo/lib', worktreesDir: '${tmp.path}/forks', slug: 'f1'))!;
    expect(copy.path, endsWith('/f1/lib'));
    expect(File('${copy.path}/a.txt').readAsStringSync(), startsWith('ONE'));
    expect(File('${copy.path}/draft.txt').existsSync(), isTrue);
    expect(copy.links, ['node_modules']);
    expect(Link('${copy.root}/node_modules').existsSync(), isTrue);

    // The fork changes the end of a.txt and adds a file; meanwhile the parent changes the start again.
    File('${copy.path}/a.txt').writeAsStringSync('ONE\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nTEN\n');
    File('${copy.path}/new.txt').writeAsStringSync('from the fork\n');
    File('$repo/lib/a.txt').writeAsStringSync('ONE!\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n');
    // And both change draft.txt: a conflict.
    File('${copy.path}/draft.txt').writeAsStringSync('fork draft\n');
    File('$repo/lib/draft.txt').writeAsStringSync('parent draft\n');

    final result = await GitService.mergeFork(copy, slug: 'f1');
    expect(result.merged, unorderedEquals(['lib/a.txt', 'lib/new.txt']));
    expect(result.conflicts, ['lib/draft.txt']);
    expect(File('$repo/lib/a.txt').readAsStringSync(), startsWith('ONE!\n'));
    expect(File('$repo/lib/a.txt').readAsStringSync(), endsWith('TEN\n'));
    expect(File('$repo/lib/new.txt').readAsStringSync(), 'from the fork\n');
    expect(File('$repo/lib/draft.txt').readAsStringSync(), contains('<<<<<<< yours'));
    // The worktree is gone, the work kept under a ref, the user's branch and index untouched.
    expect(Directory(copy.root).existsSync(), isFalse);
    expect(await _git(repo, ['rev-parse', '--verify', '-q', result.ref]), isNotEmpty);
    expect(await _git(repo, ['log', '--format=%s', '-1']), 'Initial commit');
    expect(await _git(repo, ['diff', '--cached', '--name-only']), isEmpty);
  });

  test('a fork gets its own copy in a repository with no commit yet, and merges back', () async {
    final fresh = '${tmp.path}/fresh-fork';
    await Directory(fresh).create();
    await _git(fresh, ['init', '-q', '-b', 'main']);
    File('$fresh/index.html').writeAsStringSync('<html>one</html>\n');
    final copy = (await GitService.forkCopy(fresh, worktreesDir: '${tmp.path}/forks', slug: 'f2'))!;
    expect(File('${copy.path}/index.html').readAsStringSync(), '<html>one</html>\n');
    File('${copy.path}/index.html').writeAsStringSync('<html>two</html>\n');
    File('${copy.path}/games.js').writeAsStringSync('play()\n');
    // Until it merges back, the parent's folder doesn't change.
    expect(File('$fresh/games.js').existsSync(), isFalse);
    final result = await GitService.mergeFork(copy, slug: 'f2');
    expect(result.merged, unorderedEquals(['index.html', 'games.js']));
    expect(File('$fresh/index.html').readAsStringSync(), '<html>two</html>\n');
    expect(await GitService.hasCommits(fresh), isFalse);
  });

  test('a repository with no commit yet still gets a baseline: everything new shows as added', () async {
    final fresh = '${tmp.path}/fresh';
    await Directory(fresh).create();
    await _git(fresh, ['init', '-q', '-b', 'main']);
    final base = (await GitService.baseline(fresh))!;
    File('$fresh/index.html').writeAsStringSync('<html></html>\n');
    final changes = await GitService.changes(base.diffView);
    expect(changes.single.path, 'index.html');
    expect(changes.single.kind, ChangeKind.added);
  });

  group('a repository that defines programs', () {
    late String marks;

    // Git as the test's own setup, with the repository's programs off.
    Future<String> safe(String dir, List<String> args) => _git(dir, [
      '-c', 'core.hooksPath=/dev/null', '-c', 'core.fsmonitor=false', '-c', 'filter.s.smudge=', //
      ...args,
    ]);

    /// Makes [repo] hostile: every program git might run writes its name into [marks].
    Future<String> arm() async {
      marks = '${tmp.path}/marks.log';
      final evil = File('${tmp.path}/evil.sh')..writeAsStringSync('#!/bin/sh\necho "\$1" >> "$marks"\n');
      await Process.run('chmod', ['+x', evil.path]);
      final run = evil.path;
      for (final (k, v) in [
        ('core.fsmonitor', '$run fsmonitor'),
        ('diff.y.textconv', '$run textconv'),
        ('diff.external', '$run external'),
        ('merge.m.driver', '$run merge'),
        ('filter.s.smudge', '$run smudge'),
        ('log.showSignature', 'true'),
        ('gpg.program', '$run gpg'),
        ('core.sshCommand', '$run ssh'),
        ('credential.helper', '!$run credential'),
      ]) {
        await _git(repo, ['config', k, v]);
      }
      for (final name in [
        'pre-commit',
        'commit-msg',
        'post-commit',
        'post-checkout',
        'reference-transaction',
        'pre-push',
        'post-merge',
        'post-index-change',
      ]) {
        final hook = File('$repo/.git/hooks/$name')..writeAsStringSync('#!/bin/sh\n"$run" hook-$name\n');
        await Process.run('chmod', ['+x', hook.path]);
      }
      return run;
    }

    test('EveryAI\'s own git work runs none of them', () async {
      File('$repo/.gitattributes').writeAsStringSync('*.txt diff=y merge=m filter=s\n');
      await _git(repo, ['add', '-A']);
      await _git(repo, ['commit', '-q', '-m', 'Attributes']);
      final remote = '${tmp.path}/remote.git';
      await _git(tmp.path, ['init', '-q', '--bare', remote]);
      await _git(repo, ['remote', 'add', 'origin', remote]);
      final run = await arm();
      await _git(repo, ['config', 'remote.origin.receivepack', '$run receivepack; git-receive-pack']);
      final hook = File('$remote/hooks/pre-receive')..writeAsStringSync('#!/bin/sh\n"$run" hook-pre-receive\n');
      await Process.run('chmod', ['+x', hook.path]);

      final w = await start();
      final base = (await GitService.baseline(repo))!;
      File('${w.path}/lib/a.txt').writeAsStringSync('one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nTEN\n');
      expect((await GitService.changes(w)).single.path, 'lib/a.txt');
      expect((await GitService.diff(w)).single.path, 'lib/a.txt');
      expect((await GitService.uncommittedDiff(w)).single.path, 'lib/a.txt');
      expect(await GitService.changes(base.diffView), isEmpty);
      expect(await GitService.isDirty(w), isTrue);
      final ref = await GitService.checkpoint(w, 1);
      File('${w.path}/lib/a.txt').writeAsStringSync('gone\n');
      await GitService.restoreCheckpoint(w, ref);
      expect(File('${w.path}/lib/a.txt').readAsStringSync(), endsWith('TEN\n'));
      expect(await GitService.commitAll(w, 'Shout ten\n\nCo-Authored-By: Claude <noreply@anthropic.com>\n'), isTrue);
      expect(await _git(w.path, ['log', '-1', '--format=%B']), 'Shout ten');
      expect(await GitService.commitSubjects(w), ['Shout ten']);

      File('${w.path}/README.md').writeAsStringSync('# App\n\nMore.\n');
      final readme = (await GitService.uncommittedDiff(w)).single;
      await GitService.revertHunk(w, readme, 0);
      expect(File('${w.path}/README.md').readAsStringSync(), '# App\n');

      // The main checkout moved on at the other end of the file: git's own text merge joins them.
      File('$repo/lib/a.txt').writeAsStringSync('ONE\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n');
      await safe(repo, ['commit', '-q', '-am', 'Shout one']);
      await GitService.squashMerge(w, 'Merge the session');
      expect(File('$repo/lib/a.txt').readAsStringSync(), 'ONE\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nTEN\n');

      File('${w.path}/lib/b.txt').writeAsStringSync('bee\n');
      expect(await GitService.commitOnNewBranch(w, 'everyai/bee', 'Bee'), isNotNull);
      // A remote that is a folder here would run its own hooks: refused, in plain words.
      await expectLater(
        GitService.push(w),
        throwsA(predicate<GitError>((e) => e.message.contains('folder on this computer'))),
      );
      expect(await _git(remote, ['branch', '--list']), isEmpty);

      final copy = (await GitService.forkCopy(repo, worktreesDir: '${tmp.path}/forks', slug: 'f'))!;
      File('${copy.path}/lib/c.txt').writeAsStringSync('sea\n');
      expect((await GitService.mergeFork(copy, slug: 'f')).merged, ['lib/c.txt']);
      await GitService.removeWorktree(w, hooksDir: hooks);

      expect(File(marks).existsSync() ? File(marks).readAsStringSync() : '', isEmpty);
      // The trap works: plain git in the same repository runs it.
      await Process.run('git', ['-C', repo, 'status']);
      expect(File(marks).readAsStringSync(), contains('fsmonitor'));
    });

    test('a filter that cleans files turns EveryAI\'s git work off, in plain words', () async {
      final run = await arm();
      await _git(repo, ['config', 'filter.x.clean', '$run clean']);
      File('$repo/secret.a').writeAsStringSync('plain\n');
      File('$repo/.gitattributes').writeAsStringSync('*.a filter=x\n');
      final message = predicate<GitError>((e) => e.message.contains('filter "x"') && e.message.contains('.git/config'));
      await expectLater(GitService.baseline(repo), throwsA(message));
      final head = await _git(repo, ['rev-parse', 'HEAD']);
      final view = SessionWorktree(repoRoot: repo, path: repo, branch: 'main', baseBranch: 'main', baseCommit: head);
      await expectLater(GitService.changes(view), throwsA(message));
      await expectLater(GitService.commitAll(view, 'Secret'), throwsA(message));
      expect(File(marks).existsSync(), isFalse);
      expect(await _git(repo, ['rev-parse', 'HEAD']), head);
    });
  });
}
