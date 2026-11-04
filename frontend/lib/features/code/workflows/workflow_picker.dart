// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'workflow_library.dart';

// What the agent menu's Workflow page offers: Max (an approach skill the
// lead loads), the bundled script workflows, then the project's own. A
// script is armed for the next message, which becomes its task; Max stays on
// for the session. Both work the same on every harness.

/// Max's id in `CodeSessionInfo.workflow`.
const maxWorkflowId = 'max';

/// The bundled skill Max turns on (the max lane ships it).
const maxSkillId = 'everyai-max';

const maxWorkflowDescription = 'Research, ask you, plan, then build in parts, following the everyai-max approach';

/// A pick on the Workflow page: Max, or a script workflow ([entry]).
@immutable
final class WorkflowPick {
  const WorkflowPick.max() : entry = null;
  const WorkflowPick.script(WorkflowEntry this.entry);

  final WorkflowEntry? entry;

  bool get isMax => entry == null;
  String get id => entry?.id ?? maxWorkflowId;
  String get title => entry?.title ?? 'Max';

  @override
  bool operator ==(Object other) => other is WorkflowPick && other.id == id && other.entry?.digest == entry?.digest;

  @override
  int get hashCode => Object.hash(id, entry?.digest);
}

/// The one-time note the next message carries when Max is turned on or off.
/// Prompt reason: Max is an approach skill the model loads itself now, not
/// phases the harness enforces.
String maxWorkflowNote({required bool on}) => on
    ? '<everyai-workflow name="$maxWorkflowId">The user turned on the Max workflow. Load the $maxSkillId skill now '
          'and follow its approach for this task and the ones after it.</everyai-workflow>'
    : '<everyai-workflow name="$maxWorkflowId">The user turned the Max workflow off: stop following the '
          '$maxSkillId approach from here on.</everyai-workflow>';

/// The message the lead gets when the user starts [w] on [task]: the run
/// goes on in the app, and its result comes back as a message.
String workflowStartNote(WorkflowEntry w, String task) =>
    '<everyai-workflow name="${w.id}">The user started the ${w.title} workflow on the task below. It runs in the '
    'app with its own agents, and its result reaches you later in a <workflow-result> message. Don\'t work on the '
    'task yourself meanwhile: reply in one short line that it started.</everyai-workflow>\n\n$task';

/// [w]'s args for the user's [task] (what they typed after picking it).
/// The bundled ones take their own shapes; a project file gets `{task}`.
Map<String, Object?> workflowArgsFor(WorkflowEntry w, String task) {
  if (w.origin != WorkflowOrigin.bundled) return {'task': task};
  return switch (w.id) {
    'bugfix' => {'bug': task},
    // A lone git ref is the base to compare with; anything else is context the lead reads.
    'security_review' when RegExp(r'^[\w./@^~-]+$').hasMatch(task) => {'base': task},
    'security_review' => const {},
    'ultra' => {
      'items': [
        {'id': 'task', 'title': _titleOf(task), 'spec': task},
      ],
    },
    _ => {'task': task},
  };
}

String _titleOf(String task) {
  final line = task.split('\n').first.trim();
  return line.length <= 80 ? line : '${line.substring(0, 79)}…';
}

/// What the Workflow page lists for [projectDir]: the bundled and trusted
/// project workflows, and the locked project ones with why.
final workflowChoicesProvider = FutureProvider.autoDispose.family<WorkflowLibrary, String>((ref, projectDir) async {
  final trust = ref.watch(workflowTrustProvider);
  final bundled = await loadBundledWorkflows();
  List<WorkflowEntry> project;
  try {
    project = await loadProjectWorkflows(projectDir);
  } on Object {
    project = const [];
  }
  return workflowLibrary(bundled, project, trust);
});
