import 'git_models.dart';
import 'git_service.dart' show GitError;

Never _unsupported() => throw const GitError('Git worktrees need the desktop app.');

Future<String> dataDir() async => '';
Future<String?> repoRoot(String dir) async => null;
Future<bool> hasCommits(String repoRoot) async => false;
Future<List<String>> worktrees(String dir) async => const [];
Future<Set<String>> ignoredAmong(String dir, List<String> paths) async => const {};
Future<GitBaseline?> baseline(String dir) async => null;
Future<SessionWorktree> createWorktree({
  required String repoRoot,
  required String slug,
  required String worktreesDir,
  required String hooksDir,
}) async => _unsupported();
Future<List<FileChange>> changes(SessionWorktree w) async => const [];
Future<List<FileDiff>> diff(SessionWorktree w) async => const [];
Future<List<FileDiff>> uncommittedDiff(SessionWorktree w) async => const [];
Future<List<String>> commitSubjects(SessionWorktree w) async => const [];
Future<String> remoteUrl(SessionWorktree w) async => '';
Future<bool> ghReady(String dir) async => false;
Future<bool> isDirty(SessionWorktree w) async => false;
Future<String> headCommit(SessionWorktree w) async => '';
Future<BranchPr?> prFor(SessionWorktree w) async => null;
Future<void> revertHunk(SessionWorktree w, FileDiff file, int hunk) async => _unsupported();
Future<bool> commitAll(SessionWorktree w, String message) async => _unsupported();
Future<String> commitOnNewBranch(SessionWorktree w, String branch, String message) async => _unsupported();
Future<String> checkpoint(SessionWorktree w, int turn) async => _unsupported();
Future<void> restoreCheckpoint(SessionWorktree w, String ref) async => _unsupported();
Future<({int ahead, int behind})> aheadBehind(SessionWorktree w) async => (ahead: 0, behind: 0);
Future<String> squashMerge(SessionWorktree w, String message) async => _unsupported();
Future<void> push(SessionWorktree w) async => _unsupported();
Future<String> createPr(SessionWorktree w, {required String title, required String body}) async => _unsupported();
Future<void> removeWorktree(SessionWorktree w, {required String hooksDir, bool deleteBranch = true}) async {}
Future<ForkCopy?> forkCopy(String dir, {required String worktreesDir, required String slug}) async => null;
Future<ForkMerge> mergeFork(ForkCopy copy, {required String slug, bool merge = true}) async => _unsupported();
