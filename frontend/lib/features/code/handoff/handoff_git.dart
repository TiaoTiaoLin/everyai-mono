// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import '../domain/code_session.dart';
import '../git/git_service.dart';
import 'handoff.dart';

/// The most commit subjects a handoff lists.
const handoffCommits = 8;

/// The repository facts for a handoff of [info], and each changed file's diff
/// by path (for the excerpts). Null when the session isn't in a git
/// repository or git fails: the handoff then goes out without them.
Future<({HandoffGit git, Map<String, FileDiff> diffs})?> handoffGit(CodeSessionInfo info) async {
  final target = info.diffTarget;
  if (target == null) return null;
  // An in-place session's diff view starts at a snapshot tree, which `git
  // log` can't range from: its commits count from the commit it started on.
  final b = info.baseline;
  final log =
      info.worktree ??
      SessionWorktree(repoRoot: b!.repoRoot, path: b.dir, branch: b.branch, baseBranch: b.branch, baseCommit: b.commit);
  try {
    // One diff gives both the change list and the excerpts (each snapshot
    // re-indexes the whole tree).
    final diffs = await GitService.diff(target);
    final uncommitted = await GitService.uncommittedDiff(target);
    final commits = log.baseCommit.isEmpty ? const <String>[] : await GitService.commitSubjects(log);
    return (
      git: HandoffGit.capped(
        branch: info.branch.isNotEmpty ? info.branch : target.branch,
        worktree: info.worktree?.path ?? '',
        changes: [for (final d in diffs) FileChange(d.path, d.kind, added: d.added, removed: d.removed)],
        uncommitted: uncommitted.length,
        commits: commits.take(handoffCommits).toList(),
      ),
      diffs: {for (final d in diffs) d.path: d},
    );
  } on GitError {
    return null;
  }
}
