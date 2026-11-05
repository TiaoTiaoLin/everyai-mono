import 'dart:async';

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
import 'subagent_banner.dart';
import '../limit_providers.dart' show codePlanLimitsProvider;
import '../morning_providers.dart';
import '../domain/agent_mode.dart';
import '../domain/code_session.dart';
import '../domain/floor_advice.dart';
import '../domain/questions.dart';
import '../domain/rewind.dart';
import '../domain/session_commands.dart' show AsideKind;
import 'console/session_info_view.dart' show usageLines;
import '../domain/transcript.dart';
import '../code_settings_providers.dart' show codeSettingsProvider;
import '../drivers/driver_policy.dart' show fidelityNote;
import '../../settings/byok_keys.dart' show modelBillingProvider;
import '../drivers/driver_registry.dart';
import '../harness/events.dart' show ExecutionStatus;
import 'agent_menu.dart';
import 'code_composer.dart';
import 'limit_banner.dart';
import 'code_slash_host.dart';
import 'transcript/files_card.dart';
import 'code_top_bar.dart';
import 'console/console_header.dart';
import 'console/console_state.dart';
import 'console/bottom_drawer.dart';
import 'console/console_layout.dart';
import '../panes/panes_providers.dart' show codePaneProvider;
import 'transcript/approval_card.dart';
import 'transcript/session_approval.dart';
import 'transcript/aside_card.dart';
import 'transcript/goal_card.dart';
import 'transcript/lead_offer_card.dart';
import 'transcript/plan_card.dart';
import 'transcript/retry_row.dart';
import 'transcript/subagent_card.dart';
import 'transcript/transcript_items.dart';
import '../workflows/ui/workflow_card.dart';
import '../workflows/workflow_engine.dart' show WorkflowStatus;
import '../workflows/workflow_runs.dart' show workflowRunsProvider;

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
        body: Center(child: Text('This session no longer exists.', style: theme.type.body.tint(theme.textMuted))),
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
        t.items.whereType<PlanProposal>().every((p) => p.shown) &&
        (t.items.lastOrNull is AgentText || t.items.lastOrNull is PlanProposal) &&
        t.items.whereType<UserTurn>().isNotEmpty;

    // The live harness → mode → tier → Model → Effort menu, in the composer.
    AgentMenu agentMenu() => AgentMenu(
      harness: info.harness,
      model: info.model,
      effort: info.effort,
      level: info.tier,
      onLevel: controller.setTier,
      // A workflow's own agents and subagents don't start workflows.
      workflow: controller.workflowPick,
      onWorkflow: info.isSubagent ? null : controller.pickWorkflow,
      workflowBusy: ref.watch(workflowRunsProvider(sessionId)).any((r) => r.status == WorkflowStatus.running)
          ? 'A workflow is running: pick another once its result is in'
          : null,
      projectDir:
          ref.watch(codeProjectsProvider).where((p) => p.id == info.projectId).firstOrNull?.path ?? info.workingDir,
      demo: isDemoPath(info.workingDir),
      // Any time, from the menu; a subagent keeps its parent's lead.
      onHarness: info.isSubagent || isDemoPath(info.workingDir)
          ? null
          : (harness) => _switchLead(context, ref, harness, run: false),
      switchesLive: true,
      onChanged: (model, effort) => switchCodeAgent(
        context,
        ref,
        sessionId,
        model: model == info.model ? null : model,
        effort: effort == info.effort ? null : effort,
      ),
    );

    // The lead ran out: carry on with another harness, or wait. Reopened
    // with Change after an automatic handoff, it shows below the run.
    final pick = controller.limitPick;
    final offer = pick == null
        ? null
        : LeadOfferCard(
            key: ValueKey('lead-offer-${pick.change}'),
            lead: _label(ref, pick.ranOut),
            current: _label(ref, info.harness),
            limit: pick.limit,
            credits: !isOutsideLead(pick.ranOut, info.workingDir),
            change: pick.change,
            problem: pick.problem,
            choices: _leadChoices(ref, info, controller, ranOut: pick.ranOut),
            onSwitch: (harness, makeDefault) {
              if (makeDefault) ref.read(codeLeadProvider.notifier).chooseHandoff(harness);
              unawaited(_switchLead(context, ref, harness, run: true));
            },
            onWait: pick.change ? controller.keepLead : controller.waitForLimit,
          );

    // How far the mode holds on an outside lead, in one line under the bar.
    final driver = isOutsideLead(info.harness, info.workingDir)
        ? ref.read(driverRegistryProvider).resolve(info.harness)
        : null;
    // None when it runs in one of its own modes: the harness's name for it says how it holds.
    final fidelity = driver == null || state.inNativeMode ? null : fidelityNote(driver, state.mode);

    // The console fits the width it really has (the sidebar takes some): the
    // panel beside the transcript, then over it, then the view icons in ⋯.
    return LayoutBuilder(
      builder: (context, box) {
        final tier = ConsoleTier.forWidth(box.maxWidth);
        // ⌃` anywhere on the screen (the header, the Files editor) toggles the drawer, not just under it.
        return CallbackShortcuts(
          bindings: {
            if (drawerPanesFor(info).isNotEmpty)
              drawerToggleKey: ref.read(codePaneProvider(sessionId).notifier).toggleDrawer,
          },
          child: AdaptivePage(
            title: info.title,
            titleWidget: ConsoleTitle(info: info),
            onBack: info.parentId == null ? null : () => context.go(Routes.codeSession(info.parentId!)),
            backTooltip: 'Back to the main chat',
            header: fidelity == null && info.parentId == null
                ? null
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // A fork's or workflow agent's own chat says so, and goes back to the main chat.
                      if (info.parentId case final parent?)
                        SubagentBanner(session: info, onBack: () => context.go(Routes.codeSession(parent))),
                      if (fidelity != null)
                        Padding(
                          key: const ValueKey('session.fidelity'),
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
                          child: Text(
                            fidelity,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.type.caption.tint(theme.textMuted),
                          ),
                        ),
                    ],
                  ),
            actions: [
              ConsoleActions(info: info, tier: tier),
              StatusPill(status: state.status, dense: tier != ConsoleTier.wide, minWidth: 92),
              AdaptiveIconButton(
                icon: EveryIcon.newChat,
                tooltip: 'New session',
                onPressed: () => context.go(Routes.code),
              ),
            ],
            body: LayoutBuilder(
              builder: (context, body) => ConsoleLayout(
                session: info,
                tier: ConsoleTier.forWidth(body.maxWidth),
                child: BottomDrawer(
                  session: info,
                  child: LayoutBuilder(
                    builder: (context, area) => Column(
                      children: [
                        Expanded(
                          child: TranscriptScope(
                            root: info.workingDir,
                            openDiff: info.diffTarget != null
                                ? ref.read(consolePanelProvider(sessionId).notifier).showDiff
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
                              offer: pick?.change ?? true ? null : offer,
                              trailing: [
                                WorkflowRunsView(key: const ValueKey('workflow-runs'), sessionId: sessionId),
                                if (pick?.change ?? false) offer!,
                              ],
                              onChangeHandoff: controller.changeHandoff,
                              showLeads: info.leads.isNotEmpty,
                            ),
                          ),
                        ),
                        // Notices, cards and the composer: at most 70% of a short window, scrolling (pinned to the
                        // composer) past that, so the transcript always keeps some room and nothing overflows.
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxHeight: area.maxHeight.isFinite ? area.maxHeight * 0.7 : double.infinity,
                          ),
                          child: SingleChildScrollView(
                            primary: false,
                            reverse: true,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                if (state.error case final error?)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 16),
                                    child: NoticeView(item: NoticeItem('error', error, error: true)),
                                  )
                                else if (!state.connected && t.items.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 16),
                                    child: NoticeView(
                                      item: const NoticeItem('reconnecting', 'Reconnecting to the agent server…'),
                                    ),
                                  )
                                else if (t.retry case final retry?)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 16),
                                    child: RetryRow(
                                      retry: retry,
                                      onRetryNow: controller.retryNow,
                                      onStop: controller.stop,
                                    ),
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
                                                  // None for the demo (its commands never run) or an outside lead (no EveryAI spend).
                                                  workingDir: riskLabelDir(info),
                                                  session: info.billingTag,
                                                  decided: state.decided,
                                                  rememberBy: controller.rememberBy(),
                                                  onAllowCall: controller.perCall
                                                      ? (id, scope) => controller.approve(scope, [id])
                                                      : null,
                                                  onDenyCall: controller.perCall
                                                      ? (id) => controller.deny(null, [id])
                                                      : null,
                                                  flags: approvalFlags(controller.policy, t.pending, state.mode),
                                                  reasons: controller.askReasons(t.pending),
                                                  forks: info.sharesApprovals,
                                                ),
                                              )
                                            else if (t.plan.isNotEmpty && t.running)
                                              Padding(
                                                padding: const EdgeInsets.only(bottom: 8),
                                                child: PlanView(tasks: t.plan, compact: true),
                                              ),
                                            // A fork or subagent waiting on the user asks here too, not only in its own view.
                                            ChildApprovals(parentId: sessionId),
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
                                                  usage:
                                                      ref.watch(codeUsageProvider(sessionId)).value ?? UsageTotals.zero,
                                                  contextWindow:
                                                      ref
                                                          .watch(modelCatalogProvider)[ModelId(info.model)]
                                                          ?.contextLength ??
                                                      0,
                                                  modelName: ref.watch(modelCatalogProvider)[ModelId(info.model)]?.name,
                                                  // The cap and plan limit lines; the calls line is the breakdown above.
                                                  limitLines: aside.kind != AsideKind.cost
                                                      ? const []
                                                      : usageLines(
                                                          totals:
                                                              ref.watch(codeUsageProvider(sessionId)).value ??
                                                              UsageTotals.zero,
                                                          budget: ref.watch(codeSettingsProvider).budgets[sessionId],
                                                          limit: controller.limitPick?.limit,
                                                          plan: ref.watch(codePlanLimitsProvider(sessionId)),
                                                          // The lead's own report (below) says what it knows of the plan.
                                                          outsideLabel:
                                                              isOutsideLead(info.harness, info.workingDir) &&
                                                                  !aside.busy &&
                                                                  aside.answer.isEmpty
                                                              ? (driver?.info.label ?? info.harness)
                                                              : null,
                                                        ).skip(1).toList(),
                                                  onSendToAgent: () => controller.sendReview(aside.id),
                                                  onOpenSession: (id) => context.go(Routes.codeSession(id)),
                                                  onCommit: (message) => _gitAction(
                                                    context,
                                                    () => controller.commitDraft(aside.id, message),
                                                  ),
                                                  onCreatePr: (title, body) => _gitAction(
                                                    context,
                                                    () async =>
                                                        'Opened ${await controller.openPr(aside.id, title: title, body: body)}',
                                                  ),
                                                ),
                                              ),
                                            CodeComposer(
                                              sessionId: sessionId,
                                              slashHost: codeSlashHost(context, ref, sessionId, busy: busy),
                                              project: ref
                                                  .watch(codeProjectsProvider)
                                                  .where((p) => p.id == info.projectId)
                                                  .firstOrNull
                                                  ?.path,
                                              busy: busy,
                                              mode: state.mode,
                                              onModeChanged: controller.setMode,
                                              onSend: (text, files) => controller.sendTyped(text, files: files),
                                              onSteer: (text, files) => controller.steer(text, files: files),
                                              onStop: controller.stop,
                                              queued: [for (final q in state.queued) q.text],
                                              onUnqueue: controller.unqueue,
                                              placeholder: t.openQuestion != null
                                                  ? 'Answer the questions above, or reply in your own words'
                                                  : info.parentId != null
                                                  ? 'Message this subagent (not the main chat)'
                                                  : 'Ask for a change, or reply to the agent',
                                              agent: agentMenu(),
                                              // The lead-offer card says it louder once the limit has hit.
                                              banner: pick == null ? LimitBanner(sessionId: sessionId) : null,
                                              model: ref.watch(modelCatalogProvider)[ModelId(info.model)],
                                              meter: SessionMeter(sessionId: sessionId, model: info.model),
                                              // An outside lead's own commands (empty until listed, never ours); null: EveryAI's.
                                              commands: ref.watch(nativeSlashMenuProvider(sessionId)),
                                              onUnlistedCommand: controller.runTypedCommand,
                                              // Ours while no native mode carries the session's (Plan on Codex).
                                              nativeModes: state.inNativeMode ? state.nativeModes : null,
                                              nativeMode: state.nativeMode,
                                              harnessLabel: driver?.info.label ?? '',
                                              onNativeModeChanged: (id) async {
                                                final why = await controller.setNativeMode(id);
                                                if (why != null && context.mounted) showAdaptiveToast(context, why);
                                              },
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
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  static String _label(WidgetRef ref, String harness) =>
      ref.read(driverRegistryProvider).resolve(harness)?.info.label ?? harness;

  /// The harnesses found here the session can move to (not the one on now,
  /// nor [ranOut]), each with the model it would use and how that is paid;
  /// one that isn't signed in or allowed says how to fix it.
  static List<LeadChoice> _leadChoices(
    WidgetRef ref,
    CodeSessionInfo session,
    CodeSessionController controller, {
    required String ranOut,
  }) {
    final statuses = ref.watch(driverStatusesProvider).value;
    final own = ref.watch(codeSettingsProvider.select((s) => s.ownClis));
    final catalog = ref.watch(modelCatalogProvider);
    return [
      for (final (:info, :blocked) in handoffChoices(
        ref.read(driverRegistryProvider).listed,
        statuses,
        own,
        current: session.harness,
        ranOut: ranOut,
      ))
        if (controller.leadModelFor(info.id) case (:final model, effort: _))
          (
            id: info.id,
            label: info.label,
            subtitle: isOutsideLead(info.id, session.workingDir)
                ? '${model.isEmpty ? 'Default model' : model} · on your plan'
                : '${catalog[ModelId(model)]?.name ?? model.split('/').last} · '
                      '${ref.read(modelBillingProvider).ownKey(ModelId(model)) ? 'your own key' : 'credits'}',
            blocked: blocked,
          ),
    ];
  }

  /// Moves the session to [harness]: a busy one is stopped first, once the user agrees.
  Future<void> _switchLead(BuildContext context, WidgetRef ref, String harness, {required bool run}) async {
    final controller = ref.read(codeSessionProvider(sessionId).notifier);
    final info = ref.read(codeSessionsProvider.notifier).byId(sessionId);
    if (info == null) return;
    if (ref.read(codeSessionProvider(sessionId)).switching) {
      showAdaptiveToast(context, 'The session is already switching harness.');
      return;
    }
    final t = ref.read(codeSessionProvider(sessionId)).transcript;
    final working = t.running || t.pending.isNotEmpty || t.held.isNotEmpty || t.openSubagents.isNotEmpty;
    // Background forks and research workers on EveryAI stop when it no longer leads.
    final children = controller.leaveStopsChildren(harness);
    final busy = working || children;
    final from = _label(ref, info.harness);
    final to = _label(ref, harness);
    if (busy &&
        !await showAdaptiveConfirm(
          context,
          title: 'Stop $from and switch to $to?',
          message:
              '${working ? '$from stops where it is. ' : ''}'
              '${children ? 'Its background forks and researchers stop too. ' : ''}'
              '$to gets the work so far, and the files stay as they are.',
          confirmLabel: 'Stop and switch',
        )) {
      return;
    }
    final outcome = await controller.switchLead(harness, run: run, stopFirst: busy);
    if (!context.mounted) return;
    showAdaptiveToast(
      context,
      outcome.busy
          ? '$from is still working. Stop it, then switch.'
          : outcome.failed
          ? outcome.message
          : '${run ? '$to is taking over.' : '$to takes over with your next message.'}'
                '${outcome.path == null ? '' : _pathSuffix(outcome.path!)}',
    );
  }

  /// What the toast adds about the path: only a return that reused or rebuilt the lead's conversation.
  String _pathSuffix(LeadPath path) => switch (path) {
    LeadPath.resumed => ' It continues its earlier conversation.',
    LeadPath.imported => ' It got a copy of the conversation in its own format.',
    LeadPath.fresh => '',
  };

  Future<void> _rewind(BuildContext context, WidgetRef ref, int turn) async {
    final files = ref.read(codeSessionsProvider.notifier).byId(sessionId)?.worktree != null;
    final ok = await showAdaptiveConfirm(
      context,
      title: 'Rewind to here?',
      message: rewindPrompt(
        'this message',
        files: files,
        conversation: ref.read(codeSessionProvider(sessionId).notifier).rewindsConversation,
      ),
      confirmLabel: 'Rewind',
      destructive: true,
    );
    if (!ok) return;
    final outcome = await ref.read(codeSessionProvider(sessionId).notifier).rewind(turn);
    if (context.mounted) showAdaptiveToast(context, outcome.label);
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
    this.offer,
    this.onChangeHandoff,
    this.showLeads = false,
  });

  /// Change on an automatic handoff away from a driver id (its notice).
  final ValueChanged<String>? onChangeHandoff;

  /// Shown at the end in place of the "stopped" notice: the offer to carry
  /// on with another harness after a usage limit.
  final Widget? offer;

  /// Each message names the harness it went to (the session had several).
  final bool showLeads;

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
      else if (offer case final offer?)
        KeyedSubtree(key: const ValueKey('transcript-tail'), child: offer)
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
      for (final entry in groupTurnWork(t.items, active: t.running || t.pending.isNotEmpty).reversed)
        if (entry is TurnWork)
          TurnWorkView(
            key: ValueKey(entry.key),
            work: entry,
            children: [for (final inner in groupSteps(entry.items)) _entryView(inner)],
          )
        // The task list shows above the composer while the agent works, not in the transcript too.
        else if (entry is! PlanItem)
          _entryView(entry),
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

  /// A row of the list or of a work box; every one is keyed (unkeyed rows
  /// handed their expanded state to whichever row of the same type slid into
  /// their index).
  Widget _entryView(Object entry) => switch (entry) {
    StepRun() => StepRunView(key: ValueKey(entry.key), run: entry),
    PlanItem() => const SizedBox.shrink(),
    final TranscriptItem item => KeyedSubtree(key: ValueKey(item.key), child: _itemView(item)),
    _ => const SizedBox.shrink(),
  };

  Widget _itemView(TranscriptItem item) => switch (item) {
    UserTurn(:final text, :final mode, :final lead, :final workflow) => Padding(
      padding: const EdgeInsets.only(top: 10),
      child: UserTurnView(
        text: text,
        mode: mode,
        workflow: workflow,
        lead: showLeads ? lead : '',
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
    NoticeItem(:final handedOffFrom) => NoticeView(
      item: item,
      onChange: handedOffFrom.isEmpty || onChangeHandoff == null ? null : () => onChangeHandoff!(handedOffFrom),
    ),
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
