// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../code_providers.dart';
import '../git/git_service.dart';
import 'workflow_engine.dart';

/// What the user picks for a finished run's uncommitted work.
enum WorkflowLand { commit, branch, leave }

/// Whether a run that ended this way gets the commit choice: it finished its work (done, or capped with some).
bool workflowAsksLanding(WorkflowRun run) => run.status == WorkflowStatus.done || run.status == WorkflowStatus.capped;

/// The files each run changed in the folder (what differs between the folder when it started and when it ended),
/// by run id. A run that wrote nothing has none, so nothing is asked.
final workflowOwnPathsProvider = NotifierProvider.family<WorkflowOwnPaths, Map<String, List<String>>, String>(
  WorkflowOwnPaths.new,
);

final class WorkflowOwnPaths extends Notifier<Map<String, List<String>>> {
  WorkflowOwnPaths(this.sessionId);
  final String sessionId;

  @override
  Map<String, List<String>> build() => const {};

  void set(String runId, List<String> paths) => state = {...state, runId: paths};
}

/// Whether run [runId]'s files are waiting in the session's folder uncommitted. A folder outside git, a run
/// that changed nothing, or a clean folder is false (nothing to ask).
final workflowDirtyProvider = FutureProvider.autoDispose.family<bool, ({String sessionId, String runId})>((
  ref,
  key,
) async {
  final target = ref.read(codeSessionsProvider.notifier).byId(key.sessionId)?.diffTarget;
  final paths = ref.watch(workflowOwnPathsProvider(key.sessionId))[key.runId];
  if (target == null || paths == null || paths.isEmpty) return false;
  try {
    return await GitService.isDirtyAmong(target, paths);
  } on Object {
    return false;
  }
});

/// The choices made this app run, by run id: the sentence the card shows, and whether it worked (a failed one
/// leaves the buttons up, with its reason).
typedef WorkflowLanded = ({String text, bool ok});

final workflowLandingProvider = NotifierProvider.family<WorkflowLandings, Map<String, WorkflowLanded>, String>(
  WorkflowLandings.new,
);

final class WorkflowLandings extends Notifier<Map<String, WorkflowLanded>> {
  WorkflowLandings(this.sessionId);
  final String sessionId;

  @override
  Map<String, WorkflowLanded> build() => const {};

  void set(String runId, WorkflowLanded landed) => state = {...state, runId: landed};
}

/// The commit message offered for [run]: its name and, when the result has one, the fix in a line.
String workflowCommitMessage(WorkflowRun run) {
  final r = run.result;
  final said = r is Map && r['fix_summary'] is String ? (r['fix_summary'] as String).trim().split('\n').first : '';
  final line = said.isEmpty ? run.name : '${run.name}: $said';
  return line.length <= 72 ? line : '${line.substring(0, 71)}…';
}

/// The branch name offered for [run].
String workflowBranchName(WorkflowRun run) {
  final slug = run.name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
  final id = run.runId.length > 6 ? run.runId.substring(0, 6) : run.runId;
  return 'everyai/${slug.isEmpty ? 'workflow' : slug}-$id';
}

/// The short note the lead gets once the user has chosen. Plain text in a tag; the branch is the only thing the
/// user typed and it is stripped of what could close the tag.
String workflowLandingMessage(
  WorkflowRun run,
  WorkflowLand choice, {
  String branch = '',
  String commit = '',
  bool committed = true,
}) {
  String attr(String s) => s.replaceAll(RegExp(r'["<>]'), '');
  final what = switch (choice) {
    WorkflowLand.commit when !committed => 'The user chose to commit, but there was nothing left to commit.',
    WorkflowLand.commit => 'The user committed the ${run.name} workflow\'s changes on the current branch.',
    WorkflowLand.branch =>
      'The user committed the ${run.name} workflow\'s changes on a new branch, ${attr(branch)}, '
          'and the folder is now on that branch.',
    WorkflowLand.leave => 'The user chose to leave the ${run.name} workflow\'s changes uncommitted.',
  };
  return '<workflow-landing run="${attr(run.runId)}" choice="${choice.name}"'
      '${branch.isEmpty ? '' : ' branch="${attr(branch)}"'}${commit.isEmpty ? '' : ' commit="${attr(commit)}"'}>\n'
      '$what\n</workflow-landing>';
}
