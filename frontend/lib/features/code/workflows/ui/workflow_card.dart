// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/router.dart';
import '../../../../core/theme/every_theme.dart';
import '../../../../core/ui/adaptive.dart';
import '../../../../core/ui/brand.dart';
import '../../code_providers.dart';
import '../workflow_engine.dart';
import '../workflow_runs.dart';

/// The session's workflow runs, newest last, for the end of the transcript.
class WorkflowRunsView extends ConsumerWidget {
  const WorkflowRunsView({super.key, required this.sessionId});
  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final runs = ref.watch(workflowRunsProvider(sessionId));
    if (runs.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final run in runs)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: WorkflowCard(
              run: run,
              onStop: () => ref.read(codeSessionProvider(sessionId).notifier).stopWorkflow(run.runId),
            ),
          ),
      ],
    );
  }
}

/// One run: its phases, each with its agents (tap one to open its session)
/// and log lines, then what it used of its caps.
class WorkflowCard extends StatelessWidget {
  const WorkflowCard({super.key, required this.run, this.onStop});
  final WorkflowRun run;
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final running = run.status == WorkflowStatus.running;
    final phases = [
      if (run.agents.any((a) => a.phase.isEmpty) || run.logs.any((l) => l.phase.isEmpty)) '',
      ...run.phases,
    ];
    final cost = run.spentMicros > 0 ? ' · \$${(run.spentMicros / 1e6).toStringAsFixed(2)}' : '';
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: theme.border),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (running) const EveryMarkActivity(activity: MarkActivity.tool, size: 14),
              if (running) const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Workflow: ${run.name}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.type.callout.semibold.tint(theme.text),
                ),
              ),
              Text(_statusText(run.status), style: theme.type.caption.tint(_statusColor(theme, run.status))),
              if (running && onStop != null) ...[
                const SizedBox(width: 8),
                AdaptiveButton(label: 'Stop', emphasis: ButtonEmphasis.plain, onPressed: onStop),
              ],
            ],
          ),
          for (final p in phases) ...[
            if (p.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 2),
                child: Text(p, style: theme.type.caption.semibold.tint(theme.textMuted)),
              ),
            for (final a in run.agents.where((a) => a.phase == p)) _AgentRow(agent: a),
            for (final l in run.logs.where((l) => l.phase == p).toList().reversed.take(5).toList().reversed)
              Padding(
                padding: const EdgeInsets.only(left: 16, top: 2),
                child: Text(
                  l.text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.type.caption.tint(theme.textMuted),
                ),
              ),
          ],
          if (run.error case final error? when !running)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(error, style: theme.type.caption.tint(theme.danger)),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '${run.started} of ${run.caps.maxAgents} agents$cost',
              style: theme.type.caption.tint(theme.textMuted),
            ),
          ),
        ],
      ),
    );
  }

  static String _statusText(WorkflowStatus s) => switch (s) {
    WorkflowStatus.running => 'Running',
    WorkflowStatus.done => 'Done',
    WorkflowStatus.failed => 'Failed',
    WorkflowStatus.capped => 'Hit its limit',
    WorkflowStatus.stopped => 'Stopped',
  };

  static Color _statusColor(EveryTheme theme, WorkflowStatus s) => switch (s) {
    WorkflowStatus.done => theme.success,
    WorkflowStatus.failed || WorkflowStatus.capped => theme.danger,
    _ => theme.textMuted,
  };
}

class _AgentRow extends StatelessWidget {
  const _AgentRow({required this.agent});
  final WorkflowAgentView agent;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final color = switch (agent.status) {
      WorkflowAgentStatus.queued => theme.border,
      WorkflowAgentStatus.running => theme.accent,
      WorkflowAgentStatus.done => theme.success,
      WorkflowAgentStatus.failed => theme.danger,
    };
    final where = [agent.harness, agent.model].where((s) => s.isNotEmpty).join(' · ');
    final row = Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              agent.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.type.caption.tint(theme.text),
            ),
          ),
          if (where.isNotEmpty) Text(where, maxLines: 1, style: theme.type.caption.tint(theme.textMuted)),
        ],
      ),
    );
    final child = agent.childId;
    if (child == null) return row;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => context.push(Routes.codeSession(child)),
      child: row,
    );
  }
}
