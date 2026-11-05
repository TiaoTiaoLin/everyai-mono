// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import '../drivers/briefing/session_skill.dart' show HostToolInfo;
import '../domain/subagents.dart'
    show
        SubagentTask,
        answerForkSpec,
        answerForkTool,
        checkForksSpec,
        checkForksTool,
        forkTools,
        stopForkSpec,
        stopForkTool,
        subagentBrief;
import 'host.dart';

// The Max approach's tools for every harness (the `everyai-max` skill):
// start forks on the lead's own harness, watch them, answer their questions
// and stop them. The EveryAI harness has the same tools as client tools
// (`run_subagent` in the background, check_forks, answer_fork, stop_fork).

/// Starts a background fork.
const forkHostTool = 'fork';

/// The Max tools the host offers, by name.
const maxHostTools = {forkHostTool, ...forkTools};

/// [forkHostTool]'s spec (OpenAI shape, like the fork tools it lists with).
const forkSpec = <String, Object?>{
  'name': forkHostTool,
  'description':
      'Start a fork: a new agent on your harness (or `harness`) that works on `task` in the background and reports '
      'when done. It sees nothing of this conversation, so the task must stand alone: the goal, the files, the '
      'conventions to keep and how to check the work. Returns at once with the fork\'s id. Its report arrives later '
      'as an <everyai-notice> holding a <task-notification>, and a question from it as a <fork-question> in one; '
      'don\'t sleep or poll for them. At most 4 run at once, and forks can\'t start forks. It runs on the user\'s own plan for that harness.',
  'parameters': {
    'type': 'object',
    'properties': {
      'task': {'type': 'string', 'description': 'Self-contained instructions for the fork'},
      'title': {'type': 'string', 'description': 'A few words for the user, e.g. "Add the settings page"'},
      'harness': {'type': 'string', 'description': 'Another harness id to run it on; leave out for your own'},
      'model': {'type': 'string', 'description': 'A model of that harness; leave out for its default'},
      'worktree': {
        'type': 'boolean',
        'description': 'Work in its own git worktree, merged back when it completes (default: the user\'s setting)',
      },
    },
    'required': ['task'],
  },
  'annotations': {'readOnlyHint': false, 'destructiveHint': false},
};

/// The Max tools' specs in their fixed order (the host lists them so).
const maxForkSpecs = [forkSpec, checkForksSpec, answerForkSpec, stopForkSpec];

/// What the session text tells an outside agent about each Max tool.
const maxHostToolInfos = <HostToolInfo>[
  (
    name: forkHostTool,
    when:
        'a step of the plan stands on its own: a fork does it in the background (in its own worktree when asked) '
        'and its report comes as an <everyai-notice> holding a <task-notification>.',
  ),
  (name: checkForksTool, when: 'you want to see how your forks are doing.'),
  (name: answerForkTool, when: 'a <fork-question> reached you.'),
  (name: stopForkTool, when: 'a fork is stuck, looping or off its task.'),
];

/// Why an outside lead can't fork on the EveryAI harness: that would spend
/// EveryAI credits in a session EveryAI doesn't lead.
String forkOnEveryaiOff(String lead) =>
    'Error: a fork on the EveryAI harness would spend EveryAI credits, and EveryAI spends nothing while $lead leads '
    'this session. Leave out harness to fork on $lead.';

/// A host fork's first message: the task, and what a fork is. An outside
/// CLI gets no subagent rules in its prompt, so they come with the task.
String hostForkBrief(SubagentTask task) =>
    '${subagentBrief(task)}\n\n'
    'You are a fork: another agent started you for this task, and your final message is your report to it. End '
    'with what you did, what you checked and anything left. If something only that agent or the user can decide '
    'blocks you, ask with ask_user_question (it reaches that agent). Don\'t start forks, and don\'t present a '
    'plan: your task is a step of one.';

/// What a session offers for the Max tools; the session controller
/// implements it.
abstract interface class HostForks {
  /// Checks and starts a fork, and returns at once.
  Future<HostResult> startFork(HostCall call);

  /// check_forks, answer_fork or stop_fork, as the EveryAI harness answers them.
  Future<String> forkTool(String name, Map<String, Object?> args);
}

/// Answers a Max tool [call] (one of [maxHostTools]) through [forks].
Future<HostResult> maxHostCall(HostForks forks, HostCall call) async {
  try {
    if (call.name == forkHostTool) return await forks.startFork(call);
    final out = await forks.forkTool(call.name, call.args);
    return (text: out, isError: out.startsWith('Error'));
  } on Object catch (e) {
    return (text: 'Error: $e', isError: true);
  }
}
