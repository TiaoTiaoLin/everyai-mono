import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../../core/theme/every_theme.dart';
import '../../../core/ui/anchored_popover.dart';
import '../../billing/billing_providers.dart';
import '../usage_totals.dart';

/// The composer's usage readout: "12.4K · $0.031" and a ring showing how full
/// the model's context window is. Tap for the breakdown. Hidden until the
/// first call is metered.
class UsageMeter extends StatelessWidget {
  const UsageMeter({super.key, required this.totals, required this.contextWindow, this.modelName});

  final UsageTotals totals;

  /// The model's context length in tokens (0 when unknown: no ring).
  final int contextWindow;
  final String? modelName;

  double get _fill => contextWindow <= 0 ? 0 : (totals.contextTokens / contextWindow).clamp(0, 1);

  @override
  Widget build(BuildContext context) {
    if (totals.isEmpty) return const SizedBox.shrink();
    final theme = EveryTheme.of(context);
    // Credits and own-key spend together: switching to a key mid-session
    // must not freeze the figure.
    final label = '${formatTokens(totals.totalTokens)} · ${formatMicros(totals.spentMicros)}';
    return Semantics(
      button: true,
      label:
          'Usage: ${totals.totalTokens} tokens, ${formatMicros(totals.spentMicros)}'
          '${contextWindow > 0 ? ', context ${(_fill * 100).round()}% full' : ''}',
      child: AnchoredPopover(
        width: 260,
        builder: (context, close) => UsageBreakdown(totals: totals, contextWindow: contextWindow, modelName: modelName),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: theme.type.caption.copyWith(
                  color: theme.textMuted,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              if (contextWindow > 0) ...[const SizedBox(width: 6), ContextRing(fill: _fill, size: 15)],
            ],
          ),
        ),
      ),
    );
  }
}

/// A thin progress ring: violet, amber past 80%, red past 95%.
class ContextRing extends StatelessWidget {
  const ContextRing({super.key, required this.fill, this.size = 16});

  final double fill;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final color = fill >= 0.95
        ? theme.danger
        : fill >= 0.8
        ? theme.warning
        : theme.primary;
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _RingPainter(fill: fill, track: theme.border, color: color),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({required this.fill, required this.track, required this.color});

  final double fill;
  final Color track;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 2.2;
    final rect = Offset.zero & size;
    final arc = rect.deflate(stroke / 2);
    canvas.drawOval(
      arc,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = track,
    );
    if (fill <= 0) return;
    // A sliver stays visible for tiny fills.
    final sweep = math.max(fill, 0.03) * 2 * math.pi;
    canvas.drawArc(
      arc,
      -math.pi / 2,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.fill != fill || old.color != color || old.track != track;
}

/// Context fill, tokens, cache share and cost, as rows.
class UsageBreakdown extends StatelessWidget {
  const UsageBreakdown({super.key, required this.totals, required this.contextWindow, this.modelName});

  final UsageTotals totals;
  final int contextWindow;
  final String? modelName;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    Widget row(String label, String value, {bool strong = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(child: Text(label, style: theme.type.callout.tint(theme.textMuted))),
          Text(
            value,
            style: (strong ? theme.type.callout.semibold : theme.type.callout).copyWith(
              color: theme.text,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
    final pct = contextWindow <= 0 ? null : (totals.contextTokens / contextWindow * 100);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (contextWindow > 0) ...[
            Row(
              children: [
                ContextRing(fill: (totals.contextTokens / contextWindow).clamp(0, 1), size: 28),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Context ${pct! < 1 && pct > 0 ? '<1' : pct.round()}% full',
                        style: theme.type.callout.semibold.tint(theme.text),
                      ),
                      Text(
                        '${formatTokens(totals.contextTokens)} of ${formatTokens(contextWindow)}'
                        '${modelName == null ? '' : ' · $modelName'}',
                        style: theme.type.caption.tint(theme.textMuted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
          ],
          row('Input', formatTokens(totals.promptTokens)),
          if (totals.cachedTokens > 0)
            row('  from cache', '${formatTokens(totals.cachedTokens)} (${(totals.cacheShare * 100).round()}%)'),
          if (totals.cacheWriteTokens > 0) row('  written to cache', formatTokens(totals.cacheWriteTokens)),
          row('Output', formatTokens(totals.completionTokens)),
          row('Model calls', '${totals.calls}'),
          if (totals.ownKeyMicros > 0) ...[
            row('EveryAI credits', formatMicros(totals.chargedMicros)),
            row('On your own key', formatMicros(totals.ownKeyMicros)),
          ],
          // What an outside CLI did on the user's own subscription, priced as the API would charge.
          if (totals.planMicros > 0) row('On your plan', '${formatMicros(totals.planMicros)} at API prices'),
          row('Cost', formatMicros(totals.spentMicros), strong: true),
        ],
      ),
    );
  }
}
