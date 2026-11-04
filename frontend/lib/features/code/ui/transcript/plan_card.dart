import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../../core/theme/every_theme.dart';
import '../../../../core/ui/adaptive.dart';
import '../../../../core/ui/every_icons.dart';
import '../../../chat/ui/chat_markdown.dart';
import '../../domain/transcript.dart';

final _mono = EveryType.resolve().caption.mono.copyWith(height: 1.4);

/// The agent's `present_plan` proposal: numbered steps with the files they
/// touch, risks, and how it will verify. While [open], the user can start
/// building or send it back with changes.
class PlanCard extends StatefulWidget {
  const PlanCard({
    super.key,
    required this.plan,
    required this.open,
    required this.onApprove,
    required this.onRevise,
    this.switchesToAutoEdit = false,
  });

  final PlanProposal plan;
  final bool open;

  /// In Plan mode, approving moves the session to Auto-edit.
  final bool switchesToAutoEdit;
  final VoidCallback onApprove;
  final ValueChanged<String> onRevise;

  @override
  State<PlanCard> createState() => _PlanCardState();
}

class _PlanCardState extends State<PlanCard> {
  final _feedback = TextEditingController();
  bool _revising = false;
  bool _sent = false;

  @override
  void dispose() {
    _feedback.dispose();
    super.dispose();
  }

  void _approve() {
    if (_sent) return;
    setState(() => _sent = true);
    widget.onApprove();
  }

  void _revise() {
    final text = _feedback.text.trim();
    if (text.isEmpty || _sent) return;
    setState(() => _sent = true);
    widget.onRevise(text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final plan = widget.plan;
    final open = widget.open && !_sent;
    final steps = plan.steps;
    final risks = plan.risks;

    return Container(
      decoration: BoxDecoration(
        color: theme.surfaceRaised,
        border: Border.all(color: open ? theme.accent.withValues(alpha: 0.5) : theme.border),
        borderRadius: BorderRadius.circular(EveryTheme.cardRadius),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              AdaptiveIcon(EveryIcon.document, size: 15, color: theme.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(plan.title.isEmpty ? 'Plan' : plan.title, style: theme.type.headline.tint(theme.text)),
              ),
              if (plan.verdict case final verdict?)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Text(
                    verdict == PlanVerdict.approved ? 'Approved' : 'Sent back',
                    style: theme.type.caption.semibold.tint(
                      verdict == PlanVerdict.approved ? theme.success : theme.textMuted,
                    ),
                  ),
                ),
              AdaptiveIconButton(
                icon: EveryIcon.copy,
                tooltip: 'Copy plan',
                size: 15,
                onPressed: () => Clipboard.setData(ClipboardData(text: plan.markdown)),
              ),
            ],
          ),
          if (plan.summary.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(plan.summary, style: theme.type.callout.copyWith(color: theme.textMuted, height: 1.4)),
          ],
          if (plan.body.trim().isNotEmpty) ...[const SizedBox(height: 8), ChatMarkdown(plan.body.trim())],
          const SizedBox(height: 10),
          for (final (i, step) in steps.indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: 8, right: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 22, child: Text('${i + 1}.', style: theme.type.callout.semibold.tint(theme.accent))),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(step.title, style: theme.type.body.medium.copyWith(color: theme.text, height: 1.35)),
                        if (step.detail.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              step.detail,
                              style: theme.type.callout.copyWith(color: theme.textMuted, height: 1.35),
                            ),
                          ),
                        if (step.files.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 3),
                            child: Text(step.files.join('  '), style: _mono.copyWith(color: theme.textMuted)),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          if (risks.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('Risks', style: theme.type.callout.semibold.tint(theme.text)),
            const SizedBox(height: 3),
            for (final r in risks)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text('•  $r', style: theme.type.callout.copyWith(color: theme.textMuted, height: 1.35)),
              ),
          ],
          if (plan.verification.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: 'Verify: ',
                    style: TextStyle(color: theme.text, fontWeight: FontWeight.w600),
                  ),
                  TextSpan(text: plan.verification),
                ],
              ),
              style: theme.type.callout.copyWith(color: theme.textMuted, height: 1.35),
            ),
          ],
          if (open) ...[
            const SizedBox(height: 12),
            if (_revising) ...[
              AdaptiveTextField(
                controller: _feedback,
                placeholder: 'What should change?',
                autofocus: true,
                minLines: 1,
                maxLines: 4,
                onSubmitted: (_) => _revise(),
              ),
              const SizedBox(height: 8),
            ],
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.switchesToAutoEdit ? 'Start building switches to Auto-edit.' : '',
                    style: theme.type.caption.tint(theme.textMuted),
                  ),
                ),
                if (_revising)
                  AdaptiveButton(label: 'Send changes', emphasis: ButtonEmphasis.secondary, onPressed: _revise)
                else
                  AdaptiveButton(
                    label: 'Keep planning',
                    emphasis: ButtonEmphasis.secondary,
                    onPressed: () => setState(() => _revising = true),
                  ),
                const SizedBox(width: 8),
                AdaptiveButton(label: 'Start building', onPressed: _approve),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
