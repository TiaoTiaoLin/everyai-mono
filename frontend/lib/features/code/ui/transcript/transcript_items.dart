import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../../../core/theme/every_theme.dart';

import 'package:everyai_markdown/everyai_markdown.dart' show languageForPath;

import '../../../../core/ui/adaptive.dart';
import '../../../../core/ui/brand.dart';
import '../../../../core/ui/every_icons.dart';
import '../../../../core/ui/syntax_spans.dart';
import '../../../attachments/attachment.dart';
import '../../../attachments/ui/attachment_tray.dart';
import '../../../chat/ui/chat_markdown.dart';
import '../../domain/agent_mode.dart';
import '../../domain/line_diff.dart';
import '../../domain/permissions.dart' show denialSummary;
import '../../domain/transcript.dart';
import '../../../settings/settings_registry.dart' show SettingsSection;
import '../../../settings/ui/settings_modal.dart' show showSettings;
import '../../harness/events.dart';
import '../../settings/context_files_stub.dart' if (dart.library.io) '../../settings/context_files_io.dart' as impl;
import '../../uploads/uploads.dart';

final _mono = EveryType.resolve().callout.mono.copyWith(height: 1.45);
final _monoSmall = EveryType.resolve().caption.mono.copyWith(height: 1.45);

/// The user's message, right-aligned like chat.
class UserTurnView extends StatelessWidget {
  const UserTurnView({super.key, required this.text, this.mode, this.lead = '', this.onRewind});
  final String text;

  /// The harness that got it, shown when the session had more than one ('' hides it).
  final String lead;

  /// Restores the files to before this message.
  final VoidCallback? onRewind;

  /// The mode the message was sent in, when it told the agent about one.
  final AgentMode? mode;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final (body, files) = splitAttachedNote(text);
    return Align(
      alignment: Alignment.centerRight,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (mode != null || lead.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 4, right: 4),
              child: Text(
                [if (lead.isNotEmpty) lead, if (mode != null) '${mode!.label} mode'].join(' · '),
                style: theme.type.caption.medium.tint(theme.textMuted),
              ),
            ),
          if (files.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final path in files)
                    AttachmentChip(name: path.split('/').last, kind: kindOf(path, Uint8List(0))),
                ],
              ),
            ),
          if (body.trim().isNotEmpty)
            LayoutBuilder(
              builder: (context, constraints) => ConstrainedBox(
                constraints: BoxConstraints(maxWidth: constraints.maxWidth * 0.85),
                child: DecoratedBox(
                  decoration: BoxDecoration(color: theme.userBubble, borderRadius: theme.userBubbleShape),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                    child: IntrinsicWidth(child: ChatMarkdown(body, textColor: theme.onUserBubble)),
                  ),
                ),
              ),
            ),
          if (onRewind case final rewind?)
            GestureDetector(
              onTap: rewind,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Padding(
                  padding: const EdgeInsets.only(top: 4, right: 4),
                  child: Text('Rewind to here', style: theme.type.caption.tint(theme.textMuted)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The agent's prose, with its reasoning folded away.
class AgentTextView extends StatelessWidget {
  const AgentTextView({super.key, required this.text, this.reasoning = '', this.streaming = false});
  final String text;
  final String reasoning;
  final bool streaming;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (reasoning.trim().isNotEmpty)
          _Disclosure(
            icon: EveryIcon.spark,
            // Our mark, as the working row shows it, rather than a generic sparkle.
            mark: true,
            busy: streaming && text.isEmpty,
            busyMark: MarkActivity.thinking,
            title: streaming && text.isEmpty ? 'Thinking…' : 'Thought',
            child: Text(
              reasoning.trim(),
              style: EveryTheme.of(context).type.callout.tint(EveryTheme.of(context).textMuted),
            ),
          ),
        if (text.trim().isNotEmpty) ChatMarkdown(text, streaming: streaming),
      ],
    );
  }
}

