// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import '../../../questions/domain/questions.dart';
import '../../domain/transcript.dart' show planApprovedReason, planRevisionLead;
import '../../harness/events.dart';
import '../../host/host.dart' show HostResult;
import '../driver_events.dart';
import 'acp_mapping.dart' show acpToolPrefix, taskListEvents;

// Cursor CLI's ACP extensions (cursor.com/docs/cli/acp, read 2026-11-04; the
// shapes are from the doc, not yet seen on the wire) as the app's cards and
// rows, as pure functions. `cursor/ask_question` and `cursor/create_plan`
// wait for a reply, so they become the same question and plan cards as a
// call to the app's MCP host; `cursor/update_todos` is the task list and
// `cursor/task` a subagent row.

/// The most questions one card shows (`Question.listFrom` keeps 4).
const cursorMaxQuestions = 4;

/// Cursor's questions, `[{id, prompt, options:[{id, label}], allowMultiple}]`.
List<Map<String, Object?>> _questions(Map<String, Object?> params) => [
  ...(params['questions'] as List<Object?>? ?? const []).whereType<Map<String, Object?>>(),
];

List<Map<String, Object?>> _options(Map<String, Object?> q) => [
  ...(q['options'] as List<Object?>? ?? const []).whereType<Map<String, Object?>>(),
];

/// The `ask_user_question` arguments for a `cursor/ask_question` request.
/// The request's title heads the first question.
Map<String, Object?> cursorQuestionArgs(Map<String, Object?> params) {
  final title = params['title'] as String? ?? '';
  return {
    'questions': [
      for (final (i, q) in _questions(params).indexed)
        {
          'question': q['prompt'] as String? ?? '',
          'header': i == 0 ? title : '',
          'multi_select': q['allowMultiple'] == true,
          'options': [
            for (final o in _options(q)) {'label': o['label'] as String? ?? '', 'description': ''},
          ],
        },
    ],
  };
}

/// Why a `cursor/ask_question` can't be shown as a card, or null.
String? cursorQuestionProblem(Map<String, Object?> params) {
  final n = _questions(params).length;
  if (n == 0) return 'There were no questions to show.';
  if (n > cursorMaxQuestions) {
    return 'The app shows at most $cursorMaxQuestions questions at a time; ask again with $cursorMaxQuestions or fewer.';
  }
  return null;
}

/// A `skipped` reply with [reason].
Map<String, Object?> cursorSkipped(String reason) => {
  'outcome': {'outcome': 'skipped', 'reason': reason},
};

/// The `cancelled` reply, for every request nobody answers.
const cursorCancelled = {
  'outcome': {'outcome': 'cancelled'},
};

/// The reply to `cursor/ask_question` [params] once the card's host call
/// came back with [result]: the picked option ids when every answer is a
/// pick. Cursor's reply has no place for free text, so an "Other" answer or
/// a reply in chat goes back as `skipped` with the readable answer as the
/// reason; an error (the card was given up) is `cancelled`.
Map<String, Object?> cursorAnswerReply(Map<String, Object?> params, HostResult result) {
  if (result.isError) return cursorCancelled;
  final raw = _questions(params);
  final questions = Question.listFrom(cursorQuestionArgs(params));
  final answers = parseAnswers(result.text, questions);
  if (answers == null || answers.any((a) => a.other.trim().isNotEmpty)) return cursorSkipped(result.text);
  return {
    'outcome': {
      'outcome': 'answered',
      'answers': [
        for (final (i, q) in raw.indexed)
          {
            'questionId': q['id'],
            'selectedOptionIds': [
              if (i < answers.length)
                for (final o in answers[i].selected.toList()..sort())
                  if (o < _options(q).length) _options(q)[o]['id'],
            ],
          },
      ],
    },
  };
}

/// The `present_plan` arguments for a `cursor/create_plan` request: its
/// name and overview, one step per to-do (the phases' too), and the plan's
/// own Markdown as `body`, shown as Cursor wrote it.
Map<String, Object?> cursorPlanArgs(Map<String, Object?> params) {
  final todos = [
    ...(params['todos'] as List<Object?>? ?? const []).whereType<Map<String, Object?>>(),
    for (final phase in (params['phases'] as List<Object?>? ?? const []).whereType<Map<String, Object?>>())
      ...(phase['todos'] as List<Object?>? ?? const []).whereType<Map<String, Object?>>(),
  ];
  final name = params['name'] as String? ?? '';
  return {
    'title': name.trim().isEmpty ? 'Plan' : name,
    'summary': params['overview'] as String? ?? '',
    'steps': [
      for (final t in todos) {'title': t['content'] as String? ?? ''},
    ],
    'body': params['plan'] as String? ?? '',
  };
}

/// The reply to `cursor/create_plan` once the card's host call came back
/// with [result]: approved is `accepted`, a wish for changes `rejected` with
/// the user's words, anything else (given up, an error) `cancelled`.
Map<String, Object?> cursorPlanReply(HostResult result) {
  final text = result.text.trimLeft();
  if (result.isError) return cursorCancelled;
  if (text.startsWith(planApprovedReason)) {
    return {
      'outcome': {'outcome': 'accepted'},
    };
  }
  if (text.startsWith(planRevisionLead)) {
    return {
      'outcome': {'outcome': 'rejected', 'reason': text},
    };
  }
  return cursorCancelled;
}

/// Cursor's to-do list after `cursor/update_todos` [params] on [current]
/// (by id, in order): `merge` updates or adds by id, otherwise the list is
/// replaced.
Map<String, Map<String, Object?>> cursorTodos(Map<String, Map<String, Object?>> current, Map<String, Object?> params) {
  final next = params['merge'] == true ? {...current} : <String, Map<String, Object?>>{};
  for (final (i, t) in (params['todos'] as List<Object?>? ?? const []).whereType<Map<String, Object?>>().indexed) {
    final id = '${t['id'] ?? 'todo-$i'}';
    next[id] = {...?next[id], ...t};
  }
  return next;
}

/// [todos] as the app's task list, plus its result: pending is todo,
/// completed done, cancelled done with the note "cancelled".
(ActionCall, ToolResult) cursorTodoEvents(Map<String, Map<String, Object?>> todos, {required String id}) =>
    taskListEvents(
      [
        for (final t in todos.values)
          {
            'title': t['content'] as String? ?? '',
            'status': switch (t['status']) {
              'in_progress' => 'in_progress',
              'completed' || 'cancelled' => 'done',
              _ => 'todo',
            },
            'notes': t['status'] == 'cancelled' ? 'cancelled' : '',
          },
      ],
      id: id,
      toolName: '${acpToolPrefix}update_todos',
    );

/// A `cursor/task` (a subagent Cursor started) as a subagent row.
ActionCall cursorTaskCall(Map<String, Object?> params, {required String id, String? toolCallId}) {
  final type = params['subagentType'];
  return actionEvent(
    id: id,
    toolCallId: toolCallId,
    toolName: '${acpToolPrefix}task',
    kind: 'TaskAction',
    args: {
      'description': params['description'] as String? ?? '',
      'prompt': params['prompt'] as String? ?? '',
      'agent': switch (type) {
        final String s => s,
        {'custom': final String s} => s,
        _ => '',
      },
      if (params['model'] case final String m) 'model': m,
    },
  );
}

/// The result that closes a `cursor/task` row once Cursor reports its
/// duration.
String cursorTaskDone(Object? durationMs) =>
    durationMs is num ? 'Done in ${(durationMs / 1000).toStringAsFixed(durationMs < 10000 ? 1 : 0)} s.' : 'Done.';
