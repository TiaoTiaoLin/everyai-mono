import 'git_models.dart';
import 'repo_check.dart';
import 'git_service_stub.dart' if (dart.library.io) 'git_service_io.dart' as impl;

export 'git_models.dart';
export 'repo_check.dart' show RepoFinding, repoCheckNote, splitRepoCheck;

/// A git or gh command failed; [message] is meant for the user.
final class GitError implements Exception {
  const GitError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Session worktrees and what the app does with them, on top of the `git`
/// and `gh` command-line tools. See `git_service_io.dart`.
abstract final class GitService {
  /// The app's data folder (App Support), where worktrees and hooks live.
  static Future<String> dataDir() => impl.dataDir();

  /// The top of the repository [dir] is in, or null outside one.
  static Future<String?> repoRoot(String dir) => impl.repoRoot(dir);

  /// Whether the repository at [repoRoot] has a commit to branch from (a
  /// fresh `git init` has none).
  static Future<bool> hasCommits(String repoRoot) => impl.hasCommits(repoRoot);

  /// What in the project at [dir] can run code by itself (git hooks and config programs, editor tasks, install
  /// scripts, agent CLI plugins), found without running any of it; empty when nothing is.
  static Future<List<RepoFinding>> checkRepo(String dir) => impl.checkRepo(dir);

  /// Every worktree of the repository [dir] is in, the main one included (`git worktree list`); empty outside one.
  static Future<List<String>> worktrees(String dir) => impl.worktrees(dir);

  /// A fork's own worktree, from a snapshot of [dir]'s working tree; null
  /// outside git or with no commit yet (the fork then shares [dir]).
  static Future<ForkCopy?> forkCopy(String dir, {required String worktreesDir, required String slug}) =>
      impl.forkCopy(dir, worktreesDir: worktreesDir, slug: slug);

  /// Commits what the fork did, merges it into the parent's folder file by
  /// file (three-way, against the snapshot) unless [merge] is false, keeps it
  /// under `refs/everyai/forks/<slug>` and removes the worktree.
  static Future<ForkMerge> mergeFork(ForkCopy copy, {required String slug, bool merge = true}) =>
      impl.mergeFork(copy, slug: slug, merge: merge);

  /// Snapshots [dir]'s working tree for an in-place session; null outside git
  /// or in a repository with no commit yet.
  static Future<GitBaseline?> baseline(String dir) => impl.baseline(dir);

  /// A worktree for a new session on `everyai/<slug>`, branched from the main
  /// checkout's current commit, with EveryAI's commit hooks.
  static Future<SessionWorktree> createWorktree({
    required String repoRoot,
    required String slug,
    required String worktreesDir,
    required String hooksDir,
  }) => impl.createWorktree(repoRoot: repoRoot, slug: slug, worktreesDir: worktreesDir, hooksDir: hooksDir);

  /// Files changed since the base commit, committed or not.
  static Future<List<FileChange>> changes(SessionWorktree w) => impl.changes(w);

  /// The whole diff since the base commit, by file.
  static Future<List<FileDiff>> diff(SessionWorktree w) => impl.diff(w);

  /// Undoes one hunk in the working tree.
  /// Changes not committed yet (untracked files included), against HEAD.
  static Future<List<FileDiff>> uncommittedDiff(SessionWorktree w) => impl.uncommittedDiff(w);

  /// Subjects of the commits on the session branch since its base, newest first.
  static Future<List<String>> commitSubjects(SessionWorktree w) => impl.commitSubjects(w);

  /// The `origin` remote's URL, or '' without one.
  static Future<String> remoteUrl(SessionWorktree w) => impl.remoteUrl(w);

  /// Whether anything isn't committed yet (untracked files included); cheaper than [uncommittedDiff].
  static Future<bool> isDirty(SessionWorktree w) => impl.isDirty(w);

  /// The commit the session branch is at.
  static Future<String> headCommit(SessionWorktree w) => impl.headCommit(w);

  /// The session branch's latest pull request (`gh pr view`), open, merged or closed; null without one or gh.
  static Future<BranchPr?> prFor(SessionWorktree w) => impl.prFor(w);

  /// Which of [paths] (relative to [dir]; a folder ends in `/`) git ignores (`git check-ignore`), as given; empty
  /// outside git.
  static Future<Set<String>> ignoredAmong(String dir, List<String> paths) => impl.ignoredAmong(dir, paths);

  /// Whether the GitHub CLI is installed and signed in.
  static Future<bool> ghReady(String dir) => impl.ghReady(dir);

  static Future<void> revertHunk(SessionWorktree w, FileDiff file, int hunk) => impl.revertHunk(w, file, hunk);

  /// Commits [paths] (everything when null); false when there was nothing to commit.
  static Future<bool> commitAll(SessionWorktree w, String message, {List<String>? paths}) =>
      impl.commitAll(w, message, paths: paths);

  /// Switches to new branch [branch] with the changes and commits [paths] there (everything when null); returns
  /// the commit, or null when there was nothing to commit. Refuses a name git rejects or a branch that exists
  /// before touching anything, and undoes the switch when the commit fails.
  static Future<String?> commitOnNewBranch(SessionWorktree w, String branch, String message, {List<String>? paths}) =>
      impl.commitOnNewBranch(w, branch, message, paths: paths);

  /// The tree of everything in the folder now; [changedSince] compares a later state with it.
  static Future<String> snapshotTree(SessionWorktree w) => impl.snapshotTree(w);

  /// The paths that differ between snapshot [tree] and the folder now.
  static Future<List<String>> changedSince(SessionWorktree w, String tree) => impl.changedSince(w, tree);

  /// Whether any of [paths] has uncommitted changes.
  static Future<bool> isDirtyAmong(SessionWorktree w, List<String> paths) => impl.isDirtyAmong(w, paths);

  /// Snapshots the working tree under `refs/everyai/<slug>/turn-<turn>`.
  static Future<String> checkpoint(SessionWorktree w, int turn) => impl.checkpoint(w, turn);

  /// Puts the working tree back to a [checkpoint].
  static Future<void> restoreCheckpoint(SessionWorktree w, String ref) => impl.restoreCheckpoint(w, ref);

  static Future<({int ahead, int behind})> aheadBehind(SessionWorktree w) => impl.aheadBehind(w);

  /// Commits pending work, then squashes the session branch onto the base
  /// branch in the main checkout. Returns the new commit.
  static Future<String> squashMerge(SessionWorktree w, String message) => impl.squashMerge(w, message);

  static Future<void> push(SessionWorktree w) => impl.push(w);

  /// Opens a pull request with `gh`; returns its URL.
  static Future<String> createPr(SessionWorktree w, {required String title, required String body}) =>
      impl.createPr(w, title: title, body: body);

  /// Deletes the worktree, its branch, checkpoints and hooks.
  static Future<void> removeWorktree(SessionWorktree w, {required String hooksDir, bool deleteBranch = true}) =>
      impl.removeWorktree(w, hooksDir: hooksDir, deleteBranch: deleteBranch);
}