/// "Explored 2 files, 1 search", expandable to each step.
class ExploreGroupView extends StatelessWidget {
  const ExploreGroupView({super.key, required this.group});
  final ExploreGroup group;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final running = group.steps.any((s) => !s.done);
    final current = running ? group.steps.lastWhere((s) => !s.done) : null;
    return _Disclosure(
      icon: EveryIcon.search,
      title: '${running ? 'Exploring' : 'Explored'} ${exploreSummary(group.steps)}',
      busy: running,
      preview: current == null ? null : stepTitleSpan(context, current.call, _mono),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final s in group.steps)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  _StatusDot(step: s),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text.rich(
                      stepTitleSpan(context, s.call, _mono.copyWith(color: theme.textMuted)),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// A command, an edit or another tool call.
class StepView extends StatelessWidget {
  const StepView({super.key, required this.step});
  final ToolStep step;

  @override
  Widget build(BuildContext context) => switch (step.call.actionKind) {
    'TerminalAction' => _CommandView(step: step),
    'FileEditorAction' || 'EditAction' || 'WriteFileAction' => _EditView(step: step),
    'ScriptAction' => _ScriptView(step: step),
    _ => _ToolView(step: step),
  };
}

/// "12 calls · 38 decides · 4 queries": what a run_script spent, or empty.
String scriptSummary(Map<String, Object?> observation) {
  int n(String key) => (observation[key] as num?)?.toInt() ?? 0;
  String count(int v, String one, String many) => '$v ${v == 1 ? one : many}';
  return [
    if (n('call_count') > 0) count(n('call_count'), 'call', 'calls'),
    if (n('decides') > 0) count(n('decides'), 'decide', 'decides'),
    if (n('queries') > 0) count(n('queries'), 'query', 'queries'),
  ].join(' · ');
}

/// A run_script step: its description, what it spent, and opened, the
/// program, the calls it made and what it printed.
class _ScriptView extends StatelessWidget {
  const _ScriptView({required this.step});
  final ToolStep step;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final obs = step.result?.observation ?? const {};
    final output = step.result?.text ?? '';
    final calls = [...(obs['calls'] as List<Object?>? ?? const []).whereType<Map<String, Object?>>()];
    final summary = scriptSummary(obs);
    final base = _mono.copyWith(color: theme.text);
    return _Disclosure(
      icon: EveryIcon.code,
      title: stepTitle(step.call),
      busy: !step.done,
      preview: step.done && output.trim().isNotEmpty ? TextSpan(text: lastLine(output)) : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (obs['timed_out'] == true)
            Text('timed out', style: theme.type.caption.tint(theme.danger))
          else if (summary.isNotEmpty)
            Text(summary, style: theme.type.caption.tint(theme.textMuted)),
          if (!step.done) const RunningTime(),
          const SizedBox(width: 6),
          _StatusDot(step: step),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _CodeBox(codeSpan(step.call.str('code'), 'typescript', base: base, brightness: theme.brightness)),
          if (calls.isNotEmpty) ...[
            const SizedBox(height: 6),
            for (final c in calls.take(40))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: Text(
                  '${c['failed'] == true ? '✕' : '·'} ${c['detail'] ?? c['fn']}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.type.caption.mono.tint(c['failed'] == true ? theme.danger : theme.textMuted),
                ),
              ),
            if (calls.length > 40)
              Text('… ${calls.length - 40} more calls', style: theme.type.caption.tint(theme.textMuted)),
          ],
          if (step.done) ...[const SizedBox(height: 6), _Output(output)],
        ],
      ),
    );
  }
}

