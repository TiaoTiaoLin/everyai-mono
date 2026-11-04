// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter/widgets.dart';

import '../../../../core/theme/every_theme.dart';
import '../../../../core/ui/adaptive.dart';
import '../../../../core/ui/anchored_popover.dart' show PopoverRow;
import '../../../../core/ui/every_icons.dart';
import '../../drivers/usage_limit.dart';

/// A harness the session can carry on with: its id, name, and the model it
/// would use with how it is paid ("Sonnet 5.5 · credits"). [blocked] says
/// what is in the way and how to fix it; such a row is greyed.
typedef LeadChoice = ({String id, String label, String subtitle, String? blocked});

/// The lead ran out of usage: "Your X limit ran out, switch to:" with the
/// harnesses found here ([choices]; the blocked ones greyed with the fix),
/// a "make this my default handoff" box, and Wait. The session's files, plan
/// and checklist go with it. With [change] (reopened after an automatic
/// handoff) Wait is "Keep" [current].
class LeadOfferCard extends StatefulWidget {
  const LeadOfferCard({
    super.key,
    required this.lead,
    required this.limit,
    required this.choices,
    required this.onSwitch,
    required this.onWait,
    this.current = '',
    this.credits = false,
    this.change = false,
    this.problem = '',
    this.now,
  });

  /// The harness that ran out, by name.
  final String lead;

  /// The harness the session runs on now, by name (for "Keep" in the [change] case).
  final String current;
  final UsageLimit limit;

  /// EveryAI credits ran out (not an outside plan).
  final bool credits;
  final bool change;

  /// Why the automatic handoff didn't happen, or ''.
  final String problem;
  final List<LeadChoice> choices;

  /// The pick, and whether to make it the default handoff.
  final void Function(String id, bool makeDefault) onSwitch;
  final VoidCallback onWait;

  /// For the reset time (tests).
  final DateTime? now;

  @override
  State<LeadOfferCard> createState() => _LeadOfferCardState();
}

class _LeadOfferCardState extends State<LeadOfferCard> {
  bool _makeDefault = false;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final w = widget;
    final title = w.credits ? 'Your EveryAI credits ran out, switch to:' : 'Your ${w.lead} limit ran out, switch to:';
    final ready = w.choices.where((c) => c.blocked == null);
    final at = w.limit.resetsAt;
    final wait = w.change
        ? 'Keep ${w.current}'
        : at == null
        ? 'Wait'
        : 'Wait until ${resetText(at, w.now ?? DateTime.now())}';
    final muted = theme.type.callout.copyWith(color: theme.textMuted, height: 1.4);
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
              Expanded(child: Text(title, style: theme.type.headline.tint(theme.text))),
            ],
          ),
          if (w.limit.message.trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(w.limit.message.trim(), style: muted),
          ],
          if (w.problem.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(w.problem, key: const ValueKey('lead-offer.problem'), style: muted),
          ],
          if (ready.isEmpty) ...[
            const SizedBox(height: 4),
            Text('No other harness is ready. Connect one in Settings → Code, or wait.', style: muted),
          ],
          const SizedBox(height: 8),
          for (final c in w.choices)
            PopoverRow(
              key: ValueKey('lead-offer.${c.id}'),
              title: c.label,
              subtitle: c.blocked ?? c.subtitle,
              trailing: c.blocked == null
                  ? AdaptiveIcon(EveryIcon.chevronRight, size: 12, color: theme.textMuted)
                  : null,
              onTap: c.blocked == null ? () => w.onSwitch(c.id, _makeDefault) : null,
            ),
          if (ready.isNotEmpty) _DefaultBox(value: _makeDefault, onChanged: (v) => setState(() => _makeDefault = v)),
          PopoverRow(
            key: const ValueKey('lead-offer.wait'),
            title: wait,
            subtitle: w.change ? null : 'Stay on ${w.lead}',
            onTap: w.onWait,
          ),
        ],
      ),
    );
  }
}

/// "Make this my default handoff": later limits move on to the pick by themselves.
class _DefaultBox extends StatelessWidget {
  const _DefaultBox({required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Semantics(
      checked: value,
      button: true,
      child: GestureDetector(
        key: const ValueKey('lead-offer.default'),
        behavior: HitTestBehavior.opaque,
        onTap: () => onChanged(!value),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 10, 6),
            child: Row(
              children: [
                Container(
                  width: 16,
                  height: 16,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: value ? theme.primary : null,
                    border: Border.all(color: value ? theme.accent : theme.border, width: 1.5),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: value ? AdaptiveIcon(EveryIcon.check, size: 11, color: theme.onPrimary) : null,
                ),
                const SizedBox(width: 8),
                Text('Make this my default handoff', style: theme.type.callout.tint(theme.text)),
              ],
            ),
          ),
        ),
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
  if (t.year == n.year && t.month == n.month && t.day == n.day) return clock;
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${months[t.month - 1]} ${t.day}, $clock';
}
