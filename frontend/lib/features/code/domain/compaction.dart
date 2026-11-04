// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../harness/events.dart';
import '../settings/context_files.dart' show splitContextNotes;
import 'agent_mode.dart';
import 'rewind.dart' show splitRewindNote;

// Compaction for Code sessions.
//
// OpenHands 1.59 offers only `LLMSummarizingCondenser` (its own fixed prompt),
// `NoOpCondenser` and `PipelineCondenser`: no prompt of our own and no way to
// clear old tool results without a model call. So the app compacts by itself:
//
//  1. prune: old tool output in the span being summarized is cleared, newer
//     output is cut short (no model call);
//  2. summarize that span with a cheap model through the gateway, in the
//     template below (merging the previous summary, if any);
//  3. start a continuation conversation whose first message is the summary
//     plus the newest turns word for word. Its system prompt and tools are the
//     same as before, so the cached prefix still holds.

/// The model that writes summaries (until the cheap-model routing table lands).
const compactionModel = 'anthropic/claude-haiku-5.5';

/// Marks the first message of a continuation conversation.
const compactedOpen = '<everyai-compacted>';
const compactedClose = '</everyai-compacted>';
const _summaryOpen = '<summary>';
const _summaryClose = '</summary>';
const _recentOpen = '<recent-turns>';
const _recentClose = '</recent-turns>';

/// Opens and closes a handoff message, the facts a new lead of a session
/// gets (see `handoffMessage`).
const handoffOpen = '<everyai-handoff';
const handoffClose = '</everyai-handoff>';

/// [text] (mode and context notes already split off) without the handoff
/// block it starts with: (the block or null, the rest). A driver records the
/// handoff it sent as a user message, so the next handoff and the transcript
/// read only what the user wrote.
(String?, String) splitHandoff(String text) {
  final t = text.trimLeft();
  if (!t.startsWith(handoffOpen)) return (null, text);
  final end = t.indexOf(handoffClose);
  if (end < 0) return (t, '');
  return (t.substring(0, end + handoffClose.length), t.substring(end + handoffClose.length).trim());
}

/// Shown in place of tool output the summary doesn't need.
const clearedOutput = '[old tool output cleared]';

/// Budgets, in characters (about four per token).
@immutable
final class CompactionBudget {
  const CompactionBudget({
    this.tail = 48000,
    this.protectedOutput = 160000,
    this.outputCap = 2000,
    this.argsCap = 1500,
    this.tailOutputCap = 6000,
    this.input = 600000,
  });

  /// The newest turns kept word for word (about 12K tokens).
  final int tail;

  /// The newest tool output in the summarized span that is kept (cut to
  /// [outputCap] each); older output is cleared.
  final int protectedOutput;
  final int outputCap;

  /// Tool-call arguments (file contents of an edit, say) in the summarized span.
  final int argsCap;

  /// Tool output in the kept tail (spilled results are already previews).
  final int tailOutputCap;

  /// The whole summarizer input; past this the oldest part is dropped.
  final int input;
}

/// What a compaction works on: the span to summarize and the turns kept.
@immutable
final class CompactionPlan {
  const CompactionPlan({required this.head, required this.tail, this.previousSummary = '', this.carried = ''});

  /// Events to summarize, oldest first.
  final List<HarnessEvent> head;

  /// The newest events, kept word for word.
  final List<HarnessEvent> tail;

  /// The summary from the last compaction, merged into the new one.
  final String previousSummary;

  /// The turns the last compaction kept word for word (they belong to the head).
  final String carried;
}

/// The parts of a continuation message (see [continuationMessage]).
typedef Compacted = ({String summary, String recent});

/// The summary and kept turns of [text] when it opens a continuation
/// conversation (mode and context notes already split off), else null.
Compacted? splitCompacted(String text) {
  final t = text.trimLeft();
  if (!t.startsWith(compactedOpen)) return null;
  return (summary: _between(t, _summaryOpen, _summaryClose), recent: _between(t, _recentOpen, _recentClose));
}

String _between(String text, String open, String close) {
  final start = text.indexOf(open);
  if (start < 0) return '';
  final end = text.indexOf(close, start + open.length);
  return text.substring(start + open.length, end < 0 ? text.length : end).trim();
}

/// The user's text of a message: session block, mode, context and rewind notes split off.
String userTextOf(String raw) =>
    splitRewindNote(splitContextNotes(splitModeNote(splitSessionBlock(raw).$2).$2).$2);

