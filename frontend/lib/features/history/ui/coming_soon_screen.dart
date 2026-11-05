import 'package:flutter/widgets.dart';

import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/layout.dart';
import '../../../core/ui/adaptive_page.dart';
import '../../../core/ui/every_icons.dart';

/// Placeholder for destinations on the roadmap (Projects, Artifacts), so the
/// navigation is in place before the features land.
class ComingSoonScreen extends StatelessWidget {
  const ComingSoonScreen({super.key, required this.title, required this.icon, required this.message});

  final String title;
  final EveryIcon icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return AdaptivePage(
      title: title,
      body: CenteredScroll(
        maxWidth: 420,
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AdaptiveIcon(icon, size: 44, color: theme.accent),
            const SizedBox(height: 16),
            Text(title, style: theme.type.title.tint(theme.text)),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.type.body.copyWith(color: theme.textMuted, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}
