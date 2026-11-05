// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import '../../../core/api/decide_client.dart' show DecideQuestion;
import '../domain/questions.dart';

// Bug fix needs a bug to fix: a report that names no symptom ("fix it",
// "the button") gets the user asked for one before any agent runs. The
// heuristic here costs nothing; on the EveryAI harness a decide call has the
// last word.

final _symptom = RegExp(
  r"crash|error|exception|fail|throw|wrong|broken|break|hang|freez|stuck|missing|doesn'?t|does not|can'?t|cannot|"
  r"won'?t|isn'?t|instead|expect|should|null|undefined|nan\b|timeout|timed out|slow|leak|stack ?trace|\b\d{3}\b",
  caseSensitive: false,
);

/// Code-ish text: a call `foo()`, a path `a/b.dart`, a `snake_case` or `camelCase` name.
final _codeish = RegExp(r'\w\(\)|\w/\w|\w\.\w{1,5}\b|[a-z0-9]_[a-z0-9]|[a-z][A-Z]');

/// Whether [bug] is too thin to start on: empty, or short with no symptom
/// word and nothing that looks like code.
bool bugLooksVague(String bug) {
  final t = bug.trim();
  if (t.isEmpty) return true;
  if (t.length >= 40) return false;
  return !_symptom.hasMatch(t) && !_codeish.hasMatch(t);
}

/// The decide call's one question about a report (job `bug_report`): false
/// asks the user; unsure falls back to [bugLooksVague].
const bugConcreteQuestion = DecideQuestion.yesNo(
  'concrete',
  'Does the report name a concrete symptom: an error, a wrong result, a crash or hang, or what the user saw?',
);

const bugConcreteInstructions =
    'A user asked a coding agent to fix a bug and wrote the report below. Judge only whether it says what goes '
    'wrong; it need not name the cause or the steps.';

/// The card that asks for the report: what goes wrong, how to make it
/// happen and what should happen instead.
const bugQuestions = [
  Question(
    header: 'The bug',
    question: 'What goes wrong? The error, the wrong output or what you see, as exactly as you can.',
    options: [],
  ),
  Question(
    header: 'Steps',
    question: 'How do you make it happen? Steps, a command or the input.',
    options: [QuestionOption('Not sure', 'The fixer finds a way to reproduce it.')],
  ),
  Question(
    header: 'Expected',
    question: 'What should happen instead?',
    options: [QuestionOption('Not sure', 'The fixer works it out from the code.')],
  ),
];

const _answerLabels = ['What goes wrong', 'Steps to reproduce', 'Expected'];

/// [original] with the user's [answers] to [bugQuestions] after it; empty
/// answers are left out.
String bugWithAnswers(String original, List<QuestionAnswer> answers) {
  final lines = [
    if (original.trim().isNotEmpty) original.trim(),
    for (var i = 0; i < answers.length && i < bugQuestions.length; i++)
      if (answers[i].labels(bugQuestions[i]).join('; ') case final a when a.isNotEmpty) '${_answerLabels[i]}: $a',
  ];
  return lines.join('\n');
}