String _userText(String raw) => userTextOf(raw);

bool _isUser(HarnessEvent e) => e is ChatMessage && e.fromUser;

/// Whether [e] is part of what the model saw (not state or socket events).
bool countsForModel(HarnessEvent e) =>
    e is ChatMessage || e is ActionCall || e is ToolResult || e is ConversationFailure;

/// Splits [events] (one conversation, oldest first) into a span to summarize
/// and a tail kept word for word: whole turns when they fit in the budget,
/// else the newest steps of the current turn. Null when there's nothing to
/// summarize.
CompactionPlan? planCompaction(List<HarnessEvent> events, {CompactionBudget budget = const CompactionBudget()}) {
  final all = events.where(countsForModel).toList();
  var previous = '';
  var carried = '';
  var start = 0;
  if (all.firstOrNull case final ChatMessage first when first.fromUser) {
    if (splitCompacted(_userText(first.text)) case final c?) {
      previous = c.summary;
      carried = c.recent;
      start = 1;
    }
  }
  final body = all.sublist(start);
  if (body.isEmpty) return null;

  // Walk back from the newest event; remember the oldest cut that fits.
  var size = 0;
  int? turnCut;
  int? stepCut;
  for (var i = body.length - 1; i >= 0; i--) {
    size += _render(body[i], outputCap: budget.tailOutputCap, argsCap: budget.tailOutputCap).length;
    if (size > budget.tail) break;
    if (_isUser(body[i])) turnCut = i;
    if (body[i] is! ToolResult) stepCut = i;
  }
  var cut = turnCut ?? stepCut ?? body.length;
  // Something must be left to summarize.
  if (cut == 0) {
    final nextTurn = body.indexWhere(_isUser, 1);
    cut = nextTurn > 0 ? nextTurn : body.length;
    if (cut == body.length && body.length > 1) {
      final step = body.lastIndexWhere((e) => e is! ToolResult);
      cut = step > 0 ? step : body.length;
    }
  }
  final head = body.sublist(0, cut);
  if (head.isEmpty && carried.isEmpty) return null;
  return CompactionPlan(head: head, tail: body.sublist(cut), previousSummary: previous, carried: carried);
}

/// The summarized span as text for the summarizer, pruned first: older tool
/// output is cleared, the newest [CompactionBudget.protectedOutput] characters
/// of it are kept (each cut to [CompactionBudget.outputCap]). No model call.
String prunedHead(CompactionPlan plan, {CompactionBudget budget = const CompactionBudget()}) {
  final head = plan.head;
  final keep = List.filled(head.length, false);
  var output = 0;
  for (var i = head.length - 1; i >= 0; i--) {
    if (head[i] case final ToolResult r) {
      final n = r.text.length.clamp(0, budget.outputCap);
      if (output + n > budget.protectedOutput) continue;
      output += n;
      keep[i] = true;
    }
  }
  final parts = <String>[
    if (plan.carried.isNotEmpty) '[turns kept from before the previous summary]\n${plan.carried}',
    for (var i = 0; i < head.length; i++)
      _render(head[i], outputCap: keep[i] ? budget.outputCap : 0, argsCap: budget.argsCap),
  ].where((p) => p.isNotEmpty);
  final text = parts.join('\n\n');
  if (text.length <= budget.input) return text;
  // Still too long: the oldest part goes (the previous summary covers some of it).
  final cut = text.indexOf('\n\n', text.length - budget.input);
  return '[earlier steps omitted]\n\n${text.substring(cut < 0 ? text.length - budget.input : cut + 2)}';
}

/// The kept tail as text, word for word apart from very long tool output.
String renderTail(CompactionPlan plan, {CompactionBudget budget = const CompactionBudget()}) =>
    [for (final e in plan.tail) _render(e, outputCap: budget.tailOutputCap, argsCap: budget.tailOutputCap)]
        .where((p) => p.isNotEmpty)
        .join('\n\n');

/// The conversation so far as text for a side call (`/btw`): tool output cut
/// short, and only the newest [maxChars] characters when it runs long.
String renderSessionRecord(List<HarnessEvent> events, {int maxChars = 60000}) {
  final text = [
    for (final e in events)
      if (countsForModel(e)) _render(e, outputCap: 800, argsCap: 600),
  ].where((p) => p.isNotEmpty).join('\n\n');
  if (text.length <= maxChars) return text;
  final cut = text.indexOf('\n\n', text.length - maxChars);
  return '[earlier steps omitted]\n\n${text.substring(cut < 0 ? text.length - maxChars : cut + 2)}';
}