/// Any other tool: its name, a preview of the result, and the arguments
/// and output (JSON colored) when opened.
class _ToolView extends StatelessWidget {
  const _ToolView({required this.step});
  final ToolStep step;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final args = Map.of(step.call.action)..remove('kind');
    final output = step.result?.text ?? '';
    return _Disclosure(
      icon: EveryIcon.code,
      title: stepTitle(step.call),
      titleSpan: stepTitleSpan(context, step.call, theme.type.callout.tint(theme.textMuted)),
      busy: !step.done,
      preview: step.done && output.trim().isNotEmpty ? TextSpan(text: lastLine(output)) : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Bug fix: whether the decider read the failing repro as this bug.
          if (step.result?.observation['repro_match'] case final String m when m != 'other') ...[
            Text(
              m == 'bug' ? 'matches the bug ✓' : 'match unsure ?',
              style: theme.type.caption.tint(m == 'bug' ? theme.success : theme.textMuted),
            ),
            const SizedBox(width: 6),
          ],
          _StatusDot(step: step),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (args.isNotEmpty) ...[
            _CodeBox(
              argumentsSpan(
                args,
                base: _mono.copyWith(color: theme.text),
                brightness: theme.brightness,
              ),
            ),
            const SizedBox(height: 6),
          ],
          if (step.done) _Output(output),
        ],
      ),
    );
  }
}

/// A row's title with its path or command colored: "Edited lib/**main.dart**",
/// "\$ git status".
TextSpan stepTitleSpan(BuildContext context, ActionCall call, TextStyle base) {
  final span = _titleSpan(context, call, base);
  if (!call.native || call.nativeName.isEmpty || span.toPlainText().contains(call.nativeName)) return span;
  // An outside harness's own word for the tool (Bash, apply_patch), before our title.
  final theme = EveryTheme.of(context);
  return TextSpan(
    style: base,
    children: [
      TextSpan(
        text: '${call.nativeName}  ',
        style: _mono.copyWith(color: theme.textMuted, fontSize: (base.fontSize ?? 13) - 1),
      ),
      span,
    ],
  );
}

TextSpan _titleSpan(BuildContext context, ActionCall call, TextStyle base) {
  final theme = EveryTheme.of(context);
  final title = stepTitle(call);
  if (call.actionKind == 'TerminalAction') {
    return TextSpan(
      style: base,
      children: [shellSpan(call.str('command'), base: base, brightness: theme.brightness)],
    );
  }
  final full = stepPath(call);
  if (full.isEmpty || !title.endsWith(full)) return TextSpan(text: title, style: base);
  // Long absolute paths cut off the file name; show them from the session.
  final path = displayPath(full, TranscriptScope.rootOf(context), home: impl.homeDir());
  final lead = title.substring(0, title.length - full.length);
  final mono = base.fontFamily == null
      ? _mono.copyWith(color: base.color, fontSize: base.fontSize == null ? null : base.fontSize! - 0.5)
      : base;
  return TextSpan(
    style: base,
    children: [
      TextSpan(text: lead),
      pathSpan(
        path,
        base: mono.copyWith(color: theme.text),
        muted: theme.textMuted,
      ),
    ],
  );
}

/// The file or folder a step works on, or empty.
String stepPath(ActionCall call) {
  for (final key in const ['file_path', 'dir_path', 'path']) {
    final v = call.str(key);
    if (v.isNotEmpty) return v;
  }
  return '';
}

class _CommandView extends StatelessWidget {
  const _CommandView({required this.step});
  final ToolStep step;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final obs = step.result?.observation ?? const {};
    final exit = obs['exit_code'] as int? ?? (obs['metadata'] as Map<String, Object?>?)?['exit_code'] as int?;
    final output =
        step.result?.text ??
        (step.rejected ? 'Not run: ${denialSummary('${step.result!.observation['reason'] ?? ''}')}' : '');
    final command = step.call.str('command');
    final base = _mono.copyWith(color: theme.text);
    return _Disclosure(
      title: '\$ $command',
      titleSpan: TextSpan(
        style: base,
        children: [
          TextSpan(
            text: '\$ ',
            style: TextStyle(color: theme.textMuted),
          ),
          shellSpan(command, base: base, brightness: theme.brightness),
        ],
      ),
      busy: !step.done,
      preview: step.done && output.trim().isNotEmpty ? TextSpan(text: lastLine(output)) : null,
      initiallyOpen: false,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (exit != null && exit != 0) Text('exit $exit', style: theme.type.caption.tint(theme.danger)),
          if (!step.done) const RunningTime(),
          const SizedBox(width: 6),
          _StatusDot(step: step),
        ],
      ),
      child: _Output(output),
    );
  }
}

