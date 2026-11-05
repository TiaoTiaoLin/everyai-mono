// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/every_theme.dart';
import '../../code_providers.dart';
import '../../domain/floor_advice.dart';
import 'approval_card.dart';

/// The approval card of session [sessionId], answered on that session's own
/// controller: in its own view, in the right panel's view of it, and in its
/// parent's chat (a fork waiting on the user). Nothing while it waits on none.
/// [label] goes above the card (which fork asks).
class SessionApprovalCard extends ConsumerWidget {
  const SessionApprovalCard({super.key, required this.sessionId, this.label});

  final String sessionId;
  final String? label;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(codeSessionsProvider.select((all) => all.where((s) => s.id == sessionId).firstOrNull));
    final state = ref.watch(codeSessionProvider(sessionId));
    final pending = state.transcript.pending;
    if (info == null || pending.isEmpty) return const SizedBox.shrink();
    final controller = ref.read(codeSessionProvider(sessionId).notifier);
    final theme = EveryTheme.of(context);
    final card = ApprovalCard(
      key: ValueKey(pending.map((c) => c.id).join()),
      pending: pending,
      mode: state.mode,
      onAllow: controller.approve,
      onDeny: controller.deny,
      onMode: controller.setMode,
      remember: controller.rememberable(),
      // None for the demo (its commands never run) or an outside lead (no EveryAI spend).
      workingDir: riskLabelDir(info),
      session: info.billingTag,
      decided: state.decided,
      rememberBy: controller.rememberBy(),
      onAllowCall: controller.perCall ? (id, scope) => controller.approve(scope, [id]) : null,
      onDenyCall: controller.perCall ? (id) => controller.deny(null, [id]) : null,
      flags: approvalFlags(controller.policy, pending, state.mode),
    );
    if (label == null) return card;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 4),
          child: Text(
            label!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.type.caption.semibold.tint(theme.warning),
          ),
        ),
        card,
      ],
    );
  }
}

/// The approval cards of [parentId]'s forks and subagents that wait on the
/// user, in the parent's chat: a fork's request no longer sits unseen in its
/// own view. Only children with a live controller can be waiting.
class ChildApprovals extends ConsumerWidget {
  const ChildApprovals({super.key, required this.parentId});

  final String parentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final children = ref.watch(
      codeSessionsProvider.select(
        (all) => [
          for (final s in all)
            if (s.parentId == parentId) (id: s.id, title: s.title),
        ],
      ),
    );
    final waiting = [
      for (final c in children)
        if (ref.exists(codeSessionProvider(c.id)) &&
            ref.watch(codeSessionProvider(c.id).select((s) => s.transcript.pending.isNotEmpty)))
          c,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final c in waiting)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SessionApprovalCard(
              key: ValueKey('child-approval-${c.id}'),
              sessionId: c.id,
              label: '"${c.title}" is waiting for your approval',
            ),
          ),
      ],
    );
  }
}
