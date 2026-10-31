import '../../../core/ui/brand.dart';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/adaptive_page.dart';
import '../../../core/ui/every_icons.dart';
import '../../../core/ui/selection.dart';
import '../../models/domain/model_catalog.dart';
import '../../models/models_providers.dart';
import '../../questions/ui/question_card.dart';
import '../../usage/usage_totals.dart';
import '../code_providers.dart';
import '../morning_providers.dart';
import '../domain/agent_mode.dart';
import '../domain/code_session.dart';
import '../domain/permissions.dart';
import '../domain/questions.dart';
import '../domain/rewind.dart';
import '../domain/transcript.dart';
import '../harness/events.dart' show ExecutionStatus;
import 'agent_menu.dart';
import 'code_composer.dart';
import 'code_slash_host.dart';
import 'transcript/files_card.dart';
import 'code_top_bar.dart';
import 'phase_strip.dart';
import '../domain/phases.dart' show Phase;
import '../panes/panes_providers.dart';
import 'panes/session_panes.dart';
import 'transcript/approval_card.dart';
import 'transcript/aside_card.dart';
import 'transcript/goal_card.dart';
import 'transcript/plan_card.dart';
import 'transcript/retry_row.dart';
import 'transcript/subagent_card.dart';
import 'transcript/transcript_items.dart';

const _maxWidth = 780.0;

