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
