import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../../../core/theme/every_theme.dart';
import '../../../../core/ui/adaptive.dart';
import '../../../../core/ui/every_icons.dart';
import '../../domain/code_session.dart';
import '../../panes/panes_providers.dart';
import '../console/bottom_drawer.dart' show isDrawerToggle;

/// The terminal's own key filter, which runs before the shell gets a key: ⌃` toggles the drawer ([toggle]) instead.
/// It is handled here: a key the filter lets through goes to the shell, never up to the drawer's shortcut.
KeyEventResult terminalKeys(KeyEvent event, VoidCallback toggle) {
  if (!isDrawerToggle(event)) return KeyEventResult.ignored;
  if (event is KeyDownEvent) toggle();
  return KeyEventResult.handled;
}

/// A shell in the session's folder (its worktree), kept running while the
/// app is open; right click copies the selection or pastes.
class TerminalPane extends ConsumerStatefulWidget {
  const TerminalPane({super.key, required this.session});

  final CodeSessionInfo session;

  @override
  ConsumerState<TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends ConsumerState<TerminalPane> {
  final _controller = TerminalController();

  SessionTerminal get _shell => ref.read(sessionTerminalProvider(widget.session.id).notifier);

  @override
  void initState() {
    super.initState();
    // After the first layout, so the shell starts at the view's size.
    WidgetsBinding.instance.endOfFrame.then((_) {
      if (mounted) _shell.start(widget.session.workingDir);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _copyOrPaste() async {
    final terminal = _shell.terminal;
    if (_controller.selection case final selection?) {
      await Clipboard.setData(ClipboardData(text: terminal.buffer.getText(selection)));
      _controller.clearSelection();
    } else if ((await Clipboard.getData(Clipboard.kTextPlain))?.text case final text?) {
      terminal.paste(text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final status = ref.watch(sessionTerminalProvider(widget.session.id));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 6, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  status.exitCode != null ? 'Exited (${status.exitCode})' : widget.session.workingDir,
                  overflow: TextOverflow.ellipsis,
                  style: theme.type.caption.tint(theme.textMuted),
                ),
              ),
              AdaptiveIconButton(
                icon: EveryIcon.retry,
                tooltip: 'Restart shell',
                size: 16,
                onPressed: () => _shell.restart(widget.session.workingDir),
              ),
            ],
          ),
        ),
        Expanded(
          child: ColoredBox(
            color: TerminalThemes.defaultTheme.background,
            child: TerminalView(
              _shell.terminal,
              controller: _controller,
              autofocus: true,
              padding: const EdgeInsets.all(8),
              textStyle: TerminalStyle(
                fontFamily: 'SourceCodePro',
                fontSize: EveryTheme.of(context).type.callout.fontSize!,
              ),
              onSecondaryTapDown: (_, _) => _copyOrPaste(),
              onKeyEvent: (_, event) =>
                  terminalKeys(event, ref.read(codePaneProvider(widget.session.id).notifier).toggleDrawer),
            ),
          ),
        ),
      ],
    );
  }
}
