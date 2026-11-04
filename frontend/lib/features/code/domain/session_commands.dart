import 'package:flutter/foundation.dart';

import '../agent_models.dart' show AgentChoice;
import 'compaction.dart' show compactionModel;

/// The cheap model for side jobs such as the goal judge and commit messages
/// (the summaries' model until a routing table picks one per task). `/btw`
/// answers on the session's own model instead.
const asideModel = compactionModel;

/// Reasoning efforts a Code session can run at.
const codeEfforts = ['low', 'medium', 'high', 'xhigh', 'max'];

/// The effort named by [text]: a level from [codeEfforts], or '' for the
/// model's default (`default`, `auto`, `none`). Null when it names neither.
String? codeEffortArg(String text) {
  final t = text.trim().toLowerCase();
  if (t == 'default' || t == 'auto' || t == 'none') return '';
  if (t == 'extra' || t == 'x-high' || t == 'extra-high') return 'xhigh';
  return codeEfforts.contains(t) ? t : null;
}

/// The curated agent model best matching [query] ("sonnet", "opus high",
/// "gpt-6.1"): every word must appear in the label or the model id. When an
/// effort is named too, the choice at that effort wins; otherwise the first
/// in catalog order (the tier's recommended one).
AgentChoice? agentChoiceFor(String query, List<AgentChoice> choices) {
  final words = query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return null;
  final efforts = words.where((w) => (codeEffortArg(w) ?? '').isNotEmpty).toSet();
  final names = words.where((w) => !efforts.contains(w)).toList();
  if (names.isEmpty) return null;
  bool matches(AgentChoice c) {
    final hay = '${c.label} ${c.model}'.toLowerCase();
    return names.every(hay.contains);
  }

  final hits = choices.where(matches).toList();
  if (hits.isEmpty) return null;
  if (efforts.isNotEmpty) {
    final effort = codeEffortArg(efforts.first);
    return hits.where((c) => c.effort == effort).firstOrNull ?? hits.first;
  }
  return hits.first;
}

/// The checkpoint `/rewind [n]` restores: the files as they were before user
/// turn N (1-based), where [args] is how many of the latest turns to undo
/// (default 1). Null when there's nothing to undo or [args] isn't a count.
int? rewindTarget(int userTurns, String args) {
  if (userTurns <= 0) return null;
  final back = args.trim().isEmpty ? 1 : int.tryParse(args.trim());
  if (back == null || back < 1) return null;
  return (userTurns - back + 1).clamp(1, userTurns);
}

enum AsideKind {
  /// A side question (`/btw`) answered off to the side.
  btw,

  /// The session's usage breakdown (`/cost`).
  cost,

  /// A reviewer subagent's findings on the session's changes (`/review`).
  review,

  /// A commit message for the user to check before committing (`/commit`).
  commit,

  /// A pull request title and body to check (`/pr`), or how to open one by hand.
  pr,

  /// A skill written by `/learn`.
  learn,

  /// The brief of every session (`/morning`).
  morning,
}

/// A card shown beside the running session, never sent to the agent.
@immutable
final class Aside {
  const Aside({
    required this.id,
    required this.kind,
    this.question = '',
    this.answer = '',
    this.body = '',
    this.childId,
    this.error,
    this.busy = false,
    this.ready = false,
  });

  final int id;
  final AsideKind kind;

  /// What was asked: the question, the review focus, the skill's source.
  final String question;

  /// The result: an answer, a report, a commit message or a pull request title.
  final String answer;

  /// A pull request's body.
  final String body;

  /// The session doing the work (a reviewer subagent), to open it.
  final String? childId;
  final String? error;
  final bool busy;

  /// A draft the user can act on (commit, open the pull request); false for
  /// instructions or a result.
  final bool ready;

  Aside done(String answer, {String body = '', bool ready = false}) =>
      Aside(id: id, kind: kind, question: question, answer: answer, body: body, childId: childId, ready: ready);
  Aside failed(String error) => Aside(id: id, kind: kind, question: question, childId: childId, error: error);
  Aside withChild(String childId) =>
      Aside(id: id, kind: kind, question: question, childId: childId, busy: busy, answer: answer);
}

/// The side model's messages (OpenAI chat format): what it is for, the
/// session [record] so far, then the user's [question].
List<Map<String, Object?>> btwRequest({required String record, required String question}) => [
  {'role': 'system', 'content': _btwSystem},
  {
    'role': 'user',
    'content':
        '<session-record>\n${record.trim().isEmpty ? '(nothing has happened yet)' : record.trim()}\n</session-record>\n\n'
        'Side question: ${question.trim()}',
  },
];

/// Written for this app: the side model reads the record of a coding session
/// that keeps running, answers one question about it, and never acts.
const _btwSystem = '''
You answer a quick side question from a developer whose coding agent is still at work. The record of the agent's session so far is below: their messages, the agent's replies, its tool calls and shortened results.

- Answer the question from the record and from general knowledge. Keep it short: a few sentences or a small list.
- You can't run tools, read files or talk to the agent, and your answer doesn't reach it. Don't offer to do things.
- If the record doesn't show something, say so instead of guessing what the agent did.
- Use Markdown sparingly; code in backticks.''';