/// What transcript rows know about their session: the folder paths are shown
/// relative to, and how to open a file in the Changes pane ([openDiff] null
/// where there is no diff to show).
class TranscriptScope extends InheritedWidget {
  const TranscriptScope({super.key, this.root = '', this.openDiff, required super.child});

  final String root;
  final void Function(String path)? openDiff;

  static TranscriptScope? _of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<TranscriptScope>();

  static void Function(String path)? diffOf(BuildContext context) => _of(context)?.openDiff;

  static String rootOf(BuildContext context) => _of(context)?.root ?? '';

  @override
  bool updateShouldNotify(TranscriptScope old) => root != old.root || (openDiff == null) != (old.openDiff == null);
}

/// [path] as the user reads it: relative inside [root], `~/…` under the home
/// folder, otherwise as given.
String displayPath(String path, String root, {String? home}) {
  if (root.isNotEmpty) {
    final r = root.endsWith('/') ? root : '$root/';
    if (path == root || path == r) return '.';
    if (path.startsWith(r)) return path.substring(r.length);
  }
  if (home != null && home.isNotEmpty && path.startsWith('$home/')) return '~${path.substring(home.length)}';
  return path;
}

class _EditView extends StatelessWidget {
  const _EditView({required this.step});
  final ToolStep step;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final call = step.call;
    final obs = step.result?.observation ?? const {};
    final before = obs['old_content'] as String? ?? call.str('old_str');
    final after =
        obs['new_content'] as String? ?? (call.str('new_str').isNotEmpty ? call.str('new_str') : call.str('file_text'));
    final lines = lineDiff(before, after);
    final stats = diffStats(lines);
    final path = stepPath(call);
    final openDiff = TranscriptScope.diffOf(context);
    // Folded by default, and it stays as the user left it: opening the diff
    // when the edit landed made the rows above jump.
    return _Disclosure(
      icon: EveryIcon.edit,
      title: stepTitle(call),
      titleSpan: stepTitleSpan(context, call, theme.type.callout.tint(theme.textMuted)),
      busy: !step.done,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (stats.added > 0) Text('+${stats.added}', style: theme.type.caption.tint(theme.success)),
          const SizedBox(width: 4),
          if (stats.removed > 0) Text('−${stats.removed}', style: theme.type.caption.tint(theme.danger)),
          if (openDiff != null && step.done && !step.rejected && path.isNotEmpty)
            AdaptiveIconButton(
              icon: EveryIcon.openPanel,
              tooltip: 'Show in Changes',
              size: 13,
              onPressed: () => openDiff(path),
            ),
          const SizedBox(width: 6),
          _StatusDot(step: step),
        ],
      ),
      child: step.rejected
          ? _Output('Not applied: ${denialSummary('${obs['reason'] ?? 'rejected'}')}')
          : DiffBlock(
              lines: lines,
              maxLines: 12,
              language: languageForPath(path),
              onOpenMore: openDiff == null || path.isEmpty ? null : () => openDiff(path),
            ),
    );
  }
}

/// A unified diff with line numbers, colored as [language] (from
/// `languageForPath`) when given.
class DiffBlock extends StatelessWidget {
  const DiffBlock({super.key, required this.lines, this.maxLines = 60, this.language, this.onOpenMore});
  final List<DiffLine> lines;
  final int maxLines;
  final String? language;

