import 'package:everyai_markdown/everyai_markdown.dart' show languageForPath;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/theme/every_theme.dart';
import '../../../../core/ui/adaptive.dart';
import '../../../../core/ui/every_icons.dart';
import '../../../../core/ui/syntax_spans.dart';
import '../../code_providers.dart';
import '../../domain/code_session.dart';
import '../../git/git_service.dart';
import '../../panes/panes_providers.dart';
import '../console/console_state.dart';
import '../console/git_button.dart' show mergeLocally;

final _mono = EveryType.resolve().caption.mono.copyWith(height: 1.45);

/// The session's changes since it branched: files, hunks (each revertable)
/// and what to do with the work: commit, squash merge, push, PR, discard.
class DiffPane extends ConsumerStatefulWidget {
  const DiffPane({super.key, required this.session, required this.onClose});

  final CodeSessionInfo session;
  final VoidCallback onClose;

  @override
  ConsumerState<DiffPane> createState() => _DiffPaneState();
}

class _DiffPaneState extends ConsumerState<DiffPane> {
  final _collapsed = <String>{};
  final _fileKeys = <String, GlobalKey>{};
  int _focusedSeq = 0;
  bool _busy = false;

  /// Scrolls to the file the transcript asked for (an edit row's link), once
  /// per request. Transcript paths are absolute; the diff's are repo-relative.
  void _scrollToFocus(GitSnapshot snapshot) {
    final pane = ref.read(consolePanelProvider(widget.session.id));
    final focus = pane.focus;
    if (focus == null || pane.focusSeq == _focusedSeq) return;
    final file = snapshot.files.where((f) => focus == f.path || focus.endsWith('/${f.path}')).firstOrNull;
    if (file == null) return;
    _focusedSeq = pane.focusSeq;
    _collapsed.remove(file.path);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _fileKeys[file.path]?.currentContext;
      if (target != null) Scrollable.ensureVisible(target, duration: const Duration(milliseconds: 200));
    });
  }

  CodeGit get _git => ref.read(codeGitProvider(widget.session.id).notifier);

  /// Runs [action], showing what failed instead of throwing.
  Future<void> _run(Future<String?> Function() action) async {
    setState(() => _busy = true);
    try {
      final done = await action();
      if (done != null && mounted) showAdaptiveToast(context, done);
    } on GitError catch (e) {
      if (mounted) showAdaptiveToast(context, e.message);
    } on Object catch (e) {
      if (mounted) showAdaptiveToast(context, '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _commit() async {
    final message = await showAdaptivePrompt(
      context,
      title: 'Commit message',
      confirmLabel: 'Commit',
      initialValue: widget.session.title,
    );
    if (message == null || message.trim().isEmpty) return;
    await _run(() async => await _git.commit(message.trim()) ? 'Committed' : 'Nothing to commit');
  }

  Future<void> _merge() async {
    setState(() => _busy = true);
    try {
      await mergeLocally(context, ref, widget.session);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _push(SessionWorktree w) => _run(() async {
    await _git.push();
    return 'Pushed ${w.branch}';
  });

  Future<void> _pr() async {
    final title = await showAdaptivePrompt(
      context,
      title: 'Pull request title',
      confirmLabel: 'Create',
      initialValue: widget.session.title,
    );
    if (title == null || title.trim().isEmpty) return;
    await _run(() async => 'Opened ${await _git.createPr(title: title.trim(), body: '')}');
  }

  Future<void> _discard() async {
    final ok = await showAdaptiveConfirm(
      context,
      title: 'Discard this session?',
      message: 'Deletes its worktree, branch and checkpoints. Work that was merged stays merged.',
      confirmLabel: 'Discard',
      destructive: true,
    );
    if (!ok) return;
    await _run(() async {
      await _git.discard();
      return null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final w = widget.session.worktree;
    final baseline = widget.session.baseline;
    final snapshot = ref.watch(codeGitProvider(widget.session.id));
    final git = snapshot.value;
    ref.watch(consolePanelProvider(widget.session.id).select((p) => p.focusSeq));
    if (git != null) _scrollToFocus(git);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.surface,
        border: Border(left: BorderSide(color: theme.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 6, 6),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Changes', style: theme.type.headline.tint(theme.text)),
                      if (w != null)
                        Text(
                          '${w.branch} → ${w.baseBranch}'
                          '${git == null || git.ahead == 0 ? '' : ' · ${git.ahead} commit${git.ahead == 1 ? '' : 's'}'}'
                          '${git == null || git.behind == 0 ? '' : ' · ${w.baseBranch} moved ${git.behind} ahead'}',
                          overflow: TextOverflow.ellipsis,
                          style: theme.type.caption.tint(theme.textMuted),
                        )
                      else if (baseline != null)
                        Text(
                          'In place${baseline.branch.isEmpty ? '' : ' on ${baseline.branch}'} · since the session started',
                          overflow: TextOverflow.ellipsis,
                          style: theme.type.caption.tint(theme.textMuted),
                        ),
                    ],
                  ),
                ),
                AdaptiveIconButton(icon: EveryIcon.retry, tooltip: 'Refresh', size: 16, onPressed: _git.refresh),
                AdaptiveIconButton(icon: EveryIcon.close, tooltip: 'Close', size: 16, onPressed: widget.onClose),
              ],
            ),
          ),
          Expanded(
            child: switch ((widget.session.diffTarget, snapshot)) {
              (null, _) => _Empty(
                'This folder isn\'t a git repository, so the agent works in it directly and there is no diff to show.',
              ),
              (_, AsyncError(:final error)) => _Empty('$error'),
              (_, AsyncData(value: GitSnapshot(files: []))) => const _Empty(
                'No changes yet. Edits the agent makes in this session show up here.',
              ),
              (_, AsyncData(value: final g)) => ListView(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                children: [
                  for (final f in g.files)
                    _FileView(
                      key: _fileKeys.putIfAbsent(f.path, GlobalKey.new),
                      file: f,
                      collapsed: _collapsed.contains(f.path),
                      onToggle: () => setState(
                        () => _collapsed.contains(f.path) ? _collapsed.remove(f.path) : _collapsed.add(f.path),
                      ),
                      onRevert: _busy ? null : (i) => _run(() async => _git.revertHunk(f, i).then((_) => null)),
                    ),
                ],
              ),
              _ => const Center(child: AdaptiveProgress()),
            },
          ),
          if (w != null)
            Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: theme.border)),
              ),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.end,
                children: [
                  AdaptiveMenuButton(
                    tooltip: 'More',
                    actions: [
                      MenuAction(label: 'Push ${w.branch}', icon: EveryIcon.external, onSelected: () => _push(w)),
                      MenuAction(
                        label: 'Open folder',
                        icon: EveryIcon.projects,
                        onSelected: () => launchUrl(Uri.file(w.path)),
                      ),
                      MenuAction(
                        label: 'Open terminal',
                        icon: EveryIcon.code,
                        onSelected: () =>
                            ref.read(codePaneProvider(widget.session.id).notifier).show(CodePane.terminal),
                      ),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: AdaptiveIcon(EveryIcon.more, size: 16, color: theme.textMuted),
                    ),
                  ),
                  AdaptiveButton(
                    label: 'Discard',
                    emphasis: ButtonEmphasis.destructive,
                    onPressed: _busy ? null : _discard,
                  ),
                  AdaptiveButton(label: 'Create PR', emphasis: ButtonEmphasis.secondary, onPressed: _busy ? null : _pr),
                  AdaptiveButton(
                    label: 'Commit',
                    emphasis: ButtonEmphasis.secondary,
                    onPressed: _busy ? null : _commit,
                  ),
                  AdaptiveButton(
                    label: 'Merge into ${w.baseBranch}',
                    busy: _busy,
                    onPressed: (git?.files.isEmpty ?? true) && (git?.ahead ?? 0) == 0 ? null : _merge,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty(this.message);
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(message, textAlign: TextAlign.center, style: theme.type.callout.tint(theme.textMuted)),
      ),
    );
  }
}

