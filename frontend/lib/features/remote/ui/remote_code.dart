import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/adaptive_page.dart';
import '../../../core/ui/every_icons.dart';
import '../../code/domain/agent_mode.dart';
import '../../code/domain/code_session.dart';
import '../../code/domain/phases.dart' show Phase;
import '../../code/domain/transcript.dart';
import '../../code/ui/code_composer.dart';
import '../../code/ui/phase_strip.dart';
import '../../code/ui/session_view.dart' show StartBuildingBar, StatusPill, TranscriptList;
import '../../code/ui/transcript/approval_card.dart';
import '../../code/ui/transcript/retry_row.dart';
import '../../code/ui/transcript/transcript_items.dart';
import '../../models/domain/model_catalog.dart';
import '../../models/models_providers.dart';
import '../data/relay_client.dart';
import '../host_mirror.dart' show mirroredFileKinds;
import '../remote_providers.dart';
import '../../settings/ui/settings_modal.dart';
import '../../settings/settings_registry.dart';

/// Code on a phone, tablet or browser: the paired computer's sessions. They
/// start on the computer; here they are followed and steered.
class RemoteCodeHome extends ConsumerWidget {
  const RemoteCodeHome({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final list = ref.watch(remoteSessionsProvider);
    final host = list.hostName.isEmpty ? 'your computer' : list.hostName;
    return AdaptivePage(
      title: list.paired ? list.hostName : 'Code',
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (list.paired)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                    child: Text(
                      'Sessions run on $host. Start new ones there; follow, answer and steer them here.',
                      style: theme.type.callout.tint(theme.textMuted),
                    ),
                  ),
                Expanded(child: RemoteSessionList(onNavigate: context.go)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The paired computer's sessions by project, for the sidebar and Code's page.
class RemoteSessionList extends ConsumerWidget {
  const RemoteSessionList({super.key, required this.onNavigate, this.location = '', this.dense = false});

  final ValueChanged<String> onNavigate;

  /// The current route, to mark the open session.
  final String location;
  final bool dense;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final list = ref.watch(remoteSessionsProvider);
    Widget message(String text, {Widget? action}) => Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(text, style: theme.type.callout.tint(theme.textMuted)),
          if (action != null) ...[const SizedBox(height: 12), action],
        ],
      ),
    );

    if (!list.paired) {
      return message(
        'Pair this device with a computer running EveryAI to follow its Code sessions here.',
        action: AdaptiveButton(
          label: 'Pair a computer',
          onPressed: () => showSettings(context, section: SettingsSection.remote),
        ),
      );
    }
    final linkNote = switch (list.link) {
      RemoteLinkStatus.ready => null,
      RemoteLinkStatus.hostOffline => '${list.hostName} is offline. Open EveryAI on it and turn on hosting.',
      RemoteLinkStatus.revoked => 'This device was unpaired. Pair it again in Settings → Remote.',
      RemoteLinkStatus.keyMismatch => "${list.hostName}'s keys changed. Pair this device again.",
      RemoteLinkStatus.connecting => 'Connecting to ${list.hostName}…',
    };
    if (!list.loaded) return message(linkNote ?? 'Loading sessions…');

    final active = location.startsWith('/code/s/') ? location.substring('/code/s/'.length) : null;
    // Subagents open from their parent's transcript.
    final roots = list.sessions.where((s) => !s.info.isSubagent).toList();
    final groups = [
      for (final p in list.projects) (p.name, roots.where((s) => s.info.projectId == p.id).toList()),
      ('Other', roots.where((s) => !list.projects.any((p) => p.id == s.info.projectId)).toList()),
    ].where((g) => g.$2.isNotEmpty);

    return ListView(
      padding: const EdgeInsets.only(bottom: 8),
      children: [
        if (linkNote != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: Text(linkNote, style: theme.type.caption.tint(theme.warning)),
          ),
        if (roots.isEmpty) message('No sessions on ${list.hostName} yet. Start one there and it shows up here.'),
        for (final (name, sessions) in groups) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Row(
              children: [
                AdaptiveIcon(EveryIcon.projects, size: 13, color: theme.textMuted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    name,
                    overflow: TextOverflow.ellipsis,
                    style: theme.type.caption.semibold.tint(theme.textMuted),
                  ),
                ),
              ],
            ),
          ),
          for (final s in sessions)
            _RemoteSessionTile(
              entry: s,
              dense: dense,
              selected: s.info.id == active,
              onOpen: () => onNavigate(Routes.codeSession(s.info.id)),
            ),
        ],
      ],
    );
  }
}

class _RemoteSessionTile extends StatelessWidget {
  const _RemoteSessionTile({required this.entry, required this.onOpen, this.selected = false, this.dense = false});

  final RemoteSessionEntry entry;
  final VoidCallback onOpen;
  final bool selected;
  final bool dense;

  static String _age(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'now';
    if (d.inHours < 1) return '${d.inMinutes}m';
    if (d.inDays < 1) return '${d.inHours}h';
    return '${d.inDays}d';
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onOpen,
      child: Semantics(
        button: true,
        selected: selected,
        label: '${entry.info.title}, ${entry.status.label}',
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
          padding: EdgeInsets.symmetric(horizontal: 10, vertical: dense ? 8 : 11),
          decoration: BoxDecoration(
            color: selected ? theme.text.withValues(alpha: 0.09) : null,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              StatusPill(status: entry.status, dense: true),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  entry.info.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.type.callout.tint(theme.text),
                ),
              ),
              if (!dense) Text(_age(entry.info.createdAt), style: theme.type.caption.tint(theme.textMuted)),
            ],
          ),
        ),
      ),
    );
  }
}

