import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart' as c;
import 'package:everyai_markdown/everyai_markdown.dart' show CodeHighlighter, languageForPath;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../../core/theme/every_theme.dart';
import '../../../../core/ui/adaptive.dart';
import '../../../../core/ui/every_icons.dart';
import '../../../../core/ui/syntax_spans.dart' show syntaxThemeFor;
import '../../code_providers.dart';
import '../../domain/code_session.dart';
import '../../git/git_service.dart';
import '../../panes/file_tree.dart' as fs;

/// The file open in a session's Files view: what is in the editor ([text]), what was on disk when it was read
/// ([opened], null for a file that couldn't be shown, with [note] saying why), and the folders expanded in the tree.
/// Kept per session, so switching the panel to another view or leaving the session loses no edit.
@immutable
final class FilesBuffer {
  const FilesBuffer({
    this.path,
    this.text = '',
    this.opened,
    this.note,
    this.conflict = false,
    this.expanded = const {},
  });

  final String? path;
  final String text;
  final String? opened;
  final String? note;

  /// The last save found the file changed on disk.
  final bool conflict;
  final Set<String> expanded;

  bool get dirty => opened != null && text != opened;

  FilesBuffer copyWith({String? text, String? opened, bool? conflict, Set<String>? expanded}) => FilesBuffer(
    path: path,
    text: text ?? this.text,
    opened: opened ?? this.opened,
    note: note,
    conflict: conflict ?? this.conflict,
    expanded: expanded ?? this.expanded,
  );
}

final filesEditorProvider = NotifierProvider.family<FilesEditor, FilesBuffer, String>(FilesEditor.new);

base class FilesEditor extends Notifier<FilesBuffer> {
  FilesEditor(this.sessionId);
  final String sessionId;

  @override
  FilesBuffer build() {
    // Files changed under the editor (the agent, a rewind, a reverted hunk): an untouched file shows them.
    ref.listen(codeGitProvider(sessionId), (_, _) => unawaited(sync()));
    // A deleted session keeps no buffer.
    ref.listen(codeSessionsProvider, (_, _) {
      if (ref.read(codeSessionsProvider.notifier).byId(sessionId) == null) state = const FilesBuffer();
    });
    return const FilesBuffer();
  }

  String? get _root => ref.read(codeSessionsProvider.notifier).byId(sessionId)?.workingDir;

  /// Opens [path] in the editor (the caller asked about unsaved edits first).
  Future<void> open(String path) async {
    final root = _root;
    if (root == null) return;
    final file = await fs.openForEdit(path, root: root);
    if (!ref.mounted) return;
    state = FilesBuffer(
      path: path,
      text: file.text ?? '',
      opened: file.text,
      note: file.note,
      expanded: state.expanded,
    );
  }

  void close() => state = FilesBuffer(expanded: state.expanded);

  void edit(String text) => state = state.copyWith(text: text);

  /// Reads the file again, dropping the edits.
  Future<void> reload() async {
    if (state.path case final path?) await open(path);
  }

  /// Compares the open file with the disk: an untouched one shows what is there now, an edited one is marked as a
  /// conflict (saving asks first).
  Future<void> sync() async {
    final b = state;
    final path = b.path;
    if (path == null || b.opened == null) return;
    final disk = await fs.readText(path);
    if (!ref.mounted || state.path != path || state.opened != b.opened || disk == b.opened) return;
    if (state.dirty) {
      state = state.copyWith(conflict: true);
    } else if (disk == null) {
      await open(path);
    } else {
      state = FilesBuffer(path: path, text: disk, opened: disk, expanded: state.expanded);
    }
  }

  void toggleFolder(String dir) => state = state.copyWith(
    expanded: state.expanded.contains(dir) ? ({...state.expanded}..remove(dir)) : {...state.expanded, dir},
  );

  /// Saves through the session ([CodeSessionController.saveFile]); returns why it didn't, or null.
  Future<String?> save({bool overwrite = false}) async {
    final b = state;
    if (b.path == null || b.opened == null) return null;
    final out = await ref
        .read(codeSessionProvider(sessionId).notifier)
        .saveFile(b.path!, b.text, expected: b.opened, overwrite: overwrite);
    if (!ref.mounted) return null;
    // Another file was opened meanwhile: the outcome isn't its.
    if (state.path != b.path) return out.reason;
    switch (out.kind) {
      case SaveKind.saved:
        // Typed on during the save: those edits stay unsaved.
        state = state.copyWith(opened: b.text, conflict: false);
        return null;
      case SaveKind.changedOnDisk:
        state = state.copyWith(conflict: true);
        return null;
      case SaveKind.refused:
        return out.reason;
    }
  }
}

