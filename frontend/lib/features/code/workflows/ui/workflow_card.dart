// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';

import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/router.dart';
import '../../../../core/theme/every_theme.dart';
import '../../../../core/ui/adaptive.dart';
import '../../../../core/ui/brand.dart';
import '../../../../core/ui/every_icons.dart';
import '../../code_providers.dart';
import '../../domain/code_session.dart' show SessionStatus;
import '../workflow_engine.dart';
import '../workflow_landing.dart';
import '../workflow_runs.dart';
import '../workflow_summary.dart';

/// The session's workflow runs, newest last, for the end of the transcript.
class WorkflowRunsView extends ConsumerWidget {
  const WorkflowRunsView({super.key, required this.sessionId});
  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final all = ref.watch(workflowRunsProvider(sessionId));
    final store = ref.read(workflowRunsProvider(sessionId).notifier);
    final runs = [
      for (final r in all)
        if (!store.dismissed.contains(r.runId)) r,
    ];
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
              onDismiss: () => _dismiss(context, ref, sessionId, store, run),
              landing: _landingOf(context, ref, sessionId, run),
            ),
          ),
      ],
    );
  }
}

/// Closing a card that still asks counts as leaving the changes uncommitted, so the lead isn't left waiting.
void _dismiss(BuildContext context, WidgetRef ref, String sessionId, WorkflowRuns store, WorkflowRun run) {
  _landingOf(context, ref, sessionId, run)?.onLeave?.call();
  store.dismiss(run.runId);
}

WorkflowLanding? _landingOf(BuildContext context, WidgetRef ref, String sessionId, WorkflowRun run) {
  final picked = ref.watch(workflowLandingProvider(sessionId))[run.runId];
  if (picked != null && picked.ok) return WorkflowLanding.chosen(picked.text);
  if (!workflowAsksLanding(run)) return null;
  if (!(ref.watch(workflowDirtyProvider((sessionId: sessionId, runId: run.runId))).value ?? false)) return null;
  final session = ref.read(codeSessionProvider(sessionId).notifier);
  Future<void> ask(WorkflowLand choice) async {
    final message = await showAdaptivePrompt(
      context,
      title: choice == WorkflowLand.commit ? 'Commit message' : 'Commit message for the new branch',
      confirmLabel: 'Next',
      initialValue: workflowCommitMessage(run),
    );
    if (message == null || message.trim().isEmpty || !context.mounted) return;
    var branch = '';
    if (choice == WorkflowLand.branch) {
      final named = await showAdaptivePrompt(
        context,
        title: 'Branch name (this switches your checkout to it)',
        confirmLabel: 'Commit',
        initialValue: workflowBranchName(run),
      );
      if (named == null || named.trim().isEmpty) return;
      branch = named.trim();
    }
    await session.landWorkflow(run, choice, message: message.trim(), branch: branch);
  }

  return WorkflowLanding(
    error: picked?.text,
    onCommit: () => ask(WorkflowLand.commit),
    // A session with its own branch keeps it: the commit lands there, and the branch is what merge and PR use.
    onBranch: ref.read(codeSessionsProvider.notifier).byId(sessionId)?.worktree == null
        ? () => ask(WorkflowLand.branch)
        : null,
    onLeave: () => session.landWorkflow(run, WorkflowLand.leave),
  );
}

/// What the user can do with a finished run's uncommitted work, or (once chosen) what they did.
class WorkflowLanding {
  const WorkflowLanding({required this.onCommit, required this.onBranch, required this.onLeave, this.error})
    : chosen = null;
  const WorkflowLanding.chosen(String this.chosen) : onCommit = null, onBranch = null, onLeave = null, error = null;

  final String? chosen;
  final VoidCallback? onCommit;
  final VoidCallback? onBranch;
  final VoidCallback? onLeave;

  /// Why the last try failed.
  final String? error;
}

/// One run: its phases, each with its agents (tap one to open its session)
/// and log lines, then what it used of its caps.
class WorkflowCard extends StatelessWidget {
  const WorkflowCard({super.key, required this.run, this.onStop, this.onDismiss, this.landing});
  final WorkflowRun run;
  final VoidCallback? onStop;

  /// Closes a finished run's card (done, failed, capped or stopped); a running one has Stop instead.
  final VoidCallback? onDismiss;

