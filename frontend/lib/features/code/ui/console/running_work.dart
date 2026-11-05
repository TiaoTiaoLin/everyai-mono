import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/router.dart';
import '../../../../core/theme/every_theme.dart';
import '../../../../core/ui/adaptive.dart';
import '../../../../core/ui/every_icons.dart';
import '../../code_providers.dart';
import '../subagent_banner.dart';
import '../../domain/code_session.dart';
import '../../harness/harness.dart' show BackgroundTask;
import '../../workflows/workflow_engine.dart' show WorkflowAgentStatus, WorkflowStatus;
import '../../workflows/workflow_runs.dart' show workflowRunsProvider;
import '../session_view.dart' show StatusPill, TranscriptList;
import '../transcript/transcript_items.dart' show TranscriptScope;
import '../transcript/session_approval.dart';
import 'console_state.dart';

/// Session info's Running work: the session's workflows and their agents, its forks and subagents (custom agents
/// included) and the commands it left running in the background, live. Clicking a session opens its chat in the
/// panel ([ConsolePanels.openChild]).
class RunningWork extends ConsumerStatefulWidget {
  const RunningWork({super.key, required this.session});

  final CodeSessionInfo session;

  @override
  ConsumerState<RunningWork> createState() => _RunningWorkState();
}

class _RunningWorkState extends ConsumerState<RunningWork> {
  Timer? _tick;

  /// Groups the user opened or folded, by key, per session: kept while a child's chat covers the list. A group not
  /// here follows [_isOpen]'s default.
  static final _openBySession = <String, Map<String, bool>>{};
  Map<String, bool> get _open => _openBySession[widget.session.id] ??= {};

  /// A group with work still going starts open; a finished one starts folded.
  bool _isOpen(String key, {required bool active}) => _open[key] ?? active;

  void _toggle(String key, {required bool active}) => setState(() => _open[key] = !_isOpen(key, active: active));

  /// A group header that folds its rows ([count] of them when folded).
  Widget _group(String key, String title, {required bool active, required int count, required List<Widget> rows}) {
    final open = _isOpen(key, active: active);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _Header(
          title,
          open: open,
          count: count,
          onTap: () => _toggle(key, active: active),
        ),
        if (open) ...rows,
      ],
    );
  }

  @override
  void initState() {
    super.initState();
    // Background shells change without events; elapsed times move. Only while the section is shown.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _steer(CodeSessionInfo child) async {
    final text = await showAdaptivePrompt(context, title: 'Message ${child.title}', confirmLabel: 'Send');
    if (text == null || text.trim().isEmpty) return;
    await ref.read(codeSessionProvider(child.id).notifier).steer(text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final id = widget.session.id;
    final children = ref.watch(
      codeSessionsProvider.select(
        (all) => [
          for (final s in all)
            if (s.parentId == id) s,
        ],
      ),
    );
    final byId = {for (final c in children) c.id: c};
    final runs = [...ref.watch(workflowRunsProvider(id))]
      ..sort(
        (a, b) => (a.status == WorkflowStatus.running ? 0 : 1).compareTo(b.status == WorkflowStatus.running ? 0 : 1),
      );
    final inRuns = {
      for (final r in runs)
        for (final a in r.agents) ?a.childId,
    };
    final shells = ref.read(codeSessionProvider(id).notifier).backgroundTasks;
    final panel = ref.read(consolePanelProvider(id).notifier);

    Widget childRow(CodeSessionInfo child) => _ChildRow(
      key: ValueKey('console.running.${child.id}'),
      child: child,
      onOpen: () => panel.openChild(child.id),
      onSteer: () => _steer(child),
      onStop: () => ref.read(codeSessionProvider(child.id).notifier).stop(),
    );

    final forks = [
      for (final c in children.reversed)
        if (!inRuns.contains(c.id)) c,
    ];
    bool over(CodeSessionInfo c) =>
        const {SessionStatus.done, SessionStatus.failed, SessionStatus.idle}.contains(_statusOf(ref, c.id));
    final working = [
      for (final c in forks)
        if (!over(c)) c,
    ];
    final finished = [
      for (final c in forks)
        if (over(c)) c,
    ];
    if (runs.isEmpty && children.isEmpty && shells.isEmpty) {
      return Text(
        'Workflows, forks, subagents and commands the agent leaves running in the background show up here.',
        style: theme.type.callout.tint(theme.textMuted),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, run) in runs.indexed)
          _group(
            'run-$i-${run.name}-${run.agents.firstOrNull?.childId ?? ''}',
            '${run.name} · ${run.status.name} · '
                '${run.agents.where((a) => a.status == WorkflowAgentStatus.done).length}/${run.agents.length} agents done',
            active: run.status == WorkflowStatus.running,
            count: run.agents.length,
            rows: [
              for (final a in run.agents)
                if (a.childId case final c? when byId.containsKey(c))
                  childRow(byId[c]!)
                else
                  _Line(title: a.label, subtitle: '${a.phase} · ${a.status.name}'),
            ],
          ),
        if (forks.isNotEmpty) ...[
          // Working (or waiting) forks always show; the finished ones fold into their own group.
          if (working.isNotEmpty) ...[const _Header('Forks and subagents'), for (final c in working) childRow(c)],
          if (finished.isNotEmpty)
            _group(
              'forks-done',
              working.isEmpty ? 'Forks and subagents · ${finished.length} done' : '${finished.length} done',
              active: false,
              count: finished.length,
              rows: [for (final c in finished) childRow(c)],
            ),
        ],
        if (shells.isNotEmpty)
          _group(
            'shells',
            'Background commands',
            active: shells.any((t) => t.running),
            count: shells.length,
            rows: [
              for (final t in shells.reversed)
                _ShellRow(task: t, onStop: () => ref.read(codeSessionProvider(id).notifier).stopBackground(t.id)),
            ],
          ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text, {this.open, this.count = 0, this.onTap});
  final String text;

  /// Null: a plain heading; else a fold toggle that shows whether its rows are open.
  final bool? open;
  final int count;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final open = this.open;
    final label = Padding(
      padding: const EdgeInsets.fromLTRB(2, 6, 2, 4),
      child: Row(
        children: [
          if (open != null) ...[
            AdaptiveIcon(open ? EveryIcon.chevronDown : EveryIcon.chevronRight, size: 12, color: theme.textMuted),
            const SizedBox(width: 4),
          ],
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.type.caption.semibold.tint(theme.textMuted),
            ),
          ),
          if (open == false && count > 0) Text('$count', style: theme.type.caption.tint(theme.textMuted)),
        ],
      ),
    );
    if (open == null || onTap == null) return label;
    return Semantics(
      button: true,
      expanded: open,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap, child: label),
      ),
    );
  }
}