/// One folder of the Files tree, listed when it is opened, with the children git ignores (absolute paths).
typedef FilesFolder = ({fs.FolderListing listing, Set<String> ignored});

final filesFolderProvider = FutureProvider.autoDispose.family<FilesFolder, String>((ref, dir) async {
  final listing = await fs.listFolder(dir);
  final ignored = await GitService.ignoredAmong(dir, [for (final e in listing.entries) e.dir ? '${e.name}/' : e.name]);
  return (
    listing: listing,
    ignored: {
      for (final e in listing.entries)
        if (ignored.contains(e.name) || ignored.contains('${e.name}/')) e.path,
    },
  );
});

/// The session folder as a tree (changed files marked, ignored ones dimmed, folders listed when opened) over the
/// file open in a light editor: ⌘S / Ctrl+S saves, refused while the agent works.
class FilesView extends ConsumerWidget {
  const FilesView({super.key, required this.session});

  final CodeSessionInfo session;

  String get _root => session.workingDir;

  String _rel(String path) => p.isWithin(_root, path) ? p.relative(path, from: _root) : path;

  Future<void> _open(BuildContext context, WidgetRef ref, String path) async {
    // Read before the dialog: the view may be gone when it closes (the narrow panel closes on an approval).
    final editor = ref.read(filesEditorProvider(session.id).notifier);
    final b = ref.read(filesEditorProvider(session.id));
    if (b.path == path) return;
    if (b.dirty && b.path != null) {
      final ok = await showAdaptiveConfirm(
        context,
        title: 'Discard changes to ${_rel(b.path!)}?',
        message: "Your edits haven't been saved.",
        confirmLabel: 'Discard',
        destructive: true,
      );
      if (!ok) return;
    }
    await editor.open(path);
  }

  /// Changed files by absolute path; diff paths are relative to the repository's top, which is the session folder
  /// for a worktree and maybe above it in place.
  Map<String, ChangeKind> _changes(GitSnapshot? git) {
    final top = session.worktree?.path ?? session.baseline?.repoRoot;
    if (git == null || top == null) return const {};
    return {for (final f in git.files) p.normalize(p.join(top, f.path)): f.kind};
  }

  /// What the tree's listings depend on in the diff: the files added, removed or renamed (not those only edited).
  static String _shape(GitSnapshot? git) => [
    for (final f in git?.files ?? const <FileDiff>[])
      if (f.kind != ChangeKind.modified) '${f.kind.letter} ${f.path}',
  ].join('\n');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = EveryTheme.of(context);
    final id = session.id;
    final editor = ref.read(filesEditorProvider(id).notifier);
    final expanded = ref.watch(filesEditorProvider(id).select((b) => b.expanded));
    final open = ref.watch(filesEditorProvider(id).select((b) => b.path));
    // Files were added or removed: list this session's open folders again.
    ref.listen(codeGitProvider(id).select((s) => _shape(s.value)), (_, _) {
      for (final dir in {_root, ...expanded}) {
        ref.invalidate(filesFolderProvider(dir));
      }
    });
    final changes = _changes(ref.watch(codeGitProvider(id)).value);
    final changedDirs = <String>{
      for (final path in changes.keys)
        for (var d = p.dirname(path); d != p.dirname(d); d = p.dirname(d)) d,
    };
    final rows = <Widget>[];
    void walk(String dir, int depth, {required bool dimmed}) {
      final folder = ref.watch(filesFolderProvider(dir)).value;
      if (folder == null) return;
      for (final e in folder.listing.entries) {
        final ignored = dimmed || folder.ignored.contains(e.path);
        final isOpen = e.dir && expanded.contains(e.path);
        rows.add(
          _TreeRow(
            key: ValueKey('files.row.${_rel(e.path)}'),
            entry: e,
            depth: depth,
            open: isOpen,
            selected: e.path == open,
            dimmed: ignored,
            change: changes[e.path],
            holdsChange: e.dir && changedDirs.contains(e.path),
            onTap: () => e.dir ? editor.toggleFolder(e.path) : unawaited(_open(context, ref, e.path)),
          ),
        );
        if (isOpen) walk(e.path, depth + 1, dimmed: ignored);
      }
      if (folder.listing.more > 0) {
        rows.add(
          Padding(
            padding: EdgeInsets.fromLTRB(28 + depth * 14.0, 3, 8, 3),
            child: Text('${folder.listing.more} more not shown', style: theme.type.caption.tint(theme.textMuted)),
          ),
        );
      }
    }

