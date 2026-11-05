// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

// The notes a user message carries when the user picks a workflow: Max on
// or off, or a script workflow started on the message's task. The lead reads
// them; the transcript strips them and shows a short chip instead.

/// Max's id in `CodeSessionInfo.workflow`.
const maxWorkflowId = 'max';

/// The bundled skill Max turns on (the max lane ships it).
const maxSkillId = 'everyai-max';

const _open = '<everyai-workflow ';
const _close = '</everyai-workflow>';

String _attr(String s) => s.replaceAll('"', "'");

/// The note the next message carries when Max is turned on or off.
/// Prompt reason: Max is an approach skill the model loads itself now, not
/// phases the harness enforces. If the skill can't be loaded the lead says so,
/// so a Max that does nothing isn't silent (issue #10).
String maxWorkflowNote({required bool on}) => on
    ? '${_open}name="$maxWorkflowId" state="on">The user turned on the Max workflow. Load the $maxSkillId skill now '
          'and follow its approach for this task and the ones after it. If you can\'t load it, tell the user in one '
          'line that Max isn\'t available in this session, then do the task your own way.$_close'
    : '${_open}name="$maxWorkflowId" state="off">The user turned the Max workflow off: stop following the '
          '$maxSkillId approach from here on.$_close';

/// The message the lead gets when the user starts workflow [id] ([title])
/// on [task]: the run goes on in the app, and its result comes back as a
/// message.
String workflowStartNoteOf(String id, String title, String task) =>
    '${_open}name="${_attr(id)}" state="started" title="${_attr(title)}">The user started the $title workflow on the '
    'task below. It runs in the app with its own agents, and its result reaches you later in a <workflow-result> '
    'message. Don\'t work on the task yourself meanwhile: reply in one short line that it started.$_close\n\n$task';

/// The message the lead gets when the workflow [title] the user started
/// couldn't start after all ([why]).
String workflowFailedNote(String id, String title, String why) =>
    '${_open}name="${_attr(id)}" state="failed" title="${_attr(title)}">The $title workflow didn\'t start: $why '
    'Work on the task from the user\'s message yourself instead.$_close';

/// Splits the workflow notes off the start of [text]: a short label for
/// each ("Max on", "Started Bug fix"), and the rest.
(List<String>, String) splitWorkflowNotes(String text) {
  final labels = <String>[];
  var rest = text;
  while (rest.startsWith(_open)) {
    final head = rest.indexOf('>');
    final end = rest.indexOf(_close);
    if (head < 0 || end < 0) break;
    final attrs = rest.substring(0, head);
    String attr(String name) => RegExp('$name="([^"]*)"').firstMatch(attrs)?[1] ?? '';
    final title = attr('title').isEmpty ? attr('name') : attr('title');
    labels.add(switch (attr('state')) {
      'on' => 'Max on',
      'off' => 'Max off',
      'failed' => '$title didn\'t start',
      _ => 'Started $title',
    });
    rest = rest.substring(end + _close.length).trimLeft();
  }
  return (labels, rest);
}