/// One event as a line of the transcript the summarizer (or the next agent)
/// reads. An [outputCap] of 0 clears tool output.
/// One step of [renderSessionRecord] as text: a message, a tool call (its
/// arguments cut to [argsCap]) or a result (cut to [outputCap]); '' for
/// events the model never saw.
String renderStep(HarnessEvent e, {int outputCap = 800, int argsCap = 600}) =>
    _render(e, outputCap: outputCap, argsCap: argsCap);

String _render(HarnessEvent e, {required int outputCap, required int argsCap}) => switch (e) {
  ChatMessage(fromUser: true, :final text) => '[user]\n${_userText(text).trim()}',
  ChatMessage(:final text, :final reasoning) =>
    text.trim().isEmpty
        ? (reasoning.trim().isEmpty ? '' : '[agent thinking]\n${_cap(reasoning.trim(), 600)}')
        : '[agent]\n${text.trim()}',
  ActionCall() => _renderCall(e, argsCap),
  ToolResult(:final toolName, :final outcome) =>
    '[result of $toolName${outcome == ToolOutcome.ok ? '' : ' (${outcome.name})'}]\n'
        '${outputCap == 0 ? clearedOutput : _cap(_resultText(e), outputCap)}',
  ConversationFailure(:final message) => '[error]\n$message',
  _ => '',
};

/// Fields OpenHands adds to typed actions that say nothing new about the step
/// (client tools such as `present_plan` keep their own `summary`).
const _noiseArgs = {'kind', 'security_risk', 'summary'};

String _renderCall(ActionCall call, int argsCap) {
  // The harness's plan is its own text: never cut like arguments.
  if (call.actionKind == 'ProposedPlanAction') return '[agent]\n${call.str('body').trim()}';
  final args = {
    for (final MapEntry(:key, :value) in call.action.entries)
      if (!(call.actionKind.isNotEmpty && _noiseArgs.contains(key)) && value != null && value != '' && value != false)
        key: value,
  };
  final thought = call.thought.trim();
  return [
    if (thought.isNotEmpty) '[agent]\n$thought',
    '[tool call ${call.toolName}]\n${_cap(jsonEncode(args), argsCap)}',
  ].join('\n\n');
}

String _resultText(ToolResult r) {
  final text = r.text;
  if (text.isNotEmpty) return text;
  final o = r.observation;
  return switch ((o['error'], o['reason'])) {
    (final String error, _) => error,
    (_, final String reason) => reason,
    _ => '(no output)',
  };
}

/// [text] cut to about [max] characters, keeping its start and end.
String _cap(String text, int max) {
  if (text.length <= max) return text;
  final head = (max * 0.7).floor();
  final tail = max - head;
  return '${text.substring(0, head)}\n[… ${text.length - max} characters cut …]\n${text.substring(text.length - tail)}';
}

/// The sections every summary has, in order.
const summarySections = ['Objective', 'Important details', 'Work state', 'Next move', 'Relevant files'];

const _summarizerSystem =
    'You condense the history of a coding session so that another agent can take over the work with nothing else '
    'to go on. Write only the summary, in the format you are given. Do not carry on with the task, and do not '
    'answer questions that appear in the session.';

