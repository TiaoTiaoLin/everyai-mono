import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/every_theme.dart';
import '../../../../core/ui/adaptive.dart';
import '../../../../core/ui/every_icons.dart';
import '../../../artifacts/ui/panel_split.dart';
import '../../code_providers.dart';
import '../../domain/code_session.dart';
import '../panes/diff_pane.dart';
import 'console_header.dart' show consoleViewsFor;
import 'console_state.dart';
import 'files_view.dart';
import 'running_work.dart';
import 'session_info_view.dart';

/// The session screen's body with its right panel: beside [child] when [tier] is wide (a divider resizes it), over
/// it on the right otherwise, with the rest of the transcript dimmed (a tap there closes it). An overlaid panel
/// steps aside when the session puts something in front of the user (a draft card, an approval, a question), since
/// those land under it.
class ConsoleLayout extends ConsumerStatefulWidget {
  const ConsoleLayout({super.key, required this.session, required this.tier, required this.child});

  final CodeSessionInfo session;
  final ConsoleTier tier;
  final Widget child;

  @override
  ConsumerState<ConsoleLayout> createState() => _ConsoleLayoutState();
}

class _ConsoleLayoutState extends ConsumerState<ConsoleLayout> {
  /// Keeps [ConsoleLayout.child] (the composer's draft, the transcript's scroll) when the panel opens, closes or
  /// moves between beside and over: the element moves instead of being built again.
  final _childKey = GlobalKey();

  /// Built once per session snapshot, so a drag of the divider doesn't rebuild the panel's contents.
  ConsolePanelView? _panel;

  @override
  void didUpdateWidget(ConsoleLayout old) {
    super.didUpdateWidget(old);
    if (old.session != widget.session) _panel = null;
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.session.id;
    final notifier = ref.read(consolePanelProvider(id).notifier);
    ref.listen(codeSessionProvider(id).select((s) => (s.asides.length, s.status == SessionStatus.needsInput)), (
      before,
      after,
    ) {
      final grew = after.$1 > (before?.$1 ?? 0) || (after.$2 && !(before?.$2 ?? false));
      if (grew && widget.tier != ConsoleTier.wide && ref.read(consolePanelProvider(id)).open) notifier.close();
    });
    final open = ref.watch(consolePanelProvider(id).select((p) => p.open));
    final width = ref.watch(consolePanelProvider(id).select((p) => p.width));
    final child = KeyedSubtree(key: _childKey, child: widget.child);
    if (!open) return child;
    final panel = _panel ??= ConsolePanelView(session: widget.session);
    return LayoutBuilder(
      builder: (context, box) {
        if (widget.tier == ConsoleTier.wide) {
          return PanelSplit(
            key: const ValueKey('console.split'),
            maxWidth: box.maxWidth,
            width: width,
            onWidth: notifier.setWidth,
            panel: panel,
            child: child,
          );
        }
        final theme = EveryTheme.of(context);
        return Stack(
          key: const ValueKey('console.overlay'),
          children: [
            child,
            Positioned.fill(
              child: GestureDetector(
                key: const ValueKey('console.scrim'),
                behavior: HitTestBehavior.opaque,
                onTap: notifier.close,
                child: ColoredBox(color: theme.text.withValues(alpha: 0.06)),
              ),
            ),
            Positioned(
              top: 0,
              bottom: 0,
              right: 0,
              width: PanelSplit.widthFor(width, box.maxWidth).clamp(0, box.maxWidth - 40).toDouble(),
              child: panel,
            ),
          ],
        );
      },
    );
  }
}

/// The panel itself: a child session's chat when one is open, else the chosen view.
class ConsolePanelView extends ConsumerWidget {
  const ConsolePanelView({super.key, required this.session});

  final CodeSessionInfo session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    // Not the width: a drag of the divider shouldn't rebuild the Diff or Session info.
    final (shown, childId) = ref.watch(consolePanelProvider(session.id).select((p) => (p.view, p.child)));
    final notifier = ref.read(consolePanelProvider(session.id).notifier);
    // A view this session has no content for (a Diff outside git, Files without a folder) shows Session info.
    final views = consoleViewsFor(session);
    final view = shown != null && views.contains(shown) ? shown : ConsoleView.info;
    final Widget body;
    if (childId case final child?) {
      body = ChildChatView(key: ValueKey('console.child.$child'), parentId: session.id, childId: child);
    } else if (view == ConsoleView.diff) {
      // The Diff draws its own header, with Close.
      return DiffPane(session: session, onClose: notifier.close);
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 6, 2),
            child: Row(
              children: [
                Expanded(child: Text(view.label, style: theme.type.headline.tint(theme.text))),
                AdaptiveIconButton(icon: EveryIcon.close, tooltip: 'Close', size: 16, onPressed: notifier.close),
              ],
            ),
          ),
          Expanded(
            child: switch (view) {
              ConsoleView.files => FilesView(session: session),
              _ => SessionInfoView(session: session),
            },
          ),
        ],
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.surface,
        border: Border(left: BorderSide(color: theme.border)),
      ),
      child: body,
    );
  }
}
