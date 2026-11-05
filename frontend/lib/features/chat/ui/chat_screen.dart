import '../../../core/ui/brand.dart';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/net/api_error.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/adaptive_page.dart';
import '../../../core/ui/every_icons.dart';
import '../../../core/ui/selection.dart';
import '../../artifacts/artifact_providers.dart';
import '../../artifacts/domain/artifact.dart';
import '../../artifacts/ui/artifact_panel.dart';
import '../../artifacts/ui/panel_split.dart';
import '../../slash/chat_actions.dart';
import '../../usage/ui/usage_meter.dart';
import '../chat_providers.dart';
import '../domain/ask_user.dart';
import '../domain/message.dart';
import '../domain/chat_session.dart';
import '../domain/starters.dart';
import 'composer.dart';
import 'message_view.dart';
import '../../settings/ui/settings_modal.dart';
import '../../settings/settings_registry.dart';

/// Readable line length for the transcript and composer on wide windows.
const _maxContentWidth = 820.0;

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.conversationId});

  final String conversationId;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  // Keeps the composer (draft, focus) alive as it moves from the centered home
  // layout to the bottom of the transcript after the first message.
  final _composer = GlobalKey<ComposerState>();

  @override
  Widget build(BuildContext context) {
    final provider = chatSessionProvider(widget.conversationId);
    final controller = ref.read(provider.notifier);
    final model = ref.watch(provider.select((s) => s.model));
    final mode = ref.watch(provider.select((s) => s.mode));
    final phase = ref.watch(provider.select((s) => s.phase));
    final title = ref.watch(provider.select((s) => s.title));
    final isEmpty = ref.watch(provider.select((s) => s.isEmpty));
    final usage = ref.watch(provider.select((s) => s.usage));
    final asking = ref.watch(provider.select((s) => s.pendingTools.any((t) => t.name == askUserTool)));
    final home = isEmpty && phase is! Loading;

    // Like Claude: a new or revised artifact (or a deck) opens the side panel.
    ref.listen(provider.select((s) => s.liveParts), (previous, next) {
      if (next.length <= (previous?.length ?? 0)) return;
      if (next.last case final ToolCallPart call
          when artifactTools.contains(call.toolName) || call.toolName == 'make_slides') {
        final visual = Visual.fromPart(call);
        if (visual == null) return;
        final panel = ref.read(artifactPanelProvider(widget.conversationId).notifier);
        if (call.toolName == 'make_slides') {
          panel.openVisual(visual);
        } else {
          panel.openArtifact(visual.str('id').isEmpty ? visual.callId : visual.str('id'));
        }
      }
    });

    final composer = Composer(
      key: _composer,
      busy: phase.busy,
      replying: asking,
      model: model,
      mode: mode,
      minLines: home ? 2 : 1,
      placeholder: home
          ? 'How can I help you today?'
          : asking
          ? 'Answer the questions above, or type your own reply…'
          : 'Reply to ${model.name}…',
      onSend: (text, attachments) => controller.send(text, attachments: attachments),
      onStop: controller.cancel,
      onModelChanged: controller.selectModel,
      onModeChanged: controller.setMode,
      toolsEnabled: ref.watch(provider.select((s) => s.toolsEnabled)),
      onToolsChanged: controller.setToolsEnabled,
      effort: ref.watch(provider.select((s) => s.effort)),
      onEffortChanged: controller.setEffort,
      researchDepth: ref.watch(provider.select((s) => s.researchDepth)),
      onResearchDepthChanged: controller.setResearchDepth,
      slash: chatSlashHost(
        context,
        ref,
        widget.conversationId,
        openModelPicker: () => _composer.currentState?.openModelPicker(),
      ),
      meter: UsageMeter(totals: usage, contextWindow: model.contextLength, modelName: model.name),
    );

    return AdaptivePage(
      title: home ? '' : (title ?? 'New chat'),
      actions: [
        if (!home) ...[
          _ChatMenu(conversationId: widget.conversationId),
          AdaptiveIconButton(icon: EveryIcon.newChat, tooltip: 'New chat', onPressed: () => context.go(Routes.newChat)),
        ],
      ],
      // The transcript's list pads itself by the bar's height and slides under it; the home starts below the bar.
      scrollsUnderBar: !home,
      body: _WithPanel(
        conversationId: widget.conversationId,
        child: switch (phase) {
          Loading() => const Center(child: AdaptiveProgress()),
          _ when home => _Home(
            composer: composer,
            onStarter: (starter) {
              controller.setMode(starter.mode);
              _composer.currentState?.prefill(starter.prompt);
            },
          ),
          _ => Column(
            children: [
              Expanded(child: _Transcript(conversationId: widget.conversationId)),
              if (phase case Failed(:final error))
                _ErrorBanner(
                  message: error.message,
                  retryable: error.retryable,
                  onRetry: controller.retry,
                  action: switch (error) {
                    HttpStatusError(outOfCredits: true) => (
                      label: 'Top up',
                      onPressed: () => showSettings(context, section: SettingsSection.billing, anchor: 'wallet'),
                    ),
                    // A self-run server without its own key: the user's key is what runs the model.
                    HttpStatusError(code: 'no_api_key') => (
                      label: 'Add API key',
                      onPressed: () => showSettings(context, section: SettingsSection.apiKeys),
                    ),
                    _ => null,
                  },
                ),
              SafeArea(
                top: false,
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: _maxContentWidth),
                    child: Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 14), child: composer),
                  ),
                ),
              ),
            ],
          ),
        },
      ),
    );
  }
}