/// One coding session: the transcript, the approval/question surface and
/// the composer.
class CodeSessionScreen extends ConsumerWidget {
  const CodeSessionScreen({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final info = ref.watch(codeSessionsProvider.select((all) => all.where((s) => s.id == sessionId).firstOrNull));
    if (info == null) {
      return AdaptivePage(
        title: 'Code',
        body: Center(
          child: Text('This session no longer exists.', style: TextStyle(color: theme.textMuted)),
        ),
      );
    }
    final provider = codeSessionProvider(sessionId);
    final state = ref.watch(provider);
    final controller = ref.read(provider.notifier);
    final t = state.transcript;
    final busy = t.running || t.pending.isNotEmpty;

    final showStartBuilding =
        state.mode == AgentMode.plan &&
        !busy &&
        t.openQuestion == null &&
        t.items.whereType<PlanProposal>().isEmpty &&
        t.items.lastOrNull is AgentText &&
        t.items.whereType<UserTurn>().isNotEmpty;

    // The live mode → tier → Model → Effort menu, in the composer.
    Widget agentMenu() => AgentMenu(
      model: info.model,
      effort: info.effort,
      tier: info.tier,
      harnessMode: info.harnessMode,
      onHarnessMode: controller.setHarnessMode,
      onTier: controller.setTier,
      demo: isDemoPath(info.workingDir),
      onChanged: (model, effort) => switchCodeAgent(
        context,
        ref,
        sessionId,
        model: model == info.model ? null : model,
        effort: effort == info.effort ? null : effort,
      ),
    );

    // The header drops chips by the width it really has (the sidebar and the
    // panes take some), so the title keeps room and nothing jumps into an
    // overflow menu.
    return LayoutBuilder(
      builder: (context, box) {
        final tier = TopBarTier.forWidth(box.maxWidth);
        return AdaptivePage(
          title: info.title,
          onBack: info.parentId == null ? null : () => context.go(Routes.codeSession(info.parentId!)),
          backTooltip: 'Back to the parent session',
          actions: [
            CodeTopBar(sessionId: sessionId),
            if (info.diffTarget != null && tier != TopBarTier.narrow) _ChangesButton(sessionId: sessionId),
            if (panesFor(info).contains(CodePane.terminal))
              AdaptiveIconButton(
                icon: EveryIcon.openPanel,
                tooltip: 'Terminal, processes and preview',
                onPressed: ref.read(codePaneProvider(sessionId).notifier).toggleLast,
              ),
            StatusPill(status: state.status, dense: tier == TopBarTier.narrow, minWidth: 92),
            AdaptiveIconButton(
              icon: EveryIcon.newChat,
              tooltip: 'New session',
              onPressed: () => context.go(Routes.code),
            ),
          ],
          body: SessionPanes(
            session: info,
            child: Column(
              children: [
                Expanded(
                  child: TranscriptScope(
                    root: info.workingDir,
                    openDiff: panesFor(info).contains(CodePane.diff)
                        ? ref.read(codePaneProvider(sessionId).notifier).showFile
                        : null,
                    child: TranscriptList(
                      onRewind: (turn) => _rewind(context, ref, turn),
                      transcript: t,
                      onAnswer: controller.answer,
                      mode: state.mode,
                      onApprovePlan: controller.startBuilding,
                      onRevisePlan: controller.send,
                      onRetry: controller.retry,
                      sessionId: sessionId,
                      workingDir: info.workingDir,
                    ),
                  ),
                ),
                if (state.error case final error?)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: NoticeView(item: NoticeItem('error', error, error: true)),
                  )
                else if (!state.connected && t.items.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: NoticeView(item: const NoticeItem('reconnecting', 'Reconnecting to the agent server…')),
                  )
                else if (t.retry case final retry?)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: RetryRow(retry: retry, onRetryNow: controller.retryNow, onStop: controller.stop),
                  ),
                SafeArea(
                  top: false,
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: _maxWidth),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (t.pending.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: ApprovalCard(
                                  key: ValueKey(t.pending.map((c) => c.id).join()),
                                  pending: t.pending,
                                  mode: state.mode,
                                  onAllow: controller.approve,
                                  onDeny: controller.deny,
                                  onMode: controller.setMode,
                                  remember: controller.rememberable(),
                                  // The demo's commands never run; no need to ask about them.
                                  workingDir: isDemoPath(info.workingDir) ? null : info.workingDir,
                                  session: info.billingTag,
                                  decided: state.decided,
                                  rememberBy: controller.rememberBy(),
                                  onAllowCall: controller.perCall
                                      ? (id, scope) => controller.approve(scope, [id])
                                      : null,
                                  onDenyCall: controller.perCall ? (id) => controller.deny(null, [id]) : null,
                                  flags: {
                                    for (final c in t.pending)
                                      if (controller.policy.decide(c, state.mode) case Decision(
                                        source: DecisionSource.dangerous,
                                        :final why,
                                      ))
                                        c.id: why,
                                  },
                                ),
                              )
                            else if (t.plan.isNotEmpty && t.running)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: PlanView(tasks: t.plan, compact: true),
                              ),
                            if (t.phase case final p? when p.phase != Phase.done)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: PhaseStrip(flow: p.flow, phase: p.phase, stuck: p.stuck),
                              ),
                            if (showStartBuilding)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: StartBuildingBar(onStart: controller.startBuilding),
                              ),
                            if (ref.watch(morningBriefProvider) case final brief?)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: AsideCard(
                                  key: ValueKey(brief.id),
                                  aside: brief,
                                  onDismiss: ref.read(morningBriefProvider.notifier).dismiss,
                                ),
                              ),
                            if (state.goal case final goal?)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: GoalCard(goal: goal, onClear: controller.clearGoal),
                              ),
                            for (final aside in state.asides)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: AsideCard(
                                  key: ValueKey(aside.id),
                                  aside: aside,
                                  onDismiss: () => controller.dismissAside(aside.id),
                                  usage: ref.watch(codeUsageProvider(sessionId)).value ?? UsageTotals.zero,
                                  contextWindow:
                                      ref.watch(modelCatalogProvider)[ModelId(info.model)]?.contextLength ?? 0,
                                  modelName: ref.watch(modelCatalogProvider)[ModelId(info.model)]?.name,
                                  onSendToAgent: () => controller.sendReview(aside.id),
                                  onOpenSession: (id) => context.go(Routes.codeSession(id)),
                                  onCommit: (message) =>
                                      _gitAction(context, () => controller.commitDraft(aside.id, message)),
                                  onCreatePr: (title, body) => _gitAction(
                                    context,
                                    () async => 'Opened ${await controller.openPr(aside.id, title: title, body: body)}',
                                  ),
                                ),
                              ),
                            CodeComposer(
                              slashHost: codeSlashHost(context, ref, sessionId, busy: busy),
                              project: ref
                                  .watch(codeProjectsProvider)
                                  .where((p) => p.id == info.projectId)
                                  .firstOrNull
                                  ?.path,
                              busy: busy,
                              mode: state.mode,
                              onModeChanged: controller.setMode,
                              onSend: (text, files) => controller.send(text, files: files),
                              onSteer: (text, files) => controller.steer(text, files: files),
                              onStop: controller.stop,
                              queued: [for (final q in state.queued) q.text],
                              onUnqueue: controller.unqueue,
                              placeholder: t.openQuestion != null
                                  ? 'Answer the questions above, or reply in your own words'
                                  : 'Ask for a change, or reply to the agent',
                              trailing: agentMenu(),
                              model: ref.watch(modelCatalogProvider)[ModelId(info.model)],
                              meter: SessionMeter(sessionId: sessionId, model: info.model),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _rewind(BuildContext context, WidgetRef ref, int turn) async {
    final files = ref.read(codeSessionsProvider.notifier).byId(sessionId)?.worktree != null;
    final ok = await showAdaptiveConfirm(
      context,
      title: 'Rewind to here?',
      message: rewindPrompt('this message', files: files),
      confirmLabel: 'Rewind',
      destructive: true,
    );
    if (!ok) return;
    final outcome = await ref.read(codeSessionProvider(sessionId).notifier).rewind(turn);
    if (context.mounted) showAdaptiveToast(context, outcome.label);
  }
}

/// "3 files +40 −2": opens the Diff pane.
class _ChangesButton extends ConsumerWidget {
  const _ChangesButton({required this.sessionId});
  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final git = ref.watch(codeGitProvider(sessionId)).value;
    final open = ref.watch(codePaneProvider(sessionId).select((p) => p.open == CodePane.diff));
    final files = git?.files.length ?? 0;
    return GestureDetector(
      onTap: () => ref.read(codePaneProvider(sessionId).notifier).toggle(CodePane.diff),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 4),
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            color: open ? theme.accent.withValues(alpha: 0.14) : null,
            border: Border.all(color: open ? theme.accent : theme.border),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(text: files == 0 ? 'No changes' : '$files file${files == 1 ? '' : 's'} '),
                if (files > 0) ...[
                  TextSpan(
                    text: '+${git!.added} ',
                    style: TextStyle(color: theme.success),
                  ),
                  TextSpan(
                    text: '−${git.removed}',
                    style: TextStyle(color: theme.danger),
                  ),
                ],
              ],
            ),
            style: theme.type.callout.medium.tint(theme.text),
          ),
        ),
      ),
    );
  }
}

