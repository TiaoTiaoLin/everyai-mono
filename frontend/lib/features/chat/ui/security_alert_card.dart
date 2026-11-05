import 'package:flutter/widgets.dart';

import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/every_icons.dart';
import '../domain/message.dart';
import '../domain/security_alert.dart';

/// A `security_alert` call as a red card in the answer. The source is plain
/// text, never a link, so a hostile address can't be opened from here; the
/// card has no buttons.
class SecurityAlertCard extends StatelessWidget {
  const SecurityAlertCard({super.key, required this.part});

  final ToolCallPart part;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    final alert = SecurityAlert.of(part);
    final muted = theme.type.callout.tint(theme.textMuted);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Semantics(
        container: true,
        label: alert.severity.label,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            color: theme.danger.withValues(alpha: 0.08),
            border: Border.all(color: theme.danger.withValues(alpha: 0.55)),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  AdaptiveIcon(EveryIcon.shield, size: 15, color: theme.danger),
                  const SizedBox(width: 6),
                  Text(alert.severity.label, style: theme.type.callout.semibold.tint(theme.danger)),
                ],
              ),
              const SizedBox(height: 6),
              Text(alert.what, style: theme.type.body),
              if (alert.source case final source?) ...[const SizedBox(height: 6), Text('From: $source', style: muted)],
              if (alert.actionTaken case final action?) ...[
                const SizedBox(height: 4),
                Text('What I did: $action', style: muted),
              ],
              if (alert.exposed.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('May have been exposed', style: theme.type.callout.semibold),
                for (final e in alert.exposed)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text('• $e', style: theme.type.callout),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
