import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/platform/platform_kind.dart';
import '../../../../core/theme/every_theme.dart';
import '../../../../core/ui/adaptive.dart';
import '../../../../core/ui/every_icons.dart';
import '../../code_providers.dart' show isDemoPath;
import '../../domain/code_session.dart';
import '../../panes/panes_providers.dart';
import '../../panes/pty.dart';
import '../console/console_layout.dart';
import '../console/console_state.dart';
import 'preview_pane.dart';
import 'processes_pane.dart';
import 'terminal_pane.dart';

/// The panes [session] can show: Terminal, Processes and Preview for a real
/// folder on a desktop. The Diff and the old Tasks pane live in the console's
/// right panel now (`ui/console/`); these three move to its bottom drawer next.
List<CodePane> panesFor(CodeSessionInfo session) => [
  if (Host.isDesktop && shellSupported && !isDemoPath(session.workingDir)) ...[
    CodePane.terminal,
    CodePane.processes,
    CodePane.preview,
  ],
];

/// The session's body: the console's right panel ([ConsoleLayout]) around
/// the open pane beside the session (over it when narrow), with tabs.
class SessionPanes extends ConsumerStatefulWidget {
  const SessionPanes({super.key, required this.session, required this.child});

  final CodeSessionInfo session;
  final Widget child;

  @override
  ConsumerState<SessionPanes> createState() => _SessionPanesState();
}

class _SessionPanesState extends ConsumerState<SessionPanes> {
  /// Tabs shown at least once stay built, so the webview keeps its page.
  final _built = <CodePane>{};

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) =>
        ConsoleLayout(session: widget.session, tier: ConsoleTier.forWidth(box.maxWidth), child: _panes(context)),
  );

  Widget _panes(BuildContext context) {
    final open = ref.watch(codePaneProvider(widget.session.id)).open;
    final panes = panesFor(widget.session);
    if (open == null || !panes.contains(open)) return widget.child;
    _built.add(open);
    final pane = _PaneFrame(
      session: widget.session,
      panes: panes,
      open: open,
      child: IndexedStack(
        index: panes.indexOf(open),
        sizing: StackFit.expand,
        children: [
          for (final p in panes)
            if (!_built.contains(p)) const SizedBox.shrink() else _body(p, active: p == open),
        ],
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 900) {
          return Stack(
            children: [
              widget.child,
              Positioned.fill(child: pane),
            ],
          );
        }
        final width = (constraints.maxWidth * 0.48).clamp(380.0, 760.0);
        return Row(
          children: [
            Expanded(child: widget.child),
            SizedBox(width: width, child: pane),
          ],
        );
      },
    );
  }

  Widget _body(CodePane p, {required bool active}) {
    return switch (p) {
      CodePane.diff || CodePane.tasks => const SizedBox.shrink(),
      CodePane.terminal => TerminalPane(session: widget.session),
      // Polls only while showing.
      CodePane.processes => active ? ProcessesPane(session: widget.session) : const SizedBox.shrink(),
      CodePane.preview => PreviewPane(session: widget.session),
    };
  }
}

class _PaneFrame extends ConsumerWidget {
  const _PaneFrame({required this.session, required this.panes, required this.open, required this.child});

  final CodeSessionInfo session;
  final List<CodePane> panes;
  final CodePane open;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final panesNotifier = ref.read(codePaneProvider(session.id).notifier);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.surface,
        border: Border(left: BorderSide(color: theme.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 6, 0),
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final p in panes)
                          _Tab(label: p.label, selected: p == open, onTap: () => panesNotifier.show(p)),
                      ],
                    ),
                  ),
                ),
                AdaptiveIconButton(icon: EveryIcon.close, tooltip: 'Close', size: 16, onPressed: panesNotifier.close),
              ],
            ),
          ),
          Container(height: 1, color: theme.border),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          margin: const EdgeInsets.only(right: 2),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? theme.accent.withValues(alpha: 0.12) : null,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Text(
            label,
            style: theme.type.callout.copyWith(
              color: selected ? theme.accent : theme.textMuted,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}