  /// The commit choice for a finished run whose work is waiting uncommitted; null when there is none.
  final WorkflowLanding? landing;

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
              Text(workflowStatusText(run.status), style: theme.type.caption.tint(_statusColor(theme, run.status))),
              if (running && onStop != null) ...[
                const SizedBox(width: 8),
                AdaptiveButton(label: 'Stop', emphasis: ButtonEmphasis.plain, onPressed: onStop),
              ],
              if (!running && onDismiss != null) ...[
                const SizedBox(width: 4),
                AdaptiveIconButton(
                  key: ValueKey('workflow.dismiss.${run.runId}'),
                  icon: EveryIcon.close,
                  tooltip: 'Dismiss',
                  size: 14,
                  onPressed: onDismiss,
                ),
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
          if (!running && (run.result != null || run.error != null)) _Result(run: run),
          if (landing case final l?) _LandingRow(landing: l),
        ],
      ),
    );
  }

  static Color _statusColor(EveryTheme theme, WorkflowStatus s) => switch (s) {
    WorkflowStatus.done => theme.success,
    WorkflowStatus.failed || WorkflowStatus.capped => theme.danger,
    _ => theme.textMuted,
  };
}

/// The verdict-first summary of a finished run, with the full result folded under Details.
class _Result extends StatefulWidget {
  const _Result({required this.run});
  final WorkflowRun run;

  @override
  State<_Result> createState() => _ResultState();
}

class _ResultState extends State<_Result> {
  var _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final run = widget.run;
    // The first line is the card's own header and footer; the rest is what the result says.
    final lines = workflowSummary(run).split('\n').skip(1).join('\n');
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (lines.isNotEmpty) SelectableText(lines, style: theme.type.caption.tint(theme.text)),
          if (run.result != null) ...[
            GestureDetector(
              key: ValueKey('workflow.details.${run.runId}'),
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _open = !_open),
              child: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    AdaptiveIcon(
                      _open ? EveryIcon.chevronDown : EveryIcon.chevronRight,
                      size: 12,
                      color: theme.textMuted,
                    ),
                    const SizedBox(width: 4),
                    Text('Details', style: theme.type.caption.tint(theme.textMuted)),
                  ],
                ),
              ),
            ),
            if (_open)
              Container(
                margin: const EdgeInsets.only(top: 4),
                padding: const EdgeInsets.all(8),
                constraints: const BoxConstraints(maxHeight: 280),
                decoration: BoxDecoration(
                  border: Border.all(color: theme.border),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    const JsonEncoder.withIndent('  ').convert(run.result),
                    style: theme.type.caption.mono.tint(theme.text),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _LandingRow extends StatelessWidget {
  const _LandingRow({required this.landing});
  final WorkflowLanding landing;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    if (landing.chosen case final done?) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(done, style: theme.type.caption.tint(theme.textMuted)),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Its changes are in your folder, not committed.', style: theme.type.caption.tint(theme.textMuted)),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              AdaptiveButton(label: 'Commit here', onPressed: landing.onCommit),
              AdaptiveButton(label: 'New branch', emphasis: ButtonEmphasis.secondary, onPressed: landing.onBranch),
              AdaptiveButton(label: 'Leave uncommitted', emphasis: ButtonEmphasis.plain, onPressed: landing.onLeave),
            ],
          ),
          if (landing.error case final e?) Text(e, style: theme.type.caption.tint(theme.danger)),
        ],
      ),
    );
  }
}

class _AgentRow extends ConsumerWidget {
  const _AgentRow({required this.agent});
  final WorkflowAgentView agent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final child = agent.childId;
    // A running agent may be waiting on an approval in its own session.
    final waits =
        agent.status == WorkflowAgentStatus.running &&
        child != null &&
        ref.watch(codeSessionProvider(child).select((s) => s.status == SessionStatus.needsInput));
    final color = switch (agent.status) {
      _ when waits => theme.warning,
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
          if (waits)
            Text('Needs you · open', maxLines: 1, style: theme.type.caption.tint(theme.warning))
          else if (where.isNotEmpty)
            Text(where, maxLines: 1, style: theme.type.caption.tint(theme.textMuted)),
        ],
      ),
    );
    if (child == null) return row;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => context.push(Routes.codeSession(child)),
      child: row,
    );
  }
}