class TranscriptList extends StatelessWidget {
  const TranscriptList({
    super.key,
    required this.onRewind,
    required this.transcript,
    required this.mode,
    required this.onAnswer,
    required this.onApprovePlan,
    required this.onRevisePlan,
    required this.onRetry,
    this.sessionId,
    this.workingDir = '',
    this.trailing = const [],
  });

  /// Shown newest-side, below the items (the session's Ultra runs).
  final List<Widget> trailing;

  /// For the presented-files card's shortcuts.
  final String? sessionId;
  final String workingDir;

  final Transcript transcript;
  final AgentMode mode;
  final void Function(QuestionItem, List<QuestionAnswer>) onAnswer;

  /// Restores the files to before user turn n (1-based); null without git.
  final void Function(int turn)? onRewind;
  final VoidCallback onApprovePlan;
  final ValueChanged<String> onRevisePlan;

  /// Offered at the end while the session is failed or stuck.
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final t = transcript;
    final live = t.streaming.isNotEmpty || t.streamingReasoning.isNotEmpty;
    // Newest at the bottom; a reversed list keeps the view pinned there.
    final children = <Widget>[
      ...trailing.reversed,
      // One keyed tail slot: streaming text and the working row swap in place
      // instead of shifting every row's index.
      if (live)
        KeyedSubtree(
          key: const ValueKey('transcript-tail'),
          child: AgentTextView(text: t.streaming, reasoning: t.streamingReasoning, streaming: true),
        )
      else if (t.running)
        const KeyedSubtree(key: ValueKey('transcript-tail'), child: _Working())
      else if (t.status == ExecutionStatus.error || t.status == ExecutionStatus.stuck)
        NoticeView(
          item: NoticeItem(
            'stopped',
            t.status == ExecutionStatus.stuck
                ? 'The agent got stuck and stopped. Retry to let it carry on, or reply with directions.'
                : 'The agent stopped on an error. Retry to carry on from here.',
            error: true,
          ),
          onRetry: onRetry,
        ),
      for (final entry in groupSteps(t.items).reversed)
        if (entry is StepRun)
          StepRunView(key: ValueKey(entry.key), run: entry)
        // The task list shows above the composer while the agent works, not in the transcript too.
        else if (entry is! PlanItem)
          // Every row is keyed: unkeyed rows handed their expanded state to
          // whichever row of the same type slid into their index.
          KeyedSubtree(key: ValueKey((entry as TranscriptItem).key), child: _itemView(entry)),
    ];
    return AdaptiveSelectionArea(
      child: ListView.builder(
        reverse: true,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        itemCount: children.length,
        // Newest-first indices shift as items arrive; match rows by their key so
        // a card keeps its state (the question card's page) across rebuilds.
        findChildIndexCallback: (key) {
          if (key is! ValueKey<Object?>) return null;
          final i = children.indexWhere((c) => c.key == key.value);
          return i < 0 ? null : i;
        },
        itemBuilder: (context, i) => Center(
          key: children[i].key == null ? null : ValueKey(children[i].key),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _maxWidth),
            child: Padding(padding: const EdgeInsets.symmetric(vertical: 5), child: children[i]),
          ),
        ),
      ),
    );
  }

  Widget _itemView(TranscriptItem item) => switch (item) {
    UserTurn(:final text, :final mode) => Padding(
      padding: const EdgeInsets.only(top: 10),
      child: UserTurnView(
        text: text,
        mode: mode,
        onRewind: onRewind == null
            ? null
            : () => onRewind!(transcript.items.whereType<UserTurn>().toList().indexOf(item) + 1),
      ),
    ),
    AgentText(:final text, :final reasoning) => AgentTextView(text: text, reasoning: reasoning),
    ExploreGroup() => ExploreGroupView(group: item),
    StepItem(:final step) => StepView(step: step),
    SubagentItem() => SubagentCard(item: item),
    PlanItem(:final tasks) => PlanView(tasks: tasks),
    QuestionItem() => QuestionCard(
      key: ValueKey(item.key),
      questions: item.questions,
      answers: item.answers,
      enabled: item == transcript.openQuestion,
      onSubmit: (answers) => onAnswer(item, answers),
    ),
    PlanProposal() => PlanCard(
      key: ValueKey(item.key),
      plan: item,
      open: item == transcript.openPlan,
      switchesToAutoEdit: mode == AgentMode.plan,
      onApprove: onApprovePlan,
      onRevise: onRevisePlan,
    ),
    FilesDelivered() => FilesCard(item: item, workingDir: workingDir, sessionId: sessionId),
    NoticeItem() => NoticeView(item: item),
  };
}