/// The summarizer's messages (OpenAI chat format) for [plan]; [focus] is what
/// the user asked the summary to keep (from `/compact <focus>`).
List<Map<String, Object?>> summaryRequest(
  CompactionPlan plan, {
  String focus = '',
  CompactionBudget budget = const CompactionBudget(),
}) {
  final user = StringBuffer();
  if (plan.previousSummary.isNotEmpty) {
    user
      ..writeln('<previous-summary>')
      ..writeln(plan.previousSummary)
      ..writeln('</previous-summary>')
      ..writeln()
      ..writeln(
        'The previous summary will be thrown away after this: whatever you do not carry into the new summary is '
        'lost. Where it disagrees with the session below, the session is right. Move finished work from '
        '"In progress" to "Done".',
      )
      ..writeln();
  }
  user
    ..writeln('<session>')
    ..writeln(prunedHead(plan, budget: budget))
    ..writeln('</session>')
    ..writeln()
    ..writeln('Summarize the session above in exactly this format:')
    ..writeln()
    ..writeln('## Objective')
    ..writeln('What the user wants, in their words where it matters.')
    ..writeln()
    ..writeln('## Important details')
    ..writeln('Constraints, preferences, decisions and answers the user gave; facts learned about the code.')
    ..writeln()
    ..writeln('## Work state')
    ..writeln('### Done')
    ..writeln('### In progress')
    ..writeln('### Blocked')
    ..writeln()
    ..writeln('## Next move')
    ..writeln('1. The next concrete step.')
    ..writeln()
    ..writeln('## Relevant files')
    ..writeln('- path: why it matters')
    ..writeln()
    ..writeln('Rules:')
    ..writeln('- Keep every heading, even when a section is empty (write "none").')
    ..writeln('- Short bullets, no prose paragraphs.')
    ..writeln(
      '- Copy exact file paths, function and type names, commands, error messages, URLs and ids; never paraphrase '
      'them.',
    )
    ..writeln('- Cleared tool output is gone; record what the agent concluded from it, if anything.')
    ..writeln('- Do not mention that this is a summary or that the history was shortened.');
  if (focus.trim().isNotEmpty) {
    user
      ..writeln()
      ..writeln('The user asked the summary to keep this in particular: ${focus.trim()}');
  }
  return [
    {'role': 'system', 'content': _summarizerSystem},
    {'role': 'user', 'content': user.toString().trimRight()},
  ];
}

/// What replaces a tool result cleared to save context.
String clearedToolNote(String tool) =>
    '[output cleared to save context — re-run ${tool.isEmpty ? 'the tool' : tool} if you need it]';

/// A tool result old enough to be cleared: its index in the messages, its
/// call id and tool, and its text.
typedef OldToolOutput = ({int index, String callId, String tool, String content});

/// The tool results in [messages] older than the newest [keepTurns] model
/// steps, oldest first, when together they are over [triggerTokens]
/// (characters / 4); otherwise none, so nothing needs clearing yet.
List<OldToolOutput> oldToolOutputs(
  List<Map<String, Object?>> messages, {
  int triggerTokens = 40000,
  int keepTurns = 3,
}) {
  // Where the newest [keepTurns] model steps start: nothing from there on is touched.
  var steps = 0;
  var boundary = messages.length;
  for (var i = messages.length - 1; i >= 0; i--) {
    if (messages[i]['role'] == 'assistant') {
      boundary = i;
      if (++steps == keepTurns) break;
    }
  }
  if (steps < keepTurns) return const [];
  final names = <String, String>{};
  final old = <OldToolOutput>[];
  var chars = 0;
  for (var i = 0; i < boundary; i++) {
    final m = messages[i];
    if (m['role'] == 'assistant') {
      for (final c in m['tool_calls'] as List<Object?>? ?? const []) {
        if (c case {'id': final String id, 'function': {'name': final String name}}) names[id] = name;
      }
    }
    if (m['role'] != 'tool') continue;
    final content = m['content'];
    if (content is! String || content.startsWith('[output cleared to save context')) continue;
    final id = m['tool_call_id'] as String? ?? '';
    old.add((index: i, callId: id, tool: names[id] ?? '', content: content));
    chars += content.length;
  }
  return chars / 4 <= triggerTokens ? const [] : old;
}

/// Clears old tool output in [messages] (OpenAI chat format, changed in
/// place) once the output older than the newest [keepTurns] model steps is
/// over [triggerTokens]: results are replaced by a short note until what is
/// left is under [targetTokens], the oldest first, but those whose call ids
/// are in [needed] (the work still uses them) only after all the others.
/// Tokens are estimated as characters / 4. Returns how many results were
/// cleared (0: nothing changed, so the cached prefix is left alone). The gap
/// between trigger and target means it changes the history rarely.
int clearOldToolOutput(
  List<Map<String, Object?>> messages, {
  int triggerTokens = 40000,
  int targetTokens = 20000,
  int keepTurns = 3,
  Set<String> needed = const {},
}) {
  final old = oldToolOutputs(messages, triggerTokens: triggerTokens, keepTurns: keepTurns);
  if (old.isEmpty) return 0;
  var chars = old.fold<int>(0, (n, o) => n + o.content.length);
  final order = [...old.where((o) => !needed.contains(o.callId)), ...old.where((o) => needed.contains(o.callId))];
  var cleared = 0;
  for (final o in order) {
    if (chars / 4 <= targetTokens) break;
    final note = clearedToolNote(o.tool);
    if (note.length >= o.content.length) continue;
    messages[o.index] = {...messages[o.index], 'content': note};
    chars -= o.content.length;
    cleared++;
  }
  return cleared;
}

