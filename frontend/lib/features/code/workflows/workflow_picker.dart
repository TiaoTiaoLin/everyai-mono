// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'workflow_library.dart';
import 'workflow_notes.dart';

export 'workflow_notes.dart';

// What the agent menu's Workflow page offers: Max (an approach skill the
// lead loads), the bundled script workflows, then the project's own. A
// script is armed for the next message, which becomes its task; Max stays on
// for the session. Both work the same on every harness.

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

/// The message the lead gets when the user starts [w] on [task].
String workflowStartNote(WorkflowEntry w, String task) => workflowStartNoteOf(w.id, w.title, task);

/// [w]'s args for the user's [task] (what they typed after picking it,
/// with the paths of any files attached). The bundled ones take their own
/// shapes; a project file gets `{task}`. For Security review, [gitRef] says
/// the task is a ref the project has (the base to compare with); any other
/// text is the focus its agents read.
Map<String, Object?> workflowArgsFor(WorkflowEntry w, String task, {bool gitRef = false}) {
  if (w.origin != WorkflowOrigin.bundled) return {'task': task};
  return switch (w.id) {
    'bugfix' => {'bug': task},
    'security_review' when gitRef => {'base': task},
    'security_review' when task.isEmpty => const {},
    'security_review' => {'focus': task},
    // Ultra's first agent splits it into independent items.
    _ => {'task': task},
  };
}

/// Text that could be a git ref on its own (one word, ref characters only).
bool looksLikeRef(String task) => RegExp(r'^[\w./@^~-]+$').hasMatch(task);

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
