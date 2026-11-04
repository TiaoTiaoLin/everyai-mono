import 'package:file_selector/file_selector.dart' show XFile;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/platform/platform_kind.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/anchored_popover.dart';
import '../../../core/ui/every_icons.dart';
import '../../attachments/attachment.dart';
import '../../attachments/attachment_input.dart';
import '../../attachments/ui/attachment_tray.dart';
import '../../models/domain/model_catalog.dart';
import '../../slash/native_commands.dart';
import '../../slash/slash_command.dart';
import '../../slash/slash_registry.dart';
import '../../slash/ui/slash_menu.dart';
import '../domain/agent_mode.dart';
import '../harness/harness.dart' show NativeCommand;
import '../uploads/uploads.dart';

/// The Code composer. Enter sends (or queues while the agent works),
/// Option-Enter interrupts and sends now, Esc stops. `/` at the start opens the
/// command menu.
class CodeComposer extends ConsumerStatefulWidget {
  const CodeComposer({
    super.key,
    required this.busy,
    required this.mode,
    required this.onModeChanged,
    required this.onSend,
    this.onSteer,
    this.onStop,
    this.queued = const [],
    this.onUnqueue,
    this.placeholder = 'Ask for a change, or reply to the agent',
    this.leading,
    this.trailing,
    this.meter,
    this.minLines = 1,
    this.autofocus = true,
    this.model,
    this.slashHost,
    this.project,
    this.attachKinds,
    this.commands,
    this.onUnlistedCommand,
  });

  final bool busy;
  final AgentMode mode;
  final ValueChanged<AgentMode> onModeChanged;
  final void Function(String text, List<Attachment> files) onSend;
  final void Function(String text, List<Attachment> files)? onSteer;
  final VoidCallback? onStop;
  final List<String> queued;
  final ValueChanged<int>? onUnqueue;
  final String placeholder;

  /// Extra controls in the bottom row (project and model pickers).
  final Widget? leading;
  final Widget? trailing;

  /// Tokens, cost and context ring, before send.
  final Widget? meter;
  final int minLines;
  final bool autofocus;

  /// The session's model: whether attached images reach it.
  final ModelSpec? model;

  /// What `/` commands can drive in an open session; null: only the mode and Stop.
  final CodeSlashHost? slashHost;

  /// The project folder: its own `/` commands show here.
  final String? project;

  /// The kinds of file that can be attached; null for any. A session mirrored
  /// from another computer takes pictures and text only, and photos are
  /// scaled down before they travel.
  final Set<AttachmentKind>? attachKinds;

  /// An outside harness's own `/` commands, which replace EveryAI's in the
  /// menu; the app actions they push out ([CodeSlashHost]'s rewind, commit,
  /// PR, cost and brief) move to the [SessionActionsButton]. Null: EveryAI's
  /// menu (the EveryAI harness).
  final List<SlashCommand>? commands;

  /// A typed `/name args` that isn't in an empty [commands] list (the harness
  /// hasn't listed them yet): it still goes to the harness as a command, not
  /// as a message with EveryAI's notes in front.
  final Future<String?> Function(String name, String args)? onUnlistedCommand;

  @override
  ConsumerState<CodeComposer> createState() => _CodeComposerState();
}

class _CodeComposerState extends ConsumerState<CodeComposer> {
  final _controller = TextEditingController();
  late final _focus = FocusNode(onKeyEvent: _onKey);
  final _files = <Attachment>[];
  final _slash = SlashMenuController(surface: SlashScope.code);

  @override
  void initState() {
    super.initState();
    _slash.project = widget.project;
    _controller.addListener(() {
      _slash.update(_controller.value, _commands);
      setState(() {});
    });
  }

  List<SlashCommand> get _commands => widget.commands ?? ref.read(slashCommandsProvider);

  @override
  void didUpdateWidget(CodeComposer old) {
    super.didUpdateWidget(old);
    _slash.project = widget.project;
    // The harness listed its commands again while the menu may be open.
    if (!identical(old.commands, widget.commands)) _slash.update(_controller.value, _commands);
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    _slash.dispose();
    super.dispose();
  }