  /// Opens the whole file in the Changes pane, from the "more lines" note.
  final VoidCallback? onOpenMore;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    if (lines.isEmpty) return Text('No changes', style: theme.type.callout.tint(theme.textMuted));
    final shown = lines.take(maxLines).toList();
    return Container(
      decoration: BoxDecoration(color: theme.codeBackground, borderRadius: BorderRadius.circular(8)),
      clipBehavior: Clip.antiAlias,
      // Rows fill the block (or the longest line) so highlights span it.
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: constraints.maxWidth),
            child: IntrinsicWidth(child: _rows(theme, shown)),
          ),
        ),
      ),
    );
  }

  Widget _rows(EveryTheme theme, List<DiffLine> shown) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final l in shown)
        Container(
          color: switch (l.kind) {
            DiffKind.added => theme.success.withValues(alpha: 0.14),
            DiffKind.removed => theme.danger.withValues(alpha: 0.13),
            _ => null,
          },
          padding: const EdgeInsets.only(right: 16),
          child: l.kind == DiffKind.gap
              ? Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                  child: Text('⋯ ${l.text}', style: _monoSmall.copyWith(color: theme.textMuted)),
                )
              : Row(
                  children: [
                    SizedBox(
                      width: 36,
                      child: Text(
                        '${l.newNo ?? l.oldNo ?? ''}',
                        textAlign: TextAlign.right,
                        style: _monoSmall.copyWith(color: theme.textMuted.withValues(alpha: 0.7)),
                      ),
                    ),
                    SizedBox(
                      width: 18,
                      child: Text(switch (l.kind) {
                        DiffKind.added => ' +',
                        DiffKind.removed => ' −',
                        _ => '',
                      }, style: _mono.copyWith(color: l.kind == DiffKind.added ? theme.success : theme.danger)),
                    ),
                    Text.rich(
                      codeSpan(
                        l.text,
                        language,
                        base: _mono.copyWith(color: theme.text),
                        brightness: theme.brightness,
                      ),
                    ),
                  ],
                ),
        ),
      if (lines.length > maxLines)
        Padding(
          padding: const EdgeInsets.all(8),
          child: onOpenMore == null
              ? Text('${lines.length - maxLines} more lines', style: theme.type.caption.tint(theme.textMuted))
              : GestureDetector(
                  onTap: onOpenMore,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: Text(
                      '${lines.length - maxLines} more lines · Show in Changes',
                      style: theme.type.caption.tint(theme.accent),
                    ),
                  ),
                ),
        ),
    ],
  );
}

/// A delegated task, as a nested card.
class SubagentView extends StatelessWidget {
  const SubagentView({super.key, required this.item});
  final SubagentItem item;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final step = item.step;
    final tasks = item.tasks;
    final names = tasks.keys.isEmpty ? ['subagent'] : tasks.keys.toList();
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: theme.border),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              AdaptiveIcon(EveryIcon.spark, size: 14, color: theme.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  step.done ? 'Subagent ${names.join(', ')} finished' : 'Subagent ${names.join(', ')} working…',
                  style: theme.type.callout.semibold.tint(theme.text),
                ),
              ),
              _StatusDot(step: step),
            ],
          ),
          for (final e in tasks.entries)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 22),
              child: Text(e.value, style: theme.type.callout.tint(theme.textMuted)),
            ),
          if (step.result case final r?)
            Padding(
              padding: const EdgeInsets.only(top: 8, left: 22),
              child: _Disclosure(title: 'Result', child: ChatMarkdown(r.text.isEmpty ? '(no output)' : r.text)),
            ),
        ],
      ),
    );
  }
}

