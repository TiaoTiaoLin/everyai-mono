import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../app/router.dart';
import '../../../../core/theme/every_theme.dart';
import '../../../../core/ui/adaptive.dart';
import '../../../../core/ui/anchored_popover.dart';
import '../../../../core/ui/every_icons.dart';
import '../../../billing/billing_providers.dart' show formatMicros;
import '../../code_providers.dart';
import '../../code_settings_providers.dart' show codeSettingsProvider;
import '../../domain/code_session.dart';
import '../../host/host_notes.dart' show hostSavedPlans;
import '../../panes/panes_providers.dart';
import '../../settings/code_settings.dart' show crossedBudget;
import '../code_top_bar.dart' show SessionSettingsList;
import '../panes/session_panes.dart' show panesFor;
import 'console_state.dart';
import 'git_button.dart';
import 'session_actions.dart';

/// The views the header's icons switch for [info]: Session info always, the Diff in a git repository. Files joins
/// once its view is built.
List<ConsoleView> consoleViewsFor(CodeSessionInfo info) => [
  ConsoleView.info,
  if (info.diffTarget != null) ConsoleView.diff,
];

EveryIcon _iconOf(ConsoleView view) => switch (view) {
  ConsoleView.info => EveryIcon.info,
  ConsoleView.diff => EveryIcon.code,
  ConsoleView.files => EveryIcon.projects,
};

/// The session title with its ▾ menu: rename, pin, fork, export, archive and delete. Fork and archive come later.
class ConsoleTitle extends ConsumerWidget {
  const ConsoleTitle({super.key, required this.info});

  final CodeSessionInfo info;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    return AnchoredPopover(
      width: 240,
      builder: (popover, close) {
        void run(Future<void> Function() action) {
          close();
          unawaited(action());
        }

        return SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PopoverRow(
                key: const ValueKey('console.title.rename'),
                title: 'Rename',
                leading: AdaptiveIcon(EveryIcon.edit, size: 14, color: theme.textMuted),
                onTap: () => run(() => renameSession(context, ref, info)),
              ),
              PopoverRow(
                key: const ValueKey('console.title.pin'),
                title: info.pinned ? 'Unpin' : 'Pin',
                leading: AdaptiveIcon(EveryIcon.pin, size: 14, color: theme.textMuted),
                onTap: () {
                  close();
                  ref.read(codeSessionsProvider.notifier).setPinned(info.id, !info.pinned);
                },
              ),
              PopoverRow(
                key: const ValueKey('console.title.fork'),
                title: 'Fork',
                subtitle: 'Coming later',
                leading: AdaptiveIcon(EveryIcon.chevronUpDown, size: 14, color: theme.textMuted),
              ),
              PopoverRow(
                key: const ValueKey('console.title.export'),
                title: 'Export transcript…',
                leading: AdaptiveIcon(EveryIcon.download, size: 14, color: theme.textMuted),
                onTap: () => run(() => exportSession(context, ref, info)),
              ),
              PopoverRow(
                key: const ValueKey('console.title.archive'),
                title: 'Archive',
                subtitle: 'Coming later',
                leading: AdaptiveIcon(EveryIcon.artifacts, size: 14, color: theme.textMuted),
              ),
              PopoverRow(
                key: const ValueKey('console.title.delete'),
                title: 'Delete',
                destructive: true,
                leading: AdaptiveIcon(EveryIcon.delete, size: 14, color: theme.danger),
                onTap: () => run(() async {
                  // Taken now: a worktree session leaves the list before its worktree is gone, and this title with it.
                  final router = GoRouter.of(context);
                  if (await deleteSession(context, ref, info)) router.go(Routes.code);
                }),
              ),
            ],
          ),
        );
      },
      child: Semantics(
        button: true,
        label: '${info.title}, session menu',
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(child: Text(info.title, overflow: TextOverflow.ellipsis, maxLines: 1)),
            const SizedBox(width: 4),
            AdaptiveIcon(EveryIcon.chevronDown, size: 10, color: theme.textMuted),
          ],
        ),
      ),
    );
  }
}

/// The header's right side before the status: the view icons (folded into ⋯ when [ConsoleTier.narrow]), ⋯, then the
/// git button. Also tells the user when the session's spending cap stopped it.
class ConsoleActions extends ConsumerWidget {
  const ConsoleActions({super.key, required this.info, required this.tier});

  final CodeSessionInfo info;
  final ConsoleTier tier;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = info.id;
    // The session controller stops the run at the budget; this only says so.
    ref.listen(codeUsageProvider(id), (before, after) {
      final budget = ref.read(codeSettingsProvider).budgets[id];
      final was = before?.value?.chargedMicros ?? 0;
      final now = after.value?.chargedMicros ?? was;
      if (!crossedBudget(was, now, budget)) return;
      if (context.mounted) {
        showAdaptiveToast(context, 'Stopped: this session reached its ${formatMicros((budget! * 1e6).round())} budget');
      }
    });
    final active = ref.watch(consolePanelProvider(id).select((p) => p.view));
    final panel = ref.read(consolePanelProvider(id).notifier);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (tier != ConsoleTier.narrow)
          for (final view in consoleViewsFor(info))
            ViewIcon(
              key: ValueKey('console.icon.${view.name}'),
              icon: _iconOf(view),
              tooltip: active == view ? 'Close ${view.label}' : view.label,
              active: active == view,
              onPressed: () => panel.toggle(view),
            ),
        ConsoleMoreMenu(info: info, foldViews: tier == ConsoleTier.narrow),
        GitButton(sessionId: id),
      ],
    );
  }
}

