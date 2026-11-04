// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

// EveryAI spends nothing (no credits, no BYOK key, no utility model) on a
// Code session it doesn't lead: an outside harness (Claude Code, Codex, …)
// runs on the user's own plan. The side jobs that would ask an EveryAI model
// are off there, with these reasons, or done without a model. The audit is
// in docs/research/batches/multi-harness/run3/no-spend.md.

/// `/btw` on an outside lead [lead].
String btwOff(String lead) =>
    '/btw asks an EveryAI model, and EveryAI spends nothing while $lead leads this session. Ask $lead in the '
    'chat instead.';

/// Why a goal stops being judged after the lead moved to outside harness
/// [lead] while a check was due.
String goalOff(String lead) =>
    'Goals are checked by an EveryAI model after each turn, and EveryAI spends nothing while $lead leads this '
    'session. Tell $lead the goal in a message instead.';

/// `/goal` on an outside lead: no EveryAI judge reads the session after each
/// turn, so the first message asks the lead to check the goal itself.
String goalLeadMessage(String objective) =>
    'Goal: ${objective.trim()}\n\n'
    'Work toward this until it is done and verified. Before you say it is met, call the goal_check tool of the '
    'everyai MCP server and have the goal judged as its result says; if it is not met, keep going.';

/// The goal's note on an outside lead.
const goalByLeadNote = 'The lead checks this goal itself (goal_check); EveryAI asks no model.';

/// `/learn` (writing a skill) on an outside lead [lead]. A folder that
/// already holds skills is imported without a model.
String learnOff(String lead) =>
    'Writing a skill uses an EveryAI model, and EveryAI spends nothing while $lead leads this session. You can '
    'still import a folder that already holds skills, or ask $lead to write one.';
