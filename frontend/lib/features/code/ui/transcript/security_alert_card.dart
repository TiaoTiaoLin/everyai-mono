import 'package:flutter/widgets.dart';

import '../../../../core/theme/every_theme.dart';
import '../../../../core/ui/adaptive.dart';
import '../../../../core/ui/every_icons.dart';
import '../../domain/transcript.dart';

/// A `security_alert` the agent raised: red, plain text (the fields are the
/// model's words, perhaps quoting hostile content, so nothing in them is a
/// link or Markdown), and no buttons. The user answers by writing.
class SecurityAlertCard extends StatelessWidget {
  const SecurityAlertCard({super.key, required this.item});

  final SecurityAlert item;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final muted = theme.type.footnote.tint(theme.textMuted);
    final label = switch (item.severity) {
      AlertSeverity.critical => 'Security alert · critical',
      AlertSeverity.warning => 'Security alert',
      AlertSeverity.info => 'Security note',
    };
    return Container(
      decoration: BoxDecoration(
        color: theme.danger.withValues(alpha: 0.08),
        border: Border.all(color: theme.danger.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(EveryTheme.cardRadius),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AdaptiveIcon(EveryIcon.shield, size: 16, color: theme.danger),
              const SizedBox(width: 8),
              Text(label, style: theme.type.caption.semibold.tint(theme.danger)),
            ],
          ),
          const SizedBox(height: 6),
          Text(item.what, style: theme.type.body),
          if (item.source.isNotEmpty) ...[const SizedBox(height: 4), Text('From: ${item.source}', style: muted)],
          if (item.actionTaken.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('What the agent did: ${item.actionTaken}', style: muted),
          ],
          if (item.exposed.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('May have been exposed', style: theme.type.caption.semibold.tint(theme.danger)),
            for (final e in item.exposed) Text('• $e', style: theme.type.callout),
          ],
          if (item.stopRun) ...[
            const SizedBox(height: 8),
            Text('The run stopped. It waits for your reply.', style: theme.type.callout.semibold),
          ],
        ],
      ),
    );
  }
}
