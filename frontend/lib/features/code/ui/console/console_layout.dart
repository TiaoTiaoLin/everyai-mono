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

/// The session screen's body with its right panel: beside [child] whenever both fit ([besideFrom]; a divider resizes
/// it), over it on the right only in a window too narrow for that, with the rest of the transcript dimmed (a tap
/// there closes it). An overlaid panel steps aside when the session puts something in front of the user (a draft
/// card, an approval, a question), since those land under it.
class ConsoleLayout extends ConsumerStatefulWidget {
  const ConsoleLayout({super.key, required this.session, required this.tier, required this.child});

  final CodeSessionInfo session;
  final ConsoleTier tier;
  final Widget child;

  @override
  ConsumerState<ConsoleLayout> createState() => _ConsoleLayoutState();
}

/// From this width the panel sits beside the transcript, each at least [PanelSplit.minSide] wide. Below the header's
/// wide tier too: a Linux or Windows window is often under 1000 logical pixels, and an overlay there closed on every
/// card and couldn't be resized.
const besideFrom = PanelSplit.minSide * 2;

class _ConsoleLayoutState extends ConsumerState<ConsoleLayout> {
  /// Whether the panel was last laid out beside the transcript (an overlay is the one that steps aside).
  bool _beside = true;

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
      if (grew && !_beside && ref.read(consolePanelProvider(id)).open) notifier.close();
    });
    final open = ref.watch(consolePanelProvider(id).select((p) => p.open));
    final width = ref.watch(consolePanelProvider(id).select((p) => p.width));
    final child = KeyedSubtree(key: _childKey, child: widget.child);
    if (!open) return child;
    final panel = _panel ??= ConsolePanelView(session: widget.session);
    return LayoutBuilder(
      builder: (context, box) {
        _beside = widget.tier == ConsoleTier.wide || box.maxWidth >= besideFrom;
        if (_beside) {
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
      return _belowBar(context, DiffPane(session: session, onClose: notifier.close));
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
      child: _belowBar(context, body),
    );
  }

  /// [panel] starts below a translucent top bar (the page hands its height down as padding, which only scroll views
  /// take): the panel's headers (a fork's Back and title, the view's Close) used to sit under the bar.
  static Widget _belowBar(BuildContext context, Widget panel) {
    final top = MediaQuery.paddingOf(context).top;
    if (top == 0) return panel;
    return Padding(
      padding: EdgeInsets.only(top: top),
      child: MediaQuery.removePadding(context: context, removeTop: true, child: panel),
    );
  }
}