/// The decider's questions for [old]: whether each output is still needed
/// for the work in [focus]. Its text puts the work first, then each output
/// (cut to [each] characters) under its number.
({String text, List<Map<String, Object?>> questions}) neededQuestions(
  List<OldToolOutput> old,
  String focus, {
  int each = 1500,
}) {
  final text = StringBuffer()
    ..writeln('<work-in-progress>')
    ..writeln(focus.trim())
    ..writeln('</work-in-progress>');
  for (final (n, o) in old.indexed) {
    final body = o.content.length > each ? '${o.content.substring(0, each)}…' : o.content;
    text
      ..writeln('<output n="$n" tool="${o.tool}">')
      ..writeln(body)
      ..writeln('</output>');
  }
  return (
    text: text.toString(),
    questions: [
      for (final (n, _) in old.indexed)
        {
          'id': 'o$n',
          'kind': 'bool',
          'prompt':
              'Does the work in progress still need output $n (a file, error or result it will look at again), '
              'rather than having moved past it?',
        },
    ],
  );
}

/// The summarizer's reply, tidied: code fences around it removed. Null when
/// it isn't a summary (empty, or missing most sections).
String? cleanSummary(String reply) {
  var s = reply.trim();
  final fence = RegExp(r'^```[a-z]*\n([\s\S]*?)\n```$');
  if (fence.firstMatch(s) case final m?) s = m.group(1)!.trim();
  if (s.isEmpty) return null;
  final found = summarySections.where((h) => s.toLowerCase().contains('## ${h.toLowerCase()}')).length;
  return found >= 3 ? s : null;
}

/// Writes [body] to [b] inside `<tag>` with [lead] on the line above, after a
/// blank line; nothing when [body] is blank.
void writeTaggedBlock(StringBuffer b, String tag, String lead, String body) {
  if (body.trim().isEmpty) return;
  b
    ..writeln()
    ..writeln(lead)
    ..writeln('<$tag>')
    ..writeln(body.trim())
    ..writeln('</$tag>');
}

/// A to-do list as Markdown checkboxes: `[x]` done, `[~]` in progress.
String checklist(Iterable<({String title, String status})> items) => [
  for (final t in items)
    '- [${switch (t.status) {
      'completed' || 'done' => 'x',
      'in_progress' => '~',
      _ => ' ',
    }}] ${t.title}',
].join('\n');

/// The first message of the continuation conversation: [summary], then what
/// the agent was working from ([plan] the user approved, its [todos], the
/// current text of the [files] it touched last, the [skills] it loaded),
/// then the kept turns. With [resume] the agent is told to carry on;
/// otherwise the conversation starts without running and the user's next
/// message follows.
String continuationMessage({
  required String summary,
  required String recent,
  bool resume = false,
  String plan = '',
  String todos = '',
  String files = '',
  String skills = '',
}) {
  final b = StringBuffer()
    ..writeln(compactedOpen)
    ..writeln(
      'This session continues an earlier conversation that grew too long. The summary below stands in for it and is '
      'for reference only: your tools still work, and the newest user message is the request you are working on.',
    )
    ..writeln()
    ..writeln(_summaryOpen)
    ..writeln(summary.trim())
    ..writeln(_summaryClose);
  void section(String tag, String lead, String body) => writeTaggedBlock(b, tag, lead, body);

  section('approved-plan', 'The plan the user approved, which still stands:', plan);
  section('todos', 'Your checklist as you last wrote it:', todos);
  section(
    'files',
    'The files you worked on most recently, as they are now (you have read them; edit them directly):',
    files,
  );
  section('skills', 'Skills you loaded earlier in the session; follow them as before:', skills);
  if (recent.trim().isNotEmpty) {
    b
      ..writeln()
      ..writeln('The latest turns, word for word:')
      ..writeln(_recentOpen)
      ..writeln(recent.trim())
      ..writeln(_recentClose);
  }
  b.write(compactedClose);
  if (resume) {
    b
      ..writeln()
      ..writeln()
      ..write(
        'Carry on with the next step if there is one. If you are unsure how to proceed, stop and ask the user '
        'instead of guessing.',
      );
  }
  return b.toString();
}