class _FileView extends StatelessWidget {
  const _FileView({
    super.key,
    required this.file,
    required this.collapsed,
    required this.onToggle,
    required this.onRevert,
  });

  final FileDiff file;
  final bool collapsed;
  final VoidCallback onToggle;
  final void Function(int hunk)? onRevert;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final kindColor = switch (file.kind) {
      ChangeKind.added => theme.success,
      ChangeKind.deleted => theme.danger,
      _ => theme.warning,
    };
    return Container(
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        border: Border.all(color: theme.border),
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: [
                  AdaptiveIcon(collapsed ? EveryIcon.chevronRight : EveryIcon.chevronDown, size: 13),
                  const SizedBox(width: 6),
                  Text(file.kind.letter, style: theme.type.caption.medium.tint(kindColor)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      file.path,
                      overflow: TextOverflow.ellipsis,
                      style: _mono.copyWith(color: theme.text),
                    ),
                  ),
                  Text('+${file.added}', style: _mono.copyWith(color: theme.success)),
                  const SizedBox(width: 6),
                  Text('−${file.removed}', style: _mono.copyWith(color: theme.danger)),
                ],
              ),
            ),
          ),
          if (!collapsed && file.binary)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: Text('Binary file', style: theme.type.caption.tint(theme.textMuted)),
            ),
          if (!collapsed)
            for (final (i, hunk) in file.hunks.indexed)
              _HunkView(
                hunk: hunk,
                language: languageForPath(file.path),
                onRevert: onRevert == null ? null : () => onRevert!(i),
              ),
        ],
      ),
    );
  }
}

