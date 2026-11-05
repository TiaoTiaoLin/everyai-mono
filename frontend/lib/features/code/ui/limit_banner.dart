import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/preferences.dart';
import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/every_icons.dart';
import '../../billing/billing_providers.dart' show formatMicros;
import '../../usage/usage_totals.dart';
import '../code_providers.dart' show codeUsageProvider;
import '../code_settings_providers.dart' show codeSettingsProvider;
import '../harness/events.dart';
import '../limit_providers.dart';
import '../settings/code_settings.dart' show budgetFill;
import 'transcript/lead_offer_card.dart' show resetText;

/// What the limit banner says: [key] names the step it is at, so a banner
/// the user closed comes back for a new window or the next step.
typedef LimitBannerInfo = ({String key, String text, bool danger});

/// The banner above the composer, or null for none. A plan limit the
/// harness reported ([plan], its fullest window) comes first: "On pace to
/// hit your limit early" when at least a quarter is used and more than the
/// share of the window gone by (known only when the harness gives the
/// window's length and reset), otherwise "Close to your limit" when the
/// harness warns. Then the session's spending cap ([budgetUsd]), from 80%
/// as the usage meter turns amber. Only reported numbers are shown.
LimitBannerInfo? limitBannerOf({PlanLimits? plan, int chargedMicros = 0, double? budgetUsd, required DateTime now}) {
  final windows = [...?plan?.windows]..sort((a, b) => b.used.compareTo(a.used));
  if (windows.firstOrNull case final w?) {
    final at = w.resetsAt;
    final minutes = w.minutes;
    final elapsed = at == null || minutes == null || minutes <= 0
        ? null
        : (1 - at.difference(now).inSeconds / (minutes * 60)).clamp(0.0, 1.0);
    final headline = elapsed != null && w.used >= 0.25 && w.used > elapsed
        ? 'On pace to hit your limit early'
        : plan!.warning
        ? 'Close to your limit'
        : null;
    if (headline != null) {
      return (
        key: 'plan:${w.name}:${at == null ? '' : at.millisecondsSinceEpoch ~/ 1000}',
        text: [headline, '${(w.used * 100).round()}% used', if (at != null) 'resets ${resetText(at, now)}'].join(' · '),
        danger: w.used >= 1,
      );
    }
  }
  final fill = budgetFill(chargedMicros, budgetUsd);
  if (fill == null || fill < 0.8) return null;
  final cap = formatMicros((budgetUsd! * 1e6).round());
  if (fill >= 1) return (key: 'budget:100', text: 'Session cap reached · $cap', danger: true);
  return (key: 'budget:80', text: '${(fill * 100).floor()}% of your $cap session cap used', danger: false);
}

/// [limitBannerOf] for session [sessionId], above its composer; the × hides
/// it until the next step (kept in Preferences `code.limit_banner.<id>`).
class LimitBanner extends ConsumerStatefulWidget {
  const LimitBanner({super.key, required this.sessionId, this.now = DateTime.now});

  final String sessionId;

  /// The clock the pace is read against.
  final DateTime Function() now;

  @override
  ConsumerState<LimitBanner> createState() => _LimitBannerState();
}

class _LimitBannerState extends ConsumerState<LimitBanner> {
  String get _key => '$codeLimitBannerPrefix${widget.sessionId}';

  @override
  Widget build(BuildContext context) {
    final id = widget.sessionId;
    final totals = ref.watch(codeUsageProvider(id)).value ?? UsageTotals.zero;
    final info = limitBannerOf(
      plan: ref.watch(codePlanLimitsProvider(id)),
      chargedMicros: totals.chargedMicros,
      budgetUsd: ref.watch(codeSettingsProvider.select((s) => s.budgets[id])),
      now: widget.now(),
    );
    final prefs = ref.read(preferencesProvider);
    if (info == null || prefs[_key] == info.key) return const SizedBox.shrink();
    final theme = EveryTheme.of(context);
    final color = info.danger ? theme.danger : theme.warning;
    return Padding(
      key: const ValueKey('limit-banner'),
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 2, 2, 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          border: Border.all(color: color.withValues(alpha: 0.35)),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            AdaptiveIcon(EveryIcon.usage, size: 13, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                info.text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.type.caption.tint(theme.text),
              ),
            ),
            AdaptiveIconButton(
              key: const ValueKey('limit-banner.dismiss'),
              icon: EveryIcon.close,
              tooltip: 'Dismiss',
              size: 12,
              color: theme.textMuted,
              onPressed: () => setState(() => prefs[_key] = info.key),
            ),
          ],
        ),
      ),
    );
  }
}
