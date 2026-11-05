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
/// the user closed comes back for a new window or the next step (see
/// [limitBannerClosed]).
typedef LimitBannerInfo = ({String key, String text, bool danger});

/// The banner above the composer, or null for none. A plan limit the
/// harness reported ([plan], its fullest window that hasn't reset yet)
/// comes first: "Limit reached" once it is all used; "On pace to hit your
/// limit early" when at least a quarter is used and more than the share of
/// the window gone by (known only when the harness gives the window's
/// length and reset); otherwise "Close to your limit" when the harness
/// warns. Then the session's spending cap ([budgetUsd]), from 80% as the
/// usage meter turns amber. Only reported numbers that still hold are shown.
LimitBannerInfo? limitBannerOf({PlanLimits? plan, int chargedMicros = 0, double? budgetUsd, required DateTime now}) {
  // A window whose reset has passed says nothing about now (a report replayed on reopen, or none since).
  final windows = [
    for (final w in plan?.windows ?? const <PlanWindow>[])
      if (w.resetsAt == null || w.resetsAt!.isAfter(now)) w,
  ]..sort((a, b) => b.used.compareTo(a.used));
  if (windows.firstOrNull case final w?) {
    final at = w.resetsAt;
    final minutes = w.minutes;
    final elapsed = at == null || minutes == null || minutes <= 0
        ? null
        : (1 - at.difference(now).inSeconds / (minutes * 60)).clamp(0.0, 1.0);
    final full = w.used >= 1;
    final headline = full
        ? 'Limit reached'
        : elapsed != null && w.used >= 0.25 && w.used > elapsed
        ? 'On pace to hit your limit early'
        : plan!.warning
        ? 'Close to your limit'
        : null;
    if (headline != null) {
      return (
        key: 'plan:${w.name}:${full ? 'full' : 'near'}${at == null ? '' : '@${at.millisecondsSinceEpoch ~/ 1000}'}',
        text: [
          headline,
          if (!full) '${(w.used * 100).round()}% used',
          if (at != null) 'resets ${resetText(at, now)}',
        ].join(' · '),
        danger: full,
      );
    }
  }
  final fill = budgetFill(chargedMicros, budgetUsd);
  if (fill == null || fill < 0.8) return null;
  final cap = formatMicros((budgetUsd! * 1e6).round());
  // The cap is in the key: a banner closed under one cap comes back near a new one.
  if (fill >= 1) return (key: 'budget:100:$budgetUsd', text: 'Session cap reached · $cap', danger: true);
  return (key: 'budget:80:$budgetUsd', text: '${(fill * 100).floor()}% of your $cap session cap used', danger: false);
}

/// Whether [stored], the key of the banner the user closed, still covers
/// [key]: the same step of the same window. Harnesses report a window's reset
/// a second or so apart between updates (Codex works it out from the time
/// left), so resets up to 10 minutes apart are the same window.
bool limitBannerClosed(String? stored, String key) {
  if (stored == null) return false;
  if (stored == key) return true;
  final a = stored.split('@');
  final b = key.split('@');
  if (a.length != 2 || b.length != 2 || a.first != b.first) return false;
  final x = int.tryParse(a.last);
  final y = int.tryParse(b.last);
  return x != null && y != null && (x - y).abs() <= 600;
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
    if (info == null || limitBannerClosed(prefs[_key], info.key)) return const SizedBox.shrink();
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