  SlashContext get _slashContext => SlashContext(
    context: context,
    surface: SlashScope.code,
    setDraft: (text) => _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    ),
    send: (text) => widget.onSend(text, const []),
    code:
        widget.slashHost ??
        CodeSlashHost(
          setMode: (name) => widget.onModeChanged(AgentMode.values.byName(name)),
          stop: widget.busy ? widget.onStop : null,
        ),
  );

  void _pickSlash(SlashCommand command) {
    runSlash(command, '', _slashContext);
    _focus.requestFocus();
  }

  /// `/name` then optional arguments; a path such as `/usr/bin is slow` isn't one.
  static final _commandLine = RegExp(r'^/([A-Za-z][\w:.-]*)(?:\s+([\s\S]*))?$');

  bool get _hasText => _controller.text.trim().isNotEmpty || _files.isNotEmpty;

  void _submit({bool steer = false}) {
    if (!_hasText) return;
    final text = _controller.text;
    if (_files.isEmpty) {
      if (parseSlashLine(text, _commands, SlashScope.code, project: widget.project) case final line?) {
        runSlash(line.command, line.args, _slashContext, complete: false);
        _focus.requestFocus();
        return;
      }
      final unlisted = widget.onUnlistedCommand;
      if (unlisted != null && widget.commands?.isEmpty == true) {
        if (_commandLine.firstMatch(text.trim()) case final m?) {
          final command = nativeSlashCommands([NativeCommand(name: m[1]!)], unlisted).single;
          runSlash(command, m[2]?.trim() ?? '', _slashContext, complete: false);
          _focus.requestFocus();
          return;
        }
      }
    }
    (steer && widget.busy && widget.onSteer != null ? widget.onSteer! : widget.onSend)(text, List.unmodifiable(_files));
    _controller.clear();
    setState(_files.clear);
    _focus.requestFocus();
  }

  /// Any file can go to the agent: it is saved into the project.
  Future<void> _add(List<XFile> picked) async {
    final kinds = widget.attachKinds;
    final read = await readAttachments(
      picked,
      alreadyBytes: _files.fold(0, (sum, a) => sum + a.size),
      shrinkImages: kinds != null,
      onError: (message) {
        if (mounted) showAdaptiveToast(context, message);
      },
    );
    final added = [
      for (final a in read)
        if (kinds == null || kinds.contains(a.kind)) a,
    ];
    if (added.length < read.length && mounted) {
      showAdaptiveToast(context, 'Only pictures and text files can be sent here.');
    }
    if (!mounted || added.isEmpty) return;
    setState(() => _files.addAll(added));
    _focus.requestFocus();
  }

  String get _filesNote {
    final m = widget.model;
    final images = _files.any((f) => f.kind == AttachmentKind.image);
    final blind = images && m != null && !m.accepts(AttachmentKind.image);
    return 'Saved to the project in $uploadsDir${blind ? ". ${m.name} can't see images; the agent can still open the files." : ''}';
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (_slash.handleKey(event, _pickSlash) case final handled?) return handled;
    if (event is! KeyDownEvent || Host.isMobile) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final keyboard = HardwareKeyboard.instance;
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      if (keyboard.isShiftPressed) return KeyEventResult.ignored;
      final composing = _controller.value.composing;
      if (composing.isValid && !composing.isCollapsed) return KeyEventResult.ignored;
      _submit(steer: keyboard.isAltPressed);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape && widget.busy && widget.onStop != null) {
      widget.onStop!();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final radius = theme.design == DesignLanguage.fluent ? 8.0 : EveryTheme.cardRadius;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SlashMenu(controller: _slash, onPick: _pickSlash),
        if (widget.queued.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final (i, q) in widget.queued.indexed)
                  _QueuedChip(text: q, onRemove: widget.onUnqueue == null ? null : () => widget.onUnqueue!(i)),
              ],
            ),
          ),
        AttachmentDropZone(
          onFiles: _add,
          child: GlassSurface(
            radius: radius,
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AttachmentTray(
                  attachments: _files,
                  note: _filesNote,
                  onRemove: (a) => setState(() => _files.remove(a)),
                ),
                Semantics(
                  label: 'Message the agent',
                  textField: true,
                  child: AdaptiveTextField(
                    controller: _controller,
                    focusNode: _focus,
                    placeholder: widget.busy
                        ? 'Queue a message · ${Host.enterKeys(option: true)} sends now'
                        : widget.placeholder,
                    minLines: widget.minLines,
                    maxLines: 10,
                    borderless: true,
                    keyboardType: TextInputType.multiline,
                    autofocus: widget.autofocus && !Host.isMobile,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    AdaptiveIconButton(
                      icon: EveryIcon.attach,
                      tooltip: 'Attach files',
                      color: theme.textMuted,
                      onPressed: () async => _add(await pickAttachmentFiles(allowed: widget.attachKinds)),
                    ),
                    ModeMenu(mode: widget.mode, onChanged: widget.onModeChanged),
                    if (widget.slashHost case final host? when widget.commands != null)
                      SessionActionsButton(host: host),
                    // Both sides shrink on narrow composers (project first, it is
                    // capped); the model sits at the right, next to send.
                    if (widget.leading != null) ...[
                      const SizedBox(width: 4),
                      Flexible(
                        flex: 2,
                        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 240), child: widget.leading),
                      ),
                    ],
                    Expanded(
                      flex: 3,
                      child: Align(alignment: Alignment.centerRight, child: widget.trailing ?? const SizedBox()),
                    ),
                    ?widget.meter,
                    const SizedBox(width: 6),
                    if (widget.busy && widget.onStop != null && !_hasText)
                      AdaptiveIconButton(icon: EveryIcon.stop, tooltip: 'Stop (Esc)', onPressed: widget.onStop)
                    else
                      AdaptiveIconButton(
                        icon: EveryIcon.send,
                        tooltip: widget.busy ? 'Queue' : 'Send',
                        color: _hasText ? theme.accent : theme.textMuted,
                        onPressed: _hasText ? _submit : null,
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// The app's session actions as a menu, for sessions whose `/` menu is the
/// harness's own: each row calls what its `/` command calls in an EveryAI
/// session. Model, Stop and the meter have controls of their own already.
class SessionActionsButton extends StatelessWidget {
  const SessionActionsButton({super.key, required this.host});

  final CodeSlashHost host;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return AdaptiveMenuButton(
      tooltip: 'Session actions',
      width: 220,
      actions: [
        if (host.rewind case final f?)
          MenuAction(label: 'Rewind last turn', icon: EveryIcon.retry, onSelected: () => f('')),
        if (host.commit case final f?) MenuAction(label: 'Commit…', icon: EveryIcon.check, onSelected: () => f('')),
        if (host.pr case final f?)
          MenuAction(label: 'Pull request…', icon: EveryIcon.external, onSelected: () => f('')),
        if (host.cost case final f?) MenuAction(label: 'Cost', icon: EveryIcon.usage, onSelected: f),
        if (host.morning case final f?) MenuAction(label: 'Morning brief', icon: EveryIcon.sun, onSelected: f),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        child: AdaptiveIcon(EveryIcon.more, size: 16, color: theme.textMuted),
      ),
    );
  }
}

/// Ask · Auto-edit · Plan · Full auto.
class ModeMenu extends StatelessWidget {
  const ModeMenu({super.key, required this.mode, required this.onChanged});

  final AgentMode mode;
  final ValueChanged<AgentMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final color = switch (mode) {
      AgentMode.fullAuto => theme.danger,
      AgentMode.plan => theme.accent,
      _ => theme.textMuted,
    };
    return AnchoredPopover(
      width: 280,
      builder: (context, close) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const PopoverHeader('Permissions'),
            for (final m in AgentMode.values)
              PopoverRow(
                title: m.label,
                subtitle: m.description,
                selected: m == mode,
                trailing: m == mode ? AdaptiveIcon(EveryIcon.check, size: 14, color: theme.accent) : null,
                onTap: () {
                  close();
                  onChanged(m);
                },
              ),
          ],
        ),
      ),
      child: Semantics(
        button: true,
        label: 'Mode: ${mode.label}',
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            border: Border.all(color: color.withValues(alpha: 0.4)),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(mode.label, style: theme.type.callout.medium.tint(color)),
              const SizedBox(width: 4),
              AdaptiveIcon(EveryIcon.chevronDown, size: 11, color: color),
            ],
          ),
        ),
      ),
    );
  }
}

class _QueuedChip extends StatelessWidget {
  const _QueuedChip({required this.text, required this.onRemove});
  final String text;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Container(
      constraints: const BoxConstraints(maxWidth: 320),
      padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
      decoration: BoxDecoration(
        color: theme.surfaceRaised,
        border: Border.all(color: theme.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Queued · ', style: theme.type.caption.tint(theme.textMuted)),
          Flexible(
            child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.type.caption.tint(theme.text)),
          ),
          if (onRemove != null)
            AdaptiveIconButton(icon: EveryIcon.close, tooltip: 'Remove', size: 12, onPressed: onRemove),
        ],
      ),
    );
  }
}