/// An icon button that shows when its view is open.
class ViewIcon extends StatelessWidget {
  const ViewIcon({super.key, required this.icon, required this.tooltip, required this.active, required this.onPressed});

  final EveryIcon icon;
  final String tooltip;
  final bool active;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Semantics(
      selected: active,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: active ? theme.accent.withValues(alpha: 0.14) : null,
          borderRadius: BorderRadius.circular(8),
        ),
        child: AdaptiveIconButton(
          icon: icon,
          tooltip: tooltip,
          size: 16,
          color: active ? theme.accent : theme.textMuted,
          onPressed: onPressed,
        ),
      ),
    );
  }
}

/// The saved plans in `.everyai/plans/` from the host's listing ("- name.md: Title" lines), newest first.
List<({String file, String title})> parseSavedPlans(String listing) => [
  for (final line in listing.split('\n'))
    if (RegExp(r'^- ([^:]+\.md)(?:: (.*))?$').firstMatch(line.trim()) case final m?)
      (file: m.group(1)!, title: m.group(2) ?? m.group(1)!),
];

enum _MorePage { main, plans, settings }

/// The header's ⋯: Background tasks, Plans, Saved workflows and Session settings (each opening a page of the menu),
/// plus the view icons when the header is too narrow for them.
class ConsoleMoreMenu extends ConsumerStatefulWidget {
  const ConsoleMoreMenu({super.key, required this.info, required this.foldViews});

  final CodeSessionInfo info;
  final bool foldViews;

  @override
  ConsumerState<ConsoleMoreMenu> createState() => _ConsoleMoreMenuState();
}

class _ConsoleMoreMenuState extends ConsumerState<ConsoleMoreMenu> {
  var _page = _MorePage.main;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final info = widget.info;
    final panel = ref.read(consolePanelProvider(info.id).notifier);
    return AnchoredPopover(
      width: 300,
      builder: (popover, close) => StatefulBuilder(
        builder: (popover, setPage) {
          void page(_MorePage p) => setPage(() => _page = p);
          final back = PopoverRow(
            key: const ValueKey('console.more.back'),
            title: 'Back',
            leading: AdaptiveIcon(EveryIcon.chevronLeft, size: 14, color: theme.textMuted),
            onTap: () => page(_MorePage.main),
          );
          if (_page == _MorePage.settings) {
            return SessionSettingsList(projectId: info.projectId, sessionId: info.id, close: close, leading: back);
          }
          final active = ref.read(consolePanelProvider(info.id)).view;
          return SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_page == _MorePage.plans) ...[
                  back,
                  const PopoverHeader('Saved plans'),
                  ..._plans(close),
                ] else ...[
                  if (widget.foldViews)
                    for (final view in consoleViewsFor(info))
                      PopoverRow(
                        key: ValueKey('console.more.${view.name}'),
                        title: view.label,
                        leading: AdaptiveIcon(_iconOf(view), size: 14, color: theme.textMuted),
                        selected: active == view,
                        trailing: active == view ? AdaptiveIcon(EveryIcon.check, size: 14, color: theme.accent) : null,
                        onTap: () {
                          close();
                          panel.toggle(view);
                        },
                      ),
                  PopoverRow(
                    key: const ValueKey('console.more.tasks'),
                    title: 'Background tasks',
                    subtitle: 'Workflows, forks, subagents and commands',
                    onTap: () {
                      close();
                      panel.showRunningWork();
                    },
                  ),
                  PopoverRow(
                    key: const ValueKey('console.more.plans'),
                    title: 'Plans',
                    subtitle: '.everyai/plans',
                    onTap: () => page(_MorePage.plans),
                  ),
                  const PopoverRow(
                    key: ValueKey('console.more.workflows'),
                    title: 'Saved workflows',
                    subtitle: 'Coming later',
                  ),
                  PopoverRow(
                    key: const ValueKey('console.more.settings'),
                    title: 'Session settings',
                    subtitle: 'Permissions, MCP, skills, prompt',
                    onTap: () => page(_MorePage.settings),
                  ),
                  // Until the bottom drawer: the old side pane, for these three only.
                  if (panesFor(info).contains(CodePane.terminal))
                    PopoverRow(
                      key: const ValueKey('console.more.panes'),
                      title: 'Terminal, processes and preview',
                      onTap: () {
                        close();
                        ref.read(codePaneProvider(info.id).notifier).toggleLast();
                      },
                    ),
                ],
              ],
            ),
          );
        },
      ),
      child: Semantics(
        button: true,
        label: 'More',
        // Each opening starts on the main page (a Listener: it doesn't take the tap from the popover).
        child: Listener(
          onPointerDown: (_) => _page = _MorePage.main,
          child: Padding(
            key: const ValueKey('console.more'),
            padding: const EdgeInsets.all(8),
            child: AdaptiveIcon(EveryIcon.more, size: 16, color: theme.textMuted),
          ),
        ),
      ),
    );
  }

  List<Widget> _plans(VoidCallback close) {
    final root = widget.info.workingDir;
    final plans = noLocalFolder(root)
        ? const <({String file, String title})>[]
        : parseSavedPlans(hostSavedPlans(root, const {}).text);
    if (plans.isEmpty) return const [PopoverRow(title: 'No saved plans yet')];
    return [
      for (final p in plans)
        PopoverRow(
          title: p.title,
          subtitle: p.file,
          onTap: () {
            close();
            unawaited(launchUrl(Uri.file('$root/.everyai/plans/${p.file}')));
          },
        ),
    ];
  }
}
