import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/ui/adaptive.dart';
import '../../code_providers.dart';
import '../../domain/code_session.dart';
import '../../git/git_service.dart';

/// What the console's git button does next.
enum GitActionKind { commit, viewPr, createPr, mergeLocally }

/// The git button's action: its kind, label, whether it can run now and, for View PR, the address.
typedef GitAction = ({GitActionKind kind, String label, bool enabled, String? url});

/// The one next step for a session's work, in the order a source control panel offers it: commit what isn't
/// committed, then look at the open pull request, else open one when the branch has a remote, else merge it locally.
/// A merged or closed pull request still shows while the branch has nothing newer ([head] is where it was): its
/// commits stay "ahead" after a squash merge, and another PR for them would be a duplicate. Nothing left to do is a
/// Commit that can't run. Null (no button) without a worktree: an in-place session commits in the user's own
/// checkout, which EveryAI leaves to them.
GitAction? gitActionFor({
  required bool worktree,
  required bool dirty,
  required int ahead,
  required bool hasRemote,
  BranchPr? pr,
  String head = '',
}) {
  if (!worktree) return null;
  if (dirty) return (kind: GitActionKind.commit, label: 'Commit', enabled: true, url: null);
  if (pr != null && (pr.open || pr.head == head)) {
    return (kind: GitActionKind.viewPr, label: 'View PR #${pr.number}', enabled: true, url: pr.url);
  }
  if (ahead > 0 && hasRemote) return (kind: GitActionKind.createPr, label: 'Create PR', enabled: true, url: null);
  if (ahead > 0) return (kind: GitActionKind.mergeLocally, label: 'Merge locally', enabled: true, url: null);
  return (kind: GitActionKind.commit, label: 'Commit', enabled: false, url: null);
}

/// [gitActionFor] for a session, worked out again whenever its diff refreshes (edits, turn ends, commits, the Refresh
/// button). A dirty tree is Commit at once (`git status`, no remote or gh): while the agent edits, that is every
/// refresh. gh is asked about a pull request only on a clean tree with a remote.
final gitButtonProvider = FutureProvider.autoDispose.family<GitAction?, String>((ref, sessionId) async {
  final w = ref.watch(codeSessionsProvider.select((all) => all.where((s) => s.id == sessionId).firstOrNull?.worktree));
  if (w == null) return null;
  final snapshot = await ref.watch(codeGitProvider(sessionId).future);
  if (await GitService.isDirty(w)) return gitActionFor(worktree: true, dirty: true, ahead: 0, hasRemote: false);
  final remote = await GitService.remoteUrl(w);
  final (pr, head) = remote.isEmpty ? (null, '') : await (GitService.prFor(w), GitService.headCommit(w)).wait;
  return gitActionFor(
    worktree: true,
    dirty: false,
    ahead: snapshot.ahead,
    hasRemote: remote.isNotEmpty,
    pr: pr,
    head: head,
  );
});

/// The primary git button (the console header and Session info → Changes). Commit and Create PR open the same
/// drafts as `/commit` and `/pr`, so the user edits the message before anything runs.
class GitButton extends ConsumerWidget {
  const GitButton({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final action = ref.watch(gitButtonProvider(sessionId)).value;
    if (action == null) return const SizedBox.shrink();
    final controller = ref.read(codeSessionProvider(sessionId).notifier);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: AdaptiveButton(
        key: const ValueKey('console.git'),
        label: action.label,
        emphasis: ButtonEmphasis.secondary,
        onPressed: !action.enabled
            ? null
            : switch (action.kind) {
                GitActionKind.commit => () => unawaited(controller.draftCommit('')),
                GitActionKind.createPr => () => unawaited(controller.draftPr('')),
                GitActionKind.viewPr => () => unawaited(launchUrl(Uri.parse(action.url!))),
                GitActionKind.mergeLocally => () {
                  final info = ref.read(codeSessionsProvider.notifier).byId(sessionId);
                  if (info != null) unawaited(mergeLocally(context, ref, info));
                },
              },
      ),
    );
  }
}

/// Squash-merges the session's branch into its base branch in the main checkout, with a message the user confirms,
/// then offers to remove the worktree. Failures are shown, not thrown.
Future<void> mergeLocally(BuildContext context, WidgetRef ref, CodeSessionInfo info) async {
  final w = info.worktree;
  if (w == null) return;
  final git = ref.read(codeGitProvider(info.id).notifier);
  final message = await showAdaptivePrompt(
    context,
    title: 'Squash merge into ${w.baseBranch}',
    confirmLabel: 'Merge',
    initialValue: info.title,
  );
  if (message == null || message.trim().isEmpty || !context.mounted) return;
  try {
    final sha = await git.squashMerge(message.trim());
    if (context.mounted) showAdaptiveToast(context, 'Merged into ${w.baseBranch} as ${sha.substring(0, 7)}');
  } on Object catch (e) {
    if (context.mounted) showAdaptiveToast(context, '$e');
    return;
  }
  if (!context.mounted) return;
  final remove = await showAdaptiveConfirm(
    context,
    title: 'Remove the worktree?',
    message:
        'The work is on ${w.baseBranch} now. Removing deletes the worktree at ${w.path} and branch ${w.branch}; '
        'cancel to keep it and go on working there.',
    confirmLabel: 'Remove',
  );
  if (!remove || !context.mounted) return;
  try {
    await git.discard();
  } on Object catch (e) {
    if (context.mounted) showAdaptiveToast(context, '$e');
  }
}