/// New-chat landing: greeting, a large centered composer and starter prompts.
class _Home extends StatelessWidget {
  const _Home({required this.composer, required this.onStarter});

  final Widget composer;
  final ValueChanged<Starter> onStarter;

  static String _greeting(DateTime now) => switch (now.hour) {
    < 5 => 'Up late?',
    < 12 => 'Good morning',
    < 17 => 'Good afternoon',
    _ => 'Good evening',
  };

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 48),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const BrandMark(size: 26),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(_greeting(DateTime.now()), style: theme.type.largeTitle.regular.tint(theme.text)),
                  ),
                ],
              ),
              const SizedBox(height: 28),
              composer,
              const SizedBox(height: 16),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final starter in chatStarters)
                    _StarterChip(icon: starter.icon, label: starter.label, onTap: () => onStarter(starter)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StarterChip extends StatefulWidget {
  const _StarterChip({required this.icon, required this.label, required this.onTap});

  final EveryIcon icon;
  final String label;
  final VoidCallback onTap;

  @override
  State<_StarterChip> createState() => _StarterChipState();
}

class _StarterChipState extends State<_StarterChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Semantics(
      button: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: _hover ? theme.surfaceRaised : null,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: theme.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AdaptiveIcon(widget.icon, size: 14, color: theme.textMuted),
                const SizedBox(width: 6),
                Text(widget.label, style: theme.type.callout.tint(theme.text)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Transcript extends ConsumerWidget {
  const _Transcript({required this.conversationId});

  final String conversationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Only rebuilds when a message is added or finishes, not per streamed token.
    final messages = ref.watch(chatSessionProvider(conversationId).select((s) => s.messages));
    return AdaptiveSelectionArea(
      child: ListView.builder(
        reverse: true,
        padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top + 16, bottom: 16),
        itemCount: messages.length,
        // Newest first with reverse:true keeps the latest turn pinned to the bottom.
        itemBuilder: (context, i) {
          final message = messages[messages.length - 1 - i];
          return Center(
            key: ValueKey(message.id),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _maxContentWidth),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                child: MessageView(message: message, conversationId: conversationId, isLatest: i == 0),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.retryable, required this.onRetry, this.action});

  final String message;
  final bool retryable;
  final VoidCallback onRetry;

  /// What fixes it: Top up (out of credits), Add API key (no key to run on).
  final ({String label, VoidCallback onPressed})? action;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _maxContentWidth),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Semantics(
            liveRegion: true,
            child: Container(
              padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
              decoration: BoxDecoration(
                color: theme.danger.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(theme.radius),
                border: Border.all(color: theme.danger.withValues(alpha: 0.35)),
              ),
              child: Row(
                children: [
                  Expanded(child: Text(message, style: theme.type.callout.tint(theme.text))),
                  if (action case final a?)
                    AdaptiveButton(label: a.label, emphasis: ButtonEmphasis.primary, onPressed: a.onPressed),
                  if (retryable)
                    AdaptiveButton(
                      label: 'Retry',
                      emphasis: ButtonEmphasis.plain,
                      icon: AdaptiveIcon(EveryIcon.retry, size: 16, color: theme.accent),
                      onPressed: onRetry,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The chat with the artifact side panel: beside it on wide windows, over it
/// on narrow ones.
class _WithPanel extends ConsumerWidget {
  const _WithPanel({required this.conversationId, required this.child});

  final String conversationId;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.watch(artifactPanelProvider(conversationId).select((t) => t != null));
    if (!open) return child;
    return LayoutBuilder(
      builder: (context, constraints) {
        final fullScreen = constraints.maxWidth < 720;
        final panel = BelowBar(
          child: ArtifactPanel(conversationId: conversationId, fullScreen: fullScreen),
        );
        if (fullScreen) {
          return Stack(
            children: [
              child,
              Positioned.fill(child: panel),
            ],
          );
        }
        return PanelSplit(maxWidth: constraints.maxWidth, panel: panel, child: child);
      },
    );
  }
}

/// The open chat's "…" menu: star, rename, delete.
class _ChatMenu extends ConsumerWidget {
  const _ChatMenu({required this.conversationId});
  final String conversationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final c = ref.watch(
      conversationsProvider.select((all) => all.value?.where((c) => c.id == conversationId).firstOrNull),
    );
    if (c == null) return const SizedBox.shrink();
    final repo = ref.read(chatRepositoryProvider);
    return AdaptiveMenuButton(
      tooltip: 'Chat options',
      actions: [
        MenuAction(
          label: c.pinned ? 'Unstar' : 'Star',
          icon: EveryIcon.pin,
          onSelected: () => repo.setPinned(c.id, pinned: !c.pinned),
        ),
        MenuAction(
          label: 'Rename',
          icon: EveryIcon.edit,
          onSelected: () async {
            final title = await showAdaptivePrompt(
              context,
              title: 'Rename chat',
              initialValue: c.title,
              confirmLabel: 'Rename',
            );
            if (title != null && title.trim().isNotEmpty) await repo.rename(c.id, title.trim());
          },
        ),
        MenuAction(
          label: 'Export as Markdown',
          icon: EveryIcon.download,
          onSelected: () => exportChat(context, ref, c.id, 'md'),
        ),
        MenuAction(
          label: 'Export as PDF',
          icon: EveryIcon.download,
          onSelected: () => exportChat(context, ref, c.id, 'pdf'),
        ),
        MenuAction(
          label: 'Save as skill',
          icon: EveryIcon.spark,
          onSelected: () => saveChatAsSkill(context, ref, c.id, ''),
        ),
        MenuAction(
          label: 'Delete',
          icon: EveryIcon.delete,
          destructive: true,
          onSelected: () async {
            final ok = await showAdaptiveConfirm(
              context,
              title: 'Delete chat?',
              message: '"${c.title}" will be permanently deleted from this device.',
              confirmLabel: 'Delete',
              destructive: true,
            );
            if (!ok) return;
            await repo.delete(c.id);
            if (context.mounted) context.go(Routes.newChat);
          },
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: AdaptiveIcon(EveryIcon.more, size: 18, color: theme.text.withValues(alpha: 0.85)),
      ),
    );
  }
}
