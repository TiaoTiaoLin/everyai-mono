import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/ui/adaptive.dart';
import '../../models/models_providers.dart';
import '../../slash/chat_actions.dart' show modelForQuery;
import '../../slash/slash_command.dart';
import '../agent_models.dart';
import '../code_providers.dart';
import '../morning_providers.dart';
import '../domain/agent_mode.dart';
import '../domain/goal.dart';
import '../domain/rewind.dart';
import '../domain/session_commands.dart';
import '../domain/transcript.dart';

/// Moves session [sessionId] to [model] and/or [effort] live (`switch_llm`)
/// and toasts the outcome: `/model`, `/effort` and the agent menu.
Future<void> switchCodeAgent(
  BuildContext context,
  WidgetRef ref,
  String sessionId, {
  String? model,
  String? effort,
}) async {
  void toast(String message) {
    if (context.mounted && message.isNotEmpty) showAdaptiveToast(context, message);
  }

  try {
    toast(await ref.read(codeSessionProvider(sessionId).notifier).switchModel(model: model, effort: effort));
  } on Object catch (e) {
    toast("Couldn't switch: $e");
  }
}

/// Wires the Code session commands to session [sessionId]. Callbacks that
/// need the screen ([context]) check it is still mounted after each await.
CodeSlashHost codeSlashHost(BuildContext context, WidgetRef ref, String sessionId, {required bool busy}) {
  final provider = codeSessionProvider(sessionId);
  CodeSessionController controller() => ref.read(provider.notifier);
  void toast(String message) {
    if (context.mounted && message.isNotEmpty) showAdaptiveToast(context, message);
  }

  Future<void> switchTo({String? model, String? effort}) =>
      switchCodeAgent(context, ref, sessionId, model: model, effort: effort);

  return CodeSlashHost(
    setMode: (name) => controller().setMode(AgentMode.values.byName(name)),
    stop: busy ? controller().stop : null,
    build: (args) async {
      final state = ref.read(provider);
      if (args.isNotEmpty) {
        await controller().setMode(AgentMode.autoEdit);
        await controller().send(args);
      } else if (state.mode == AgentMode.plan || state.transcript.openPlan != null) {
        await controller().startBuilding();
      } else {
        await controller().setMode(AgentMode.autoEdit);
        toast('Auto-edit mode: send what to build.');
      }
    },
    setModel: (query) {
      final choice = agentChoiceFor(query, ref.read(agentCatalogProvider).models);
      // Auto is a chat router; a Code session needs a concrete model.
      final spec = choice == null
          ? switch (modelForQuery(ref.read(modelCatalogProvider), query)) {
              final s? when !s.isAuto => s,
              _ => null,
            }
          : null;
      if (choice == null && spec == null) return toast('No model matches "$query".');
      switchTo(model: choice?.model ?? spec!.id.value, effort: choice?.effort);
    },
    setEffort: (arg) {
      final effort = codeEffortArg(arg);
      if (effort == null) return toast('Pick one: low, medium, high, xhigh, max or default.');
      switchTo(effort: effort);
    },
    clear: (args) async {
      final sessions = ref.read(codeSessionsProvider.notifier);
      final info = sessions.byId(sessionId);
      final project = ref.read(codeProjectsProvider).where((p) => p.id == info?.projectId).firstOrNull;
      if (info == null || project == null || args.isEmpty) {
        if (context.mounted) context.go(Routes.code);
        return;
      }
      try {
        final next = await sessions.start(
          project: project,
          prompt: args,
          model: info.model,
          effort: info.effort.isEmpty ? null : info.effort,
          mode: ref.read(provider).mode,
          // The same lead: an outside CLI's model id means nothing to another harness.
          harness: info.harness,
        );
        if (context.mounted) context.go(Routes.codeSession(next.id));
      } on Object catch (e) {
        toast("Couldn't start the session: $e");
      }
    },
    compact: (focus) async {
      toast('Compacting the session…');
      final outcome = await controller().compact(focus: focus);
      toast(switch (outcome.kind) {
        CompactKind.compacted => 'Compacted: older turns are now a summary.',
        CompactKind.nothing => 'Nothing to compact yet.',
        CompactKind.busy => 'The agent is busy; compact when it stops.',
        CompactKind.failed => "Couldn't compact: ${outcome.message}",
      });
    },
    rewind: (args) async {
      final info = ref.read(codeSessionsProvider.notifier).byId(sessionId);
      final turns = ref.read(provider).transcript.items.whereType<UserTurn>().length;
      final turn = rewindTarget(turns, args);
      if (turn == null) return toast(turns == 0 ? 'Nothing to rewind yet.' : 'Give a number of turns: /rewind 2');
      final back = turns - turn + 1;
      final ok = await showAdaptiveConfirm(
        context,
        title: 'Rewind?',
        message: rewindPrompt(
          back == 1 ? 'your last message' : 'your last $back messages',
          files: info?.worktree != null,
        ),
        confirmLabel: 'Rewind',
        destructive: true,
      );
      if (!ok) return;
      toast((await controller().rewind(turn)).label);
    },
    cost: () => controller().showCost(),
    skipPhase: () => controller().skipPhase(),
    btw: (question) => controller().askAside(question),
    review: (focus) => controller().review(focus),
    goal: (args) {
      final current = ref.read(provider).goal;
      final word = args.trim().toLowerCase();
      if (word.isEmpty) {
        return toast(current == null ? 'Set one: /goal make the tests pass --turns 10' : current.statusLabel);
      }
      if (const {'clear', 'stop', 'off', 'cancel', 'none'}.contains(word)) {
        if (current == null) return toast('There is no goal to clear.');
        controller().clearGoal();
        return toast('Goal cleared');
      }
      final goal = parseGoalArgs(args);
      if (goal == null) return toast('Say what the goal is: /goal make the tests pass');
      controller().setGoal(goal.objective, budget: goal.budget);
    },
    commit: (hint) => controller().draftCommit(hint),
    pr: (hint) => controller().draftPr(hint),
    learn: (args) => controller().learn(args),
    morning: () => ref.read(morningBriefProvider.notifier).refresh(),
  );
}