/// The agent's task list.
class PlanView extends StatelessWidget {
  const PlanView({super.key, required this.tasks, this.compact = false});
  final List<PlanTask> tasks;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final done = tasks.where((t) => t.status == 'done').length;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: theme.surfaceRaised,
        border: Border.all(color: theme.border),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Plan · $done of ${tasks.length} done', style: theme.type.caption.semibold.tint(theme.textMuted)),
          const SizedBox(height: 6),
          for (final t in tasks)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(padding: const EdgeInsets.only(top: 2), child: _TaskMark(t.status)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          // The harness's own wording of what it is doing, while it does it.
                          t.status == 'in_progress' && t.active.isNotEmpty ? t.active : t.title,
                          style: theme.type.callout.copyWith(
                            color: t.status == 'done' ? theme.textMuted : theme.text,
                            decoration: t.status == 'done' ? TextDecoration.lineThrough : null,
                            decorationColor: theme.textMuted,
                            fontWeight: t.status == 'in_progress' ? FontWeight.w600 : FontWeight.w400,
                          ),
                        ),
                        if (t.notes.isNotEmpty) Text(t.notes, style: theme.type.caption.tint(theme.textMuted)),
                      ],
                    ),
                  ),
                  if (t.priority.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Text(t.priority, style: theme.type.caption.tint(theme.textMuted)),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _TaskMark extends StatelessWidget {
  const _TaskMark(this.status);
  final String status;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return switch (status) {
      'done' => Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(color: theme.success, shape: BoxShape.circle),
        child: Center(child: AdaptiveIcon(EveryIcon.check, size: 10, color: const Color(0xFFFFFFFF))),
      ),
      'in_progress' => Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(
          border: Border.all(color: theme.accent, width: 2),
          shape: BoxShape.circle,
        ),
        child: Center(
          child: Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(color: theme.accent, shape: BoxShape.circle),
          ),
        ),
      ),
      _ => Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(
          border: Border.all(color: theme.textMuted, width: 1.5),
          shape: BoxShape.circle,
        ),
      ),
    };
  }
}

class NoticeView extends StatefulWidget {
  const NoticeView({super.key, required this.item, this.onRetry, this.onChange});
  final NoticeItem item;
  final VoidCallback? onRetry;

  /// Change on an automatic handoff: the picker again.
  final VoidCallback? onChange;

  @override
  State<NoticeView> createState() => _NoticeViewState();
}

class _NoticeViewState extends State<NoticeView> {
  /// The detail (a compaction's summary, a handoff's facts) is shown.
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final item = widget.item;
    final color = item.error ? theme.danger : theme.textMuted;
    final detail = item.detail.trim();
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(8)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (!item.error) ...[const BrandAvatar(size: 18), const SizedBox(width: 8)],
              Expanded(child: Text(item.message, style: theme.type.callout.tint(color))),
              if (detail.isNotEmpty) ...[
                const SizedBox(width: 8),
                AdaptiveButton(
                  key: const ValueKey('notice.detail'),
                  label: _open ? 'Hide' : 'Show',
                  emphasis: ButtonEmphasis.secondary,
                  onPressed: () => setState(() => _open = !_open),
                ),
              ],
              // Out of credits: the two ways on, then Retry (or a new message) resumes.
              if (item.error && isOutOfCredits(item.message)) ...[
                const SizedBox(width: 8),
                AdaptiveButton(
                  label: 'Top up',
                  emphasis: ButtonEmphasis.secondary,
                  onPressed: () => showSettings(context, section: SettingsSection.billing),
                ),
                const SizedBox(width: 6),
                AdaptiveButton(
                  label: 'Use my own key',
                  emphasis: ButtonEmphasis.secondary,
                  onPressed: () => showSettings(context, section: SettingsSection.apiKeys),
                ),
              ],
              if (widget.onRetry != null) ...[
                const SizedBox(width: 8),
                AdaptiveButton(label: 'Retry', emphasis: ButtonEmphasis.secondary, onPressed: widget.onRetry),
              ],
              if (widget.onChange != null) ...[
                const SizedBox(width: 8),
                AdaptiveButton(
                  key: const ValueKey('notice.change'),
                  label: 'Change',
                  emphasis: ButtonEmphasis.secondary,
                  onPressed: widget.onChange,
                ),
              ],
            ],
          ),
          if (_open && detail.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 360),
                child: SingleChildScrollView(
                  child: Text(detail, style: _monoSmall.copyWith(color: theme.text)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Spinner while running, check when done, cross on failure.
class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.step});
  final ToolStep step;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    if (!step.done) return const EveryMarkActivity(activity: MarkActivity.tool, size: 13);
    if (step.rejected) return AdaptiveIcon(EveryIcon.close, size: 13, color: theme.textMuted);
    if (step.failed) return AdaptiveIcon(EveryIcon.close, size: 13, color: theme.danger);
    return AdaptiveIcon(EveryIcon.check, size: 13, color: theme.success);
  }
}