    walk(_root, 0, dimmed: false);
    final tree = ListView(padding: const EdgeInsets.symmetric(vertical: 4), children: rows);
    if (open == null) return tree;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(flex: 2, child: tree),
        Container(height: 1, color: theme.border),
        Expanded(
          flex: 3,
          child: _FileEditor(key: ValueKey('files.editor.$open'), session: session),
        ),
      ],
    );
  }
}

class _TreeRow extends StatelessWidget {
  const _TreeRow({
    super.key,
    required this.entry,
    required this.depth,
    required this.open,
    required this.selected,
    required this.dimmed,
    required this.change,
    required this.holdsChange,
    required this.onTap,
  });

  final fs.TreeEntry entry;
  final int depth;
  final bool open;
  final bool selected;
  final bool dimmed;
  final ChangeKind? change;
  final bool holdsChange;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final color = switch (change) {
      ChangeKind.added => theme.success,
      ChangeKind.deleted => theme.danger,
      null => dimmed ? theme.textMuted.withValues(alpha: 0.6) : theme.text,
      _ => theme.warning,
    };
    return Semantics(
      button: true,
      selected: selected,
      label: entry.name,
      child: GestureDetector(
        onTap: onTap,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Container(
            color: selected ? theme.accent.withValues(alpha: 0.12) : null,
            padding: EdgeInsets.fromLTRB(10 + depth * 14.0, 3, 10, 3),
            child: Row(
              children: [
                SizedBox(
                  width: 18,
                  child: entry.dir
                      ? AdaptiveIcon(
                          open ? EveryIcon.chevronDown : EveryIcon.chevronRight,
                          size: 10,
                          color: theme.textMuted,
                        )
                      : null,
                ),
                Expanded(
                  child: Text(
                    entry.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.type.callout.tint(color),
                  ),
                ),
                if (change case final kind?)
                  Text(
                    kind.letter,
                    key: ValueKey('files.mark.${entry.name}'),
                    style: theme.type.caption.mono.tint(color),
                  )
                else if (holdsChange)
                  Container(
                    key: ValueKey('files.dot.${entry.name}'),
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(color: theme.warning, shape: BoxShape.circle),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The open file: its header (path, unsaved dot, Save, Mention in composer, Open in editor, Close) and the editor.
class _FileEditor extends ConsumerStatefulWidget {
  const _FileEditor({super.key, required this.session});

  final CodeSessionInfo session;

  @override
  ConsumerState<_FileEditor> createState() => _FileEditorState();
}

class _FileEditorState extends ConsumerState<_FileEditor> {
  late final _controller = FilesCodeController(
    text: ref.read(filesEditorProvider(widget.session.id)).text,
    language: languageForPath(ref.read(filesEditorProvider(widget.session.id)).path ?? ''),
  );

  FilesEditor get _editor => ref.read(filesEditorProvider(widget.session.id).notifier);

  @override
  void initState() {
    super.initState();
    // What changed while the view wasn't showing.
    unawaited(_editor.sync());
    _controller.addListener(() {
      if (_controller.text != ref.read(filesEditorProvider(widget.session.id)).text) _editor.edit(_controller.text);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save({bool overwrite = false}) async {
    final why = await _editor.save(overwrite: overwrite);
    if (why != null && mounted) showAdaptiveToast(context, why);
  }

  Future<void> _close() async {
    final b = ref.read(filesEditorProvider(widget.session.id));
    if (b.dirty &&
        !await showAdaptiveConfirm(
          context,
          title: 'Discard changes to ${b.path!.split('/').last}?',
          message: "Your edits haven't been saved.",
          confirmLabel: 'Discard',
          destructive: true,
        )) {
      return;
    }
    if (mounted) _editor.close();
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final id = widget.session.id;
    final b = ref.watch(filesEditorProvider(id));
    final path = b.path!;
    // The text changed under the editor (a reload): show it.
    ref.listen(filesEditorProvider(id).select((b) => b.text), (_, text) {
      if (text != _controller.text) _controller.text = text;
    });
    final busy = ref.watch(codeSessionProvider(id).select((s) => s.filesLocked));
    // A turn ended: an untouched file shows what the agent left.
    ref.listen(codeSessionProvider(id).select((s) => s.transcript.running), (was, now) {
      if (was == true && !now) unawaited(_editor.sync());
    });
    final root = widget.session.workingDir;
    // With forward slashes on every platform, as the agent writes paths.
    final rel = p.isWithin(root, path) ? p.split(p.relative(path, from: root)).join('/') : path;
    final style = theme.type.caption.mono.copyWith(color: theme.text, height: 1.45);
    _controller
      ..base = style
      ..brightness = theme.brightness;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(rel, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.type.callout.medium),
              ),
              if (b.dirty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Semantics(
                    label: 'Unsaved changes',
                    child: Container(
                      key: const ValueKey('files.dirty'),
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(color: theme.accent, shape: BoxShape.circle),
                    ),
                  ),
                ),
              if (b.opened != null)
                AdaptiveIconButton(
                  key: const ValueKey('files.save'),
                  icon: EveryIcon.check,
                  tooltip: 'Save',
                  size: 15,
                  onPressed: b.dirty && !busy ? _save : null,
                ),
              AdaptiveIconButton(
                key: const ValueKey('files.mention'),
                icon: EveryIcon.mention,
                tooltip: 'Mention in composer',
                size: 15,
                onPressed: () => ref.read(composerInsertProvider(id).notifier).insert('@$rel '),
              ),
              // As text in the system's editor, never run; not for a file this view couldn't show either.
              if (b.opened != null)
                AdaptiveIconButton(
                  key: const ValueKey('files.external'),
                  icon: EveryIcon.external,
                  tooltip: 'Open in text editor',
                  size: 15,
                  onPressed: () async {
                    final why = await fs.openAsText(path);
                    if (why != null && context.mounted) showAdaptiveToast(context, why);
                  },
                ),
              AdaptiveIconButton(
                key: const ValueKey('files.close'),
                icon: EveryIcon.close,
                tooltip: 'Close file',
                size: 15,
                onPressed: _close,
              ),
            ],
          ),
        ),
        if (b.conflict)
          _Banner(
            key: const ValueKey('files.conflict'),
            text: 'This file changed on disk since you opened it.',
            actions: [
              AdaptiveButton(label: 'Reload', emphasis: ButtonEmphasis.secondary, onPressed: _editor.reload),
              AdaptiveButton(label: 'Overwrite', onPressed: () => _save(overwrite: true)),
            ],
          )
        else if (busy && b.opened != null)
          const _Banner(text: CodeSessionController.agentWorking),
        Expanded(
          child: b.opened == null
              ? Center(child: Text(b.note ?? '', style: theme.type.callout.tint(theme.textMuted)))
              : CallbackShortcuts(
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.keyS, meta: true): _save,
                    const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
                  },
                  child: c.CupertinoTextField.borderless(
                    key: const ValueKey('files.text'),
                    controller: _controller,
                    readOnly: busy,
                    expands: true,
                    maxLines: null,
                    keyboardType: TextInputType.multiline,
                    style: style,
                    cursorColor: theme.accent,
                    padding: const EdgeInsets.fromLTRB(12, 6, 12, 24),
                  ),
                ),
        ),
      ],
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({super.key, required this.text, this.actions = const []});

  final String text;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Container(
      color: theme.warning.withValues(alpha: 0.12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Expanded(child: Text(text, style: theme.type.caption.tint(theme.text))),
          for (final a in actions) Padding(padding: const EdgeInsets.only(left: 6), child: a),
        ],
      ),
    );
  }
}

/// Colours the text as it is typed: straight through the highlighter (not `codeSpan`'s cache, which would fill with
/// every keystroke's text), remembering only the last result. Plain above [maxChars] characters or with a line over
/// [maxLine] (minified code): the highlighter runs on the UI thread on every keystroke and slows down sharply on long
/// lines.
@visibleForTesting
class FilesCodeController extends TextEditingController {
  FilesCodeController({super.text, required this.language});

  final String? language;
  TextStyle base = const TextStyle();
  Brightness brightness = Brightness.light;

  static const maxChars = 40000;
  static const maxLine = 2000;

  static bool _tooBig(String text) {
    if (text.length > maxChars) return true;
    var start = 0;
    while (start < text.length) {
      final end = text.indexOf('\n', start);
      if ((end < 0 ? text.length : end) - start > maxLine) return true;
      if (end < 0) break;
      start = end + 1;
    }
    return false;
  }

  (String, TextStyle, Brightness, TextSpan)? _last;

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final lang = language;
    final composing = withComposing && value.isComposingRangeValid;
    if (_last case (final t, final b, final br, final span)
        when !composing && t == text && b == base && br == brightness) {
      return span;
    }
    if (lang == null || composing || _tooBig(text)) {
      return super.buildTextSpan(context: context, style: style, withComposing: withComposing);
    }
    final span = CodeHighlighter.highlight(text, lang, base: base, theme: syntaxThemeFor(brightness));
    _last = (text, base, brightness, span);
    return span;
  }
}
