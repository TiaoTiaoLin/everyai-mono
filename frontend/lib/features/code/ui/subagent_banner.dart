// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';
import '../../../core/ui/every_icons.dart';
import '../code_providers.dart';
import '../domain/code_session.dart';
import '../workflows/workflow_runs.dart';

/// What a child session is to its parent: "An agent of the Ultra workflow", else "A subagent" (a fork or a helper).
String subagentKind(WidgetRef ref, CodeSessionInfo child) {
  final parentId = child.parentId;
  if (parentId != null) {
    for (final run in ref.watch(workflowRunsProvider(parentId))) {
      if (run.agents.any((a) => a.childId == child.id)) return 'An agent of the ${run.name} workflow';
    }
  }
  return 'A subagent';
}

/// The strip at the top of a fork's, subagent's or workflow agent's chat: it says plainly that this isn't the main
/// chat, names the main chat, and goes back to it. Nothing for a session without a parent.
class SubagentBanner extends ConsumerWidget {
  const SubagentBanner({super.key, required this.session, required this.onBack});

  final CodeSessionInfo session;

  /// Back to the main chat (the parent session, or the panel's list in the parent's view).
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final parentId = session.parentId;
    if (parentId == null) return const SizedBox.shrink();
    final theme = EveryTheme.of(context);
    final parent = ref.watch(codeSessionsProvider.select((all) => all.where((s) => s.id == parentId).firstOrNull));
    final kind = subagentKind(ref, session);
    final text = parent == null ? '$kind, not the main chat' : '$kind of “${parent.title}”, not the main chat';
    return Semantics(
      button: true,
      label: '$text. Back to the main chat',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          key: const ValueKey('subagent.banner'),
          behavior: HitTestBehavior.opaque,
          onTap: onBack,
          child: Container(
            margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
            padding: const EdgeInsets.fromLTRB(10, 7, 12, 7),
            decoration: BoxDecoration(
              color: theme.accent.withValues(alpha: 0.12),
              border: Border.all(color: theme.accent.withValues(alpha: 0.5)),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                AdaptiveIcon(EveryIcon.chevronLeft, size: 14, color: theme.accent),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.type.callout.medium.tint(theme.text),
                  ),
                ),
                const SizedBox(width: 10),
                Text('Back to the main chat', style: theme.type.callout.semibold.tint(theme.accent)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