/// One of the computer's sessions, mirrored: the same transcript, cards and
/// composer as on the computer, with every action sent there to run.
class RemoteSessionScreen extends ConsumerWidget {
  const RemoteSessionScreen({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final list = ref.watch(remoteSessionsProvider);
    final entry = list.byId(sessionId);
    final info = entry?.info;
    final remote = ref.watch(remoteSessionProvider(sessionId));
    final controller = ref.read(remoteSessionProvider(sessionId).notifier);
    final state = remote.session;
    final t = state.transcript;
    final busy = t.running || t.pending.isNotEmpty;

    if (remote.gone case final gone?) {
      return AdaptivePage(
        title: info?.title ?? 'Code',
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(gone, textAlign: TextAlign.center, style: theme.type.body.tint(theme.textMuted)),
          ),
        ),
      );
    }

    /// Runs [action] on the computer; a refusal or a dropped link shows as a toast.
    void act(Future<void> Function() action) {
      action().catchError((Object e) {
        if (context.mounted) showAdaptiveToast(context, '$e');
      });
    }

    final showStartBuilding =
        state.mode == AgentMode.plan &&
        !busy &&
        t.openQuestion == null &&
        t.items.whereType<PlanProposal>().every((p) => p.shown) &&
        (t.items.lastOrNull is AgentText || t.items.lastOrNull is PlanProposal) &&
        t.items.whereType<UserTurn>().isNotEmpty;
    final linked = remote.link == RemoteLinkStatus.ready;
    final model = info == null ? null : ref.watch(modelCatalogProvider)[ModelId(info.model)];
    final host = list.hostName.isEmpty ? 'the computer' : list.hostName;

    return AdaptivePage(
      title: info?.title ?? 'Session',
      onBack: info?.parentId == null ? null : () => context.go(Routes.codeSession(info!.parentId!)),
      backTooltip: 'Back to the parent session',
      actions: [
        StatusPill(
          status: linked && remote.loaded ? state.status : entry?.status ?? SessionStatus.starting,
          dense: true,
        ),
      ],
      body: Column(
        children: [
          Expanded(
            child: TranscriptScope(
              root: info?.workingDir ?? '',
              child: !remote.loaded
                  ? Center(
                      child: linked
                          ? const AdaptiveProgress()
                          : Text('Connecting to $host…', style: theme.type.callout.tint(theme.textMuted)),
                    )
                  : TranscriptList(
                      onRewind: null,
                      transcript: t,
                      mode: state.mode,
                      onAnswer: (item, answers) => act(() => controller.answer(item, answers)),
                      onApprovePlan: () => act(controller.startBuilding),
                      onRevisePlan: (text) => act(() => controller.send(text)),
                      onRetry: () => act(controller.retry),
                    ),
            ),
          ),
          if (!linked && remote.loaded)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: NoticeView(
                item: NoticeItem(
                  'link',
                  remote.link == RemoteLinkStatus.hostOffline
                      ? '$host is offline. What you see is from before; it catches up when $host is back.'
                      : 'Reconnecting to $host…',
                ),
              ),
            )
          else if (state.error case final error?)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: NoticeView(item: NoticeItem('error', error, error: true)),
            )
          else if (t.retry case final retry?)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: RetryRow(
                retry: retry,
                onRetryNow: () => act(controller.retryNow),
                onStop: () => act(controller.stop),
              ),
            ),
          SafeArea(
            top: false,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 780),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
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
                            onAllow: (scope) => act(() => controller.approve(scope)),
                            onDeny: (reason) => act(() => controller.deny(reason)),
                            onMode: (mode) => act(() => controller.setMode(mode)),
                            remember: remote.remember,
                            decided: state.decided,
                            rememberBy: remote.rememberBy,
                            onAllowCall: remote.perCall
                                ? (id, scope) => act(() => controller.approve(scope, [id]))
                                : null,
                            onDenyCall: remote.perCall ? (id) => act(() => controller.deny(null, [id])) : null,
                            flags: remote.flags,
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
                          child: StartBuildingBar(onStart: () => act(controller.startBuilding)),
                        ),
                      CodeComposer(
                        busy: busy,
                        mode: state.mode,
                        autofocus: false,
                        attachKinds: mirroredFileKinds,
                        onModeChanged: (mode) => act(() => controller.setMode(mode)),
                        onSend: (text, files) => act(() => controller.send(text, files: files)),
                        onSteer: (text, files) => act(() => controller.steer(text, files: files)),
                        onStop: () => act(controller.stop),
                        queued: [for (final q in state.queued) q.text],
                        onUnqueue: (i) => act(() => controller.unqueue(i)),
                        placeholder: t.openQuestion != null
                            ? 'Answer the questions above, or reply in your own words'
                            : 'Reply to the agent on $host',
                        model: model,
                        trailing: model == null
                            ? null
                            : Text(
                                model.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.type.caption.tint(theme.textMuted),
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