class _Output extends StatelessWidget {
  const _Output(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    if (text.trim().isEmpty) return Text('No output', style: theme.type.callout.tint(theme.textMuted));
    final lines = text.split('\n');
    final clipped = lines.length > 40 ? [...lines.take(40), '… ${lines.length - 40} more lines'].join('\n') : text;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: theme.codeBackground, borderRadius: BorderRadius.circular(8)),
      child: Text.rich(
        outputSpan(
          clipped,
          base: _mono.copyWith(color: theme.text),
          brightness: theme.brightness,
        ),
      ),
    );
  }
}

/// Colored code in a tinted box.
class _CodeBox extends StatelessWidget {
  const _CodeBox(this.span);
  final TextSpan span;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: theme.codeBackground, borderRadius: BorderRadius.circular(8)),
      child: Text.rich(span),
    );
  }
}

/// A one-line header that expands to [child].
class _Disclosure extends StatefulWidget {
  const _Disclosure({
    required this.title,
    required this.child,
    this.icon,
    this.trailing,
    this.titleSpan,
    this.preview,
    this.busy = false,
    this.busyMark = MarkActivity.tool,
    this.mark = false,
    this.initiallyOpen = false,
  });

  final String title;

  /// A colored title, shown instead of [title] (which stays for semantics).
  final InlineSpan? titleSpan;

  /// One muted line under the title while folded: the latest output, or
  /// what a running group is on.
  final InlineSpan? preview;
  final Widget child;
  final EveryIcon? icon;
  final Widget? trailing;
  final bool busy;

  /// How the mark moves while [busy].
  final MarkActivity busyMark;

  /// The EveryAI mark in place of [icon] when settled (the agent's own thoughts).
  final bool mark;
  final bool initiallyOpen;

  @override
  State<_Disclosure> createState() => _DisclosureState();
}

class _DisclosureState extends State<_Disclosure> {
  late bool _open = widget.initiallyOpen;
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _open = !_open),
            child: Semantics(
              button: true,
              expanded: _open,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
                decoration: BoxDecoration(
                  color: _hover ? theme.text.withValues(alpha: 0.04) : null,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    if (widget.icon != null) ...[
                      // The mark works while the step runs.
                      if (widget.busy)
                        EveryMarkActivity(activity: widget.busyMark, size: 13)
                      else if (widget.mark)
                        const BrandMark(size: 13)
                      else
                        AdaptiveIcon(widget.icon!, size: 13, color: theme.textMuted),
                      const SizedBox(width: 8),
                    ],
                    // Title and chevron hug the left; trailing sits at the right edge.
                    Expanded(
                      child: Row(
                        children: [
                          Flexible(
                            child: widget.titleSpan == null
                                ? Text(
                                    widget.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.type.callout.tint(theme.textMuted),
                                  )
                                : Text.rich(
                                    widget.titleSpan!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    semanticsLabel: widget.title,
                                  ),
                          ),
                          const SizedBox(width: 4),
                          AnimatedRotation(
                            turns: _open ? 0.25 : 0,
                            duration: const Duration(milliseconds: 120),
                            child: AdaptiveIcon(EveryIcon.chevronRight, size: 11, color: theme.textMuted),
                          ),
                        ],
                      ),
                    ),
                    if (widget.trailing != null) widget.trailing!,
                  ],
                ),
              ),
            ),
          ),
        ),
        if (!_open && widget.preview != null)
          Padding(
            padding: EdgeInsets.fromLTRB(widget.icon == null ? 6 : 27, 0, 6, 3),
            child: Text.rich(
              widget.preview!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _monoSmall.copyWith(color: theme.textMuted),
            ),
          ),
        if (_open) Padding(padding: const EdgeInsets.fromLTRB(6, 4, 0, 4), child: widget.child),
      ],
    );
  }
}

