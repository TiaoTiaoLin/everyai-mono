// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'workflow_bridge.dart';
import 'workflow_engine.dart';

/// A session's workflow runs this app run, oldest first, for the card.
final workflowRunsProvider = NotifierProvider.family<WorkflowRuns, List<WorkflowRun>, String>(WorkflowRuns.new);

final class WorkflowRuns extends Notifier<List<WorkflowRun>> {
  WorkflowRuns(this.sessionId);
  final String sessionId;

  @override
  List<WorkflowRun> build() => const [];

  /// Finished runs the user closed in the transcript; they still show under Session info's Running work.
  final dismissed = <String>{};

  /// Takes finished run [runId]'s card out of the transcript (a running one stays).
  void dismiss(String runId) {
    if (state.any((r) => r.runId == runId && r.status == WorkflowStatus.running)) return;
    dismissed.add(runId);
    state = [...state];
  }

  void put(WorkflowRun run) {
    final i = state.indexWhere((r) => r.runId == run.runId);
    state = i < 0 ? [...state, run] : [...state.sublist(0, i), run, ...state.sublist(i + 1)];
  }
}

/// Starts a workflow script (tests swap in a fake bridge).
typedef StartWorkflowBridge = Future<WorkflowBridge> Function({
  required String dir,
  required String source,
  required Map<String, Object?> args,
});

final workflowBridgeProvider = Provider<StartWorkflowBridge>((ref) => startWorkflowBridge);