class _HunkView extends StatelessWidget {
  const _HunkView({required this.hunk, required this.onRevert, this.language});

  final DiffHunk hunk;

  /// The file's grammar, or null for plain text.
  final String? language;

  /// The +/-/space marker stays plain; the code after it is colored.
  Widget _line(EveryTheme theme, String line, Color fg) {
    final marker = line.isEmpty ? '' : line[0];
    if (language == null || line.length < 2 || !const {'+', '-', ' '}.contains(marker)) {
      return Text(line, softWrap: true, style: _mono.copyWith(color: fg));
    }
    final base = _mono.copyWith(color: fg);
    return Text.rich(
      TextSpan(
        style: base,
        children: [
          TextSpan(text: marker),
          codeSpan(line.substring(1), language, base: base, brightness: theme.brightness),
        ],
      ),
      softWrap: true,
    );
  }

  final VoidCallback? onRevert;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    var oldLine = hunk.oldStart, newLine = hunk.newStart;
    final rows = <Widget>[];
    for (final line in hunk.lines) {
      Color? bg;
      var fg = theme.textMuted;
      var number = '';
      switch (line.isEmpty ? ' ' : line[0]) {
        case '+':
          bg = theme.success.withValues(alpha: 0.12);
          fg = theme.text;
          number = '${newLine++}';
        case '-':
          bg = theme.danger.withValues(alpha: 0.12);
          fg = theme.text;
          number = '${oldLine++}';
        case r'\':
          break;
        default:
          number = '${newLine++}';
          oldLine++;
      }
      rows.add(
        Container(
          color: bg,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 34,
                child: Text(
                  number,
                  textAlign: TextAlign.right,
                  style: _mono.copyWith(color: theme.textMuted),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(child: _line(theme, line, fg)),
            ],
          ),
        ),
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.codeBackground,
        border: Border(top: BorderSide(color: theme.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
                  child: Text(
                    hunk.header,
                    overflow: TextOverflow.ellipsis,
                    style: _mono.copyWith(color: theme.textMuted),
                  ),
                ),
              ),
              if (onRevert != null)
                AdaptiveButton(label: 'Revert', emphasis: ButtonEmphasis.plain, onPressed: onRevert),
            ],
          ),
          ...rows,
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}
