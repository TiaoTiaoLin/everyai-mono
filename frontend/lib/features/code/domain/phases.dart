// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

// Legacy: the Max, Ultra and Bug fix phase flow is gone (workflows and the
// everyai-max skill replaced it). What is left reads the notes old sessions
// still hold, so transcripts and handoffs keep hiding them.

export 'bug_check.dart' show bugCheckSpec, bugCheckTool;

/// A step of the old phase flow, as its notes name it.
enum Phase {
  reproduce('Reproduce'),
  triage('Triage'),
  research('Research'),
  questions('Questions'),
  plan('Plan'),
  build('Build'),
  fix('Fix'),
  verify('Verify'),
  done('Done');

  const Phase(this.label);
  final String label;

  static Phase parse(Object? s) => values.where((p) => p.name == s).firstOrNull ?? research;
}

/// The phase note at the start of [text], or null: (flow, phase, stuck, body).
({String flow, Phase phase, String run, bool stuck, String body})? parsePhaseNote(String text) {
  final m = RegExp(
    r'^<everyai-phase flow="([\w-]+)" phase="(\w+)"(?: run="([\w-]*)")?( stuck="true")?>\n([\s\S]*?)\n</everyai-phase>',
  ).firstMatch(text.trimLeft());
  if (m == null) return null;
  return (flow: m[1]!, phase: Phase.parse(m[2]), run: m[3] ?? '', stuck: m[4] != null, body: m[5]!);
}

/// The tag of the old Ultra research round's message to the lead.
const researchWorkflowTag = 'research-workflow';