/// Describes an action waiting for approval.
String approvalTitle(ActionCall call) => switch (call.actionKind) {
  'TerminalAction' => 'Run this command?',
  'FileEditorAction' when call.str('command') == 'view' => 'Read ${call.str('path')}?',
  'FileEditorAction' when call.str('command') == 'create' => 'Create ${call.str('path')}?',
  'FileEditorAction' => 'Edit ${call.str('path')}?',
  'ApplyPatchAction' => switch ((call.action['paths'] as List<Object?>?)?.length ?? 0) {
    1 => 'Patch ${call.str('path')}?',
    final n => 'Apply this patch to $n files?',
  },
  'DelegateAction' || 'TaskAction' => 'Start a subagent?',
  _ => 'Allow ${call.nativeName.isEmpty ? call.toolName : call.nativeName}?',
};

/// Three or more consecutive finished commands or tool calls, shown as one
/// row ("Ran 3 commands") that opens to each step.
final class StepRun {
  StepRun(this.steps);
  final List<ToolStep> steps;
  String get key => 'run:${steps.first.call.id}';
}

/// Folds runs of finished, non-edit steps in [items] into [StepRun]s; every
/// other item passes through. Edits, running steps and refused steps stay
/// on their own rows so their diffs and approvals stay in view.
List<Object> groupSteps(List<TranscriptItem> items, {int minRun = 3}) {
  final out = <Object>[];
  final run = <StepItem>[];
  void flush() {
    if (run.length >= minRun) {
      out.add(StepRun([for (final s in run) s.step]));
    } else {
      out.addAll(run);
    }
    run.clear();
  }

  for (final item in items) {
    if (item is StepItem && _groupable(item.step)) {
      run.add(item);
    } else {
      flush();
      out.add(item);
    }
  }
  flush();
  return out;
}

bool _groupable(ToolStep s) =>
    s.done && !s.rejected && !const {'FileEditorAction', 'EditAction', 'WriteFileAction'}.contains(s.call.actionKind);

/// "Ran 2 commands, used 1 tool".
String stepRunSummary(List<ToolStep> steps) {
  final commands = steps.where((s) => s.call.actionKind == 'TerminalAction').length;
  final tools = steps.length - commands;
  String n(int count, String one, String many) => '$count ${count == 1 ? one : many}';
  return [
    if (commands > 0) 'Ran ${n(commands, 'command', 'commands')}',
    if (tools > 0) '${commands > 0 ? 'used' : 'Used'} ${n(tools, 'tool', 'tools')}',
  ].join(', ');
}

class StepRunView extends StatelessWidget {
  const StepRunView({super.key, required this.run});
  final StepRun run;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final failed = run.steps.where((s) => s.failed).length;
    return _Disclosure(
      icon: EveryIcon.code,
      title: stepRunSummary(run.steps),
      preview: stepTitleSpan(context, run.steps.last.call, _mono),
      trailing: failed > 0
          ? Text('$failed failed', style: theme.type.caption.tint(theme.danger))
          : AdaptiveIcon(EveryIcon.check, size: 13, color: theme.success),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [for (final s in run.steps) StepView(step: s)],
      ),
    );
  }
}

/// "12s" / "1m 05s" for a clock, e.g. a command that has run this long.
String formatElapsed(Duration d) {
  final s = d.inSeconds;
  if (s < 60) return '${s}s';
  return '${s ~/ 60}m ${(s % 60).toString().padLeft(2, '0')}s';
}

/// Counts up from when it appears (a running command), once it passes two seconds.
class RunningTime extends StatefulWidget {
  const RunningTime({super.key});

  @override
  State<RunningTime> createState() => _RunningTimeState();
}

class _RunningTimeState extends State<RunningTime> {
  final _clock = Stopwatch()..start();
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_clock.elapsed < const Duration(seconds: 2)) return const SizedBox.shrink();
    final theme = EveryTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Text(
        formatElapsed(_clock.elapsed),
        style: theme.type.caption.copyWith(color: theme.textMuted, fontFeatures: const [FontFeature.tabularFigures()]),
      ),
    );
  }
}