String _elapsed(DateTime from) {
  final d = DateTime.now().difference(from);
  if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes % 60}m';
  if (d.inMinutes > 0) return '${d.inMinutes}m ${d.inSeconds % 60}s';
  return '${d.inSeconds}s';
}

/// The status of a session that may not be open: live when its controller runs, else the last one the harness told.
SessionStatus _statusOf(WidgetRef ref, String id) => ref.exists(codeSessionProvider(id))
    ? ref.watch(codeSessionProvider(id).select((s) => s.status))
    : ref.watch(codeStatusesProvider.select((all) => all[id])) ?? SessionStatus.idle;

class _Line extends StatelessWidget {
  const _Line({required this.title, required this.subtitle, this.leading, this.trailing = const []});

  final String title;
  final String subtitle;
  final Widget? leading;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
      decoration: BoxDecoration(
        border: Border.all(color: theme.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 8)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.type.callout.tint(theme.text)),
                Text(subtitle, maxLines: 1, style: theme.type.caption.tint(theme.textMuted)),
              ],
            ),
          ),
          ...trailing,
        ],
      ),
    );
  }
}

class _ChildRow extends ConsumerWidget {
  const _ChildRow({super.key, required this.child, required this.onOpen, required this.onSteer, required this.onStop});

  final CodeSessionInfo child;
  final VoidCallback onOpen;
  final VoidCallback onSteer;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = _statusOf(ref, child.id);
    final working = status == SessionStatus.running || status == SessionStatus.starting;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onOpen,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Semantics(
          button: true,
          label: 'Open ${child.title}',
          child: _Line(
            leading: StatusPill(status: status, dense: true),
            title: child.title,
            subtitle: '${status.label} · ${_elapsed(child.createdAt)}',
            trailing: [
              if (working) ...[
                AdaptiveButton(label: 'Steer', emphasis: ButtonEmphasis.plain, onPressed: onSteer),
                AdaptiveButton(label: 'Stop', emphasis: ButtonEmphasis.plain, onPressed: onStop),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ShellRow extends StatelessWidget {
  const _ShellRow({required this.task, required this.onStop});

  final BackgroundTask task;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) => _Line(
    title: task.description.isNotEmpty ? task.description : task.command,
    subtitle: '${task.id} · ${task.running ? 'running ${_elapsed(task.startedAt)}' : 'exited (${task.exitCode})'}',
    trailing: [if (task.running) AdaptiveButton(label: 'Stop', emphasis: ButtonEmphasis.plain, onPressed: onStop)],
  );
}

/// A child session's chat in the right panel: Back to the view under it, its title and status, a way to open it as
/// a full session, its approval card when it waits on the user, then its transcript (the composer is on its own
/// screen).
class ChildChatView extends ConsumerWidget {
  const ChildChatView({super.key, required this.parentId, required this.childId});

  final String parentId;
  final String childId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final info = ref.watch(codeSessionsProvider.select((all) => all.where((s) => s.id == childId).firstOrNull));
    final back = ref.read(consolePanelProvider(parentId).notifier).back;
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 8, 6),
      child: Row(
        children: [
          AdaptiveIconButton(
            key: const ValueKey('console.child.back'),
            icon: EveryIcon.chevronLeft,
            tooltip: 'Back to the main chat',
            size: 16,
            onPressed: back,
          ),
          Expanded(
            child: Text(
              info?.title ?? 'Session',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.type.headline.tint(theme.text),
            ),
          ),
          if (info != null) StatusPill(status: _statusOf(ref, childId), dense: true),
          if (info != null)
            AdaptiveButton(
              key: const ValueKey('console.child.open'),
              label: 'Open full session',
              emphasis: ButtonEmphasis.plain,
              onPressed: () => context.go(Routes.codeSession(childId)),
            ),
        ],
      ),
    );
    if (info == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text('This session no longer exists.', style: theme.type.callout.tint(theme.textMuted)),
          ),
        ],
      );
    }
    final state = ref.watch(codeSessionProvider(childId));
    final controller = ref.read(codeSessionProvider(childId).notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        Container(height: 1, color: theme.border),
        SubagentBanner(session: info, onBack: back),
        // Answered here, on the child's own controller.
        if (state.transcript.pending.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: SingleChildScrollView(child: SessionApprovalCard(sessionId: childId)),
            ),
          ),
        Expanded(
          child: TranscriptScope(
            root: info.workingDir,
            child: TranscriptList(
              onRewind: null,
              transcript: state.transcript,
              mode: state.mode,
              onAnswer: controller.answer,
              onApprovePlan: controller.startBuilding,
              onRevisePlan: controller.send,
              onRetry: controller.retry,
              sessionId: childId,
              workingDir: info.workingDir,
            ),
          ),
        ),
      ],
    );
  }
}
