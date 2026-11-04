// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter/widgets.dart';

import '../../../../core/theme/every_theme.dart';
import '../../../../core/ui/adaptive.dart';
import '../../../../core/ui/anchored_popover.dart' show PopoverRow;
import '../../../../core/ui/every_icons.dart';
import '../../drivers/usage_limit.dart';

/// A harness the session can carry on with: its id, name, and the model it
/// would use with how it is paid ("Sonnet 5.5 · credits").
typedef LeadChoice = ({String id, String label, String subtitle});

/// The lead ran out of usage: carry on with another harness that is ready
/// ([choices]), or Wait. The session's files, plan and checklist go with it.
class LeadOfferCard extends StatelessWidget {
  const LeadOfferCard({
    super.key,
    required this.lead,
    required this.limit,
    required this.choices,
    required this.onSwitch,
    required this.onWait,
    this.credits = false,
    this.now,
  });

  /// The harness that ran out, by name.
  final String lead;
  final UsageLimit limit;

  /// EveryAI credits ran out (not an outside plan).
  final bool credits;
  final List<LeadChoice> choices;
  final ValueChanged<String> onSwitch;
  final VoidCallback onWait;

  /// For the reset time (tests).
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final resets = limit.resetsAt == null ? '' : ' (resets ${resetText(limit.resetsAt!, now ?? DateTime.now())})';
    final out = credits ? "You're out of EveryAI credits." : "You're out of $lead usage$resets.";
    final ask = switch (choices) {
      [] => 'No other harness is ready. Connect one in Settings → Code, or wait.',
      [final only] => 'Continue on ${only.label}? It gets the work so far.',
      _ => 'Continue on another harness? It gets the work so far.',
    };
    return Container(
      key: const ValueKey('lead-offer'),
      decoration: BoxDecoration(
        color: theme.surfaceRaised,
        border: Border.all(color: theme.accent.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(EveryTheme.cardRadius),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              AdaptiveIcon(EveryIcon.usage, size: 15, color: theme.warning),
              const SizedBox(width: 8),
              Expanded(child: Text(out, style: theme.type.headline.tint(theme.text))),
            ],
          ),
          const SizedBox(height: 4),
          Text(ask, style: theme.type.callout.copyWith(color: theme.textMuted, height: 1.4)),
          const SizedBox(height: 8),
          for (final c in choices)
            PopoverRow(
              key: ValueKey('lead-offer.${c.id}'),
              title: c.label,
              subtitle: c.subtitle,
              trailing: AdaptiveIcon(EveryIcon.chevronRight, size: 12, color: theme.textMuted),
              onTap: () => onSwitch(c.id),
            ),
          PopoverRow(key: const ValueKey('lead-offer.wait'), title: 'Wait', subtitle: 'Stay on $lead', onTap: onWait),
        ],
      ),
    );
  }
}

/// "15:00" today, else "Nov 5, 03:00" (local time).
String resetText(DateTime at, DateTime now) {
  final t = at.toLocal();
  final n = now.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  final clock = '${two(t.hour)}:${two(t.minute)}';
  if (t.year == n.year && t.month == n.month && t.day == n.day) return 'at $clock';
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${months[t.month - 1]} ${t.day}, $clock';
}
