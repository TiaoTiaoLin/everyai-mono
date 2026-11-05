import 'package:flutter/widgets.dart';

import '../../../../core/theme/every_theme.dart';
import '../../../../core/ui/adaptive.dart';
import '../../../../core/ui/brand.dart';
import '../../../../core/ui/every_icons.dart';
import '../../../chat/ui/chat_markdown.dart';
import '../../../usage/ui/usage_meter.dart';
import '../../../usage/usage_totals.dart';
import '../../domain/session_commands.dart';

/// A card above the composer: a `/btw` answer, the `/cost` breakdown, a
/// `/review` report, a `/commit` or `/pr` draft, a `/learn` result or the
/// `/morning` brief. It sits outside the transcript: the agent never sees it.
class AsideCard extends StatelessWidget {
  const AsideCard({
    super.key,
    required this.aside,
    required this.onDismiss,
    this.usage = UsageTotals.zero,
    this.contextWindow = 0,
    this.modelName,
    this.limitLines = const [],
    this.onSendToAgent,
    this.onOpenSession,
    this.onCommit,
    this.onCreatePr,
  });

  final Aside aside;
  final VoidCallback onDismiss;

  /// For a cost card.
  final UsageTotals usage;
  final int contextWindow;
  final String? modelName;

  /// For a usage card: the cap and plan limit lines Session info shows.
  final List<String> limitLines;

  /// A review: hands the findings to the agent.
  final VoidCallback? onSendToAgent;

  /// A review: opens the reviewer's own session.
  final ValueChanged<String>? onOpenSession;

  /// A commit draft: commits with the (edited) message.
  final Future<void> Function(String message)? onCommit;

  /// A pull request draft: opens it with the (edited) title and body.
  final Future<void> Function(String title, String body)? onCreatePr;

  String get _title {
    final q = aside.question;
    return switch (aside.kind) {
      AsideKind.btw => 'By the way: $q',
      AsideKind.cost => 'Usage and limits',
      AsideKind.review => q.isEmpty ? 'Review' : 'Review: $q',
      AsideKind.commit => 'Commit',
      AsideKind.pr => 'Pull request',
      AsideKind.learn => 'Learn from $q',
      AsideKind.morning => 'Your sessions',
    };
  }

  String get _busyLabel => switch (aside.kind) {
    AsideKind.review => 'Reviewing the changes…',
    AsideKind.commit => 'Writing a commit message…',
    AsideKind.pr => 'Drafting the pull request…',
    AsideKind.learn => 'Writing a skill…',
    AsideKind.morning => 'Gathering your sessions…',
    _ => 'Thinking…',
  };

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final childId = aside.childId;
    final Widget body = switch (aside) {
      Aside(kind: AsideKind.cost) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (usage.isEmpty)
            Text('No model calls yet.', style: theme.type.callout.tint(theme.textMuted))
          else
            UsageBreakdown(totals: usage, contextWindow: contextWindow, modelName: modelName),
          for (final line in limitLines)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(line, style: theme.type.callout.tint(theme.textMuted)),
            ),
        ],
      ),
      Aside(busy: true) => Row(
        children: [
          const EveryMarkActivity(activity: MarkActivity.thinking, size: 14),
          const SizedBox(width: 8),
          Expanded(child: Text(_busyLabel, style: theme.type.callout.tint(theme.textMuted))),
          if (childId != null && onOpenSession != null)
            AdaptiveButton(label: 'Watch', emphasis: ButtonEmphasis.plain, onPressed: () => onOpenSession!(childId)),
        ],
      ),
      Aside(:final error?) => Text(error, style: theme.type.callout.tint(theme.danger)),
      Aside(kind: AsideKind.commit, ready: true) => _CommitDraft(
        key: ValueKey('commit-${aside.id}'),
        message: aside.answer,
        onCommit: onCommit,
      ),
      Aside(kind: AsideKind.pr, ready: true) => _PrDraft(
        key: ValueKey('pr-${aside.id}'),
        title: aside.answer,
        body: aside.body,
        onCreate: onCreatePr,
      ),
      Aside(:final answer) => ChatMarkdown(answer),
    };
    final reviewActions = aside.kind == AsideKind.review && aside.ready && !aside.busy;
    return Container(
      decoration: BoxDecoration(
        color: theme.accent.withValues(alpha: 0.06),
        border: Border.all(color: theme.border),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.type.callout.semibold.tint(theme.textMuted),
                ),
              ),
              AdaptiveIconButton(icon: EveryIcon.close, tooltip: 'Dismiss', size: 14, onPressed: onDismiss),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 280),
              child: SingleChildScrollView(child: body),
            ),
          ),
          if (reviewActions)
            Padding(
              padding: const EdgeInsets.only(top: 8, right: 6),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                children: [
                  if (childId != null && onOpenSession != null)
                    AdaptiveButton(
                      label: 'Open review',
                      emphasis: ButtonEmphasis.secondary,
                      onPressed: () => onOpenSession!(childId),
                    ),
                  if (onSendToAgent != null) AdaptiveButton(label: 'Ask the agent to fix', onPressed: onSendToAgent),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The drafted commit message, editable, with Commit.
class _CommitDraft extends StatefulWidget {
  const _CommitDraft({super.key, required this.message, required this.onCommit});
  final String message;
  final Future<void> Function(String message)? onCommit;

  @override
  State<_CommitDraft> createState() => _CommitDraftState();
}

class _CommitDraftState extends State<_CommitDraft> {
  late final _message = TextEditingController(text: widget.message);
  bool _busy = false;

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  Future<void> _commit() async {
    final text = _message.text.trim();
    if (text.isEmpty || widget.onCommit == null) return;
    setState(() => _busy = true);
    try {
      await widget.onCommit!(text);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      const SizedBox(height: 6),
      AdaptiveTextField(controller: _message, minLines: 2, maxLines: 8, placeholder: 'Commit message'),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerRight,
        child: AdaptiveButton(label: 'Commit all changes', busy: _busy, onPressed: _commit),
      ),
    ],
  );
}

/// The drafted pull request, editable, with Create.
class _PrDraft extends StatefulWidget {
  const _PrDraft({super.key, required this.title, required this.body, required this.onCreate});
  final String title;
  final String body;
  final Future<void> Function(String title, String body)? onCreate;

  @override
  State<_PrDraft> createState() => _PrDraftState();
}

class _PrDraftState extends State<_PrDraft> {
  late final _title = TextEditingController(text: widget.title);
  late final _body = TextEditingController(text: widget.body);
  bool _busy = false;

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final title = _title.text.trim();
    if (title.isEmpty || widget.onCreate == null) return;
    setState(() => _busy = true);
    try {
      await widget.onCreate!(title, _body.text);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 6),
        AdaptiveTextField(controller: _title, placeholder: 'Title'),
        const SizedBox(height: 6),
        AdaptiveTextField(controller: _body, minLines: 3, maxLines: 10, placeholder: 'Description (Markdown)'),
        const SizedBox(height: 6),
        Text(
          'Commits anything left with the title, pushes the branch and opens the pull request with gh.',
          style: theme.type.caption.tint(theme.textMuted),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: AdaptiveButton(label: 'Create pull request', busy: _busy, onPressed: _create),
        ),
      ],
    );
  }
}
