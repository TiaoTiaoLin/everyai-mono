import 'package:flutter/services.dart';
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
import '../panes/preview_pane.dart';
import '../panes/processes_pane.dart';
import '../panes/terminal_pane.dart';

/// The drawer's tabs for [session]: Terminal, Processes and Preview for a real folder on a desktop with a shell;
/// none elsewhere (no drawer).
List<CodePane> drawerPanesFor(CodeSessionInfo session) =>
    Host.isDesktop && shellSupported && !isDemoPath(session.workingDir) ? CodePane.values : const [];

/// ⌃` opens and closes the drawer on every platform (as in VS Code and Claude's console).
const drawerToggleKey = SingleActivator(LogicalKeyboardKey.backquote, control: true);

/// Whether [event] is [drawerToggleKey]: the terminal lets it through instead of sending it to the shell.
bool isDrawerToggle(KeyEvent event) =>
    event is! KeyUpEvent &&
    event.logicalKey == LogicalKeyboardKey.backquote &&
    HardwareKeyboard.instance.isControlPressed &&
    !HardwareKeyboard.instance.isMetaPressed &&
    !HardwareKeyboard.instance.isAltPressed;

/// [child] (the transcript and composer) with the session's drawer under it, when it has one. ⌃` anywhere inside
/// [child] or the drawer toggles it.
class BottomDrawer extends ConsumerStatefulWidget {
  const BottomDrawer({super.key, required this.session, required this.child, this.paneBuilder});

  final CodeSessionInfo session;
  final Widget child;

  /// Builds a tab's body in place of the real pane (tests: no shell, poller or webview).
  @visibleForTesting
  final Widget Function(CodePane pane)? paneBuilder;

  static const defaultHeight = 260.0;
  static const minHeight = 120.0;

  @override
  ConsumerState<BottomDrawer> createState() => _BottomDrawerState();
}

class _BottomDrawerState extends ConsumerState<BottomDrawer> {
  /// Tabs shown at least once stay built while the drawer is open, so the Preview keeps its page.
  final _built = <CodePane>{};

  /// The height while a drag is under way (written when it ends).
  double? _dragging;

  /// Holds the keyboard after a click on the drawer's tabs (which take no focus of their own), so ⌃` still reaches
  /// the shortcut.
  final _focus = FocusNode(debugLabel: 'drawer', skipTraversal: true);

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final panes = drawerPanesFor(widget.session);
    if (panes.isEmpty) return widget.child;
    final id = widget.session.id;
    final state = ref.watch(codePaneProvider(id));
    final notifier = ref.read(codePaneProvider(id).notifier);
    final open = state.open;
    // Closing with the keyboard inside the drawer (a terminal): the keyboard stays on the screen, so ⌃` opens it
    // again. Before the pane goes, or focus would fall out of reach of the shortcut.
    ref.listen(codePaneProvider(id).select((s) => s.open), (was, now) {
      if (was != null && now == null && _focus.hasFocus) _focus.requestFocus();
    });
    return CallbackShortcuts(
      bindings: {drawerToggleKey: notifier.toggleDrawer},
      child: Focus(
        focusNode: _focus,
        child: LayoutBuilder(
          builder: (context, box) {
            final max = (box.maxHeight * 0.7).clamp(BottomDrawer.minHeight, double.infinity).toDouble();
            double clamp(double h) => h.clamp(BottomDrawer.minHeight, max).toDouble();
            final height = clamp(_dragging ?? state.height ?? BottomDrawer.defaultHeight);
            if (open == null) {
              _built.clear();
            } else {
              _built.add(open);
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Always first, so the transcript and the composer's draft keep their state when the drawer toggles.
                Expanded(child: widget.child),
                if (open != null) ...[
                  _Handle(
                    onDrag: (dy) => setState(() => _dragging = clamp(height - dy)),
                    onEnd: () {
                      if (_dragging case final h?) notifier.setHeight(h);
                      setState(() => _dragging = null);
                    },
                  ),
                  SizedBox(
                    key: const ValueKey('drawer'),
                    height: height,
                    child: _Frame(
                      onTab: _focus.requestFocus,
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
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _body(CodePane p, {required bool active}) =>
      widget.paneBuilder?.call(p) ??
      switch (p) {
        CodePane.terminal => TerminalPane(session: widget.session),
        // Polls only while showing.
        CodePane.processes => active ? ProcessesPane(session: widget.session) : const SizedBox.shrink(),
        CodePane.preview => PreviewPane(session: widget.session),
      };
}

/// The drawer's top edge: drag it to resize.
class _Handle extends StatelessWidget {
  const _Handle({required this.onDrag, required this.onEnd});

  final ValueChanged<double> onDrag;
  final VoidCallback onEnd;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.resizeRow,
      child: GestureDetector(
        key: const ValueKey('drawer.handle'),
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: (d) => onDrag(d.delta.dy),
        onVerticalDragEnd: (_) => onEnd(),
        onVerticalDragCancel: onEnd,
        child: SizedBox(
          height: 7,
          child: Center(child: Container(height: 1, color: theme.border)),
        ),
      ),
    );
  }
}

class _Frame extends ConsumerWidget {
  const _Frame({
    required this.session,
    required this.panes,
    required this.open,
    required this.onTab,
    required this.child,
  });

  /// A tab was clicked.
  final VoidCallback onTab;

  final CodeSessionInfo session;
  final List<CodePane> panes;
  final CodePane open;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final notifier = ref.read(codePaneProvider(session.id).notifier);
    return ColoredBox(
      color: theme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 2, 6, 0),
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final p in panes)
                          _Tab(
                            key: ValueKey('drawer.tab.${p.name}'),
                            label: p.label,
                            selected: p == open,
                            onTap: () {
                              onTab();
                              notifier.show(p);
                            },
                          ),
                      ],
                    ),
                  ),
                ),
                AdaptiveIconButton(icon: EveryIcon.close, tooltip: 'Close (⌃`)', size: 16, onPressed: notifier.close),
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
  const _Tab({super.key, required this.label, required this.selected, required this.onTap});

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