class _Working extends StatelessWidget {
  const _Working();

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Row(
      children: [
        const EveryMarkActivity(size: 16),
        const SizedBox(width: 10),
        Text('Working…', style: theme.type.callout.tint(theme.textMuted)),
      ],
    );
  }
}

/// Plan mode's nudge once a plan is written: Start building switches to Auto-edit.
class StartBuildingBar extends StatelessWidget {
  const StartBuildingBar({super.key, required this.onStart});
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      decoration: BoxDecoration(
        color: theme.accent.withValues(alpha: 0.08),
        border: Border.all(color: theme.accent.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(EveryTheme.cardRadius),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Happy with the plan? Start building switches to Auto-edit.',
              style: theme.type.callout.tint(theme.text),
            ),
          ),
          AdaptiveButton(label: 'Start building', onPressed: onStart),
        ],
      ),
    );
  }
}

/// A coloured dot and label for a session's status.
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.status, this.dense = false, this.minWidth = 0});
  final SessionStatus status;
  final bool dense;

  /// Keeps the pill one width as the label changes, so the bar doesn't shift.
  final double minWidth;

  static Color colorOf(SessionStatus s, EveryTheme theme) => switch (s) {
    SessionStatus.running || SessionStatus.starting => theme.accent,
    SessionStatus.needsInput => theme.warning,
    SessionStatus.failed => theme.danger,
    SessionStatus.done => theme.success,
    SessionStatus.idle => theme.textMuted,
  };

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final color = colorOf(status, theme);
    final dot = Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
    if (dense) return Semantics(label: status.label, child: dot);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: ConstrainedBox(
        constraints: BoxConstraints(minWidth: minWidth),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            dot,
            const SizedBox(width: 6),
            Text(status.label, maxLines: 1, style: theme.type.callout.tint(theme.textMuted)),
          ],
        ),
      ),
    );
  }
}

/// Runs a git action from a card and tells the user how it went.
Future<void> _gitAction(BuildContext context, Future<String> Function() action) async {
  try {
    final done = await action();
    if (context.mounted) showAdaptiveToast(context, done);
  } on Object catch (e) {
    // GitError's text is the message itself.
    if (context.mounted) showAdaptiveToast(context, '$e');
  }
}
