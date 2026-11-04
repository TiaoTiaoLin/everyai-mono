// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';

import '../../domain/compaction.dart' show userTextOf;
import '../../domain/transcript.dart' show isHarnessNote;
import '../../harness/events.dart';
import '../handoff.dart';
import '../native_import.dart';

// A conversation as the steps every native import writes (one translation
// for all three CLIs; each writer only maps the tool calls it has a tool
// for). Read from the handoff record, so secret files are withheld and call
// arguments and results redacted; message text is redacted here.

/// The most characters an import writes in all (about 60K tokens); the
/// oldest turns give way first.
const nativeImportMaxChars = 240000;

/// One string in a call's arguments is cut to this many characters.
const nativeImportArgChars = 4000;

/// The result a call gets when none came (the session stopped first). Every
/// CLI's format needs a result for every call.
const notFinishedResult = '(not finished: the session stopped before this call returned)';

sealed class ImportStep {
  const ImportStep();
}

/// A message from the user (or one of ours: the lead note, the handoff facts).
final class UserStep extends ImportStep {
  const UserStep(this.text, {this.ours = false});
  final String text;

  /// One of the app's notes, not a request of the user's.
  final bool ours;
}

/// The agent's text.
final class AgentStep extends ImportStep {
  const AgentStep(this.text);
  final String text;
}

/// A tool call with its result: [kind] is the app's action kind
/// (`TerminalAction`, `FileEditorAction`, ...), [args] the action without it.
final class CallStep extends ImportStep {
  const CallStep({
    required this.kind,
    required this.tool,
    required this.args,
    required this.result,
    required this.finished,
    required this.isError,
  });
  final String kind;
  final String tool;
  final Map<String, Object?> args;
  final String result;
  final bool finished;
  final bool isError;

  String str(String key) => args[key] as String? ?? '';

  CallStep withResult(String text) =>
      CallStep(kind: kind, tool: tool, args: args, result: text, finished: finished, isError: isError);
}

/// A call no tool of the CLI stands for, as the agent's text.
String callAsText(CallStep c) =>
    'Earlier call: ${c.tool} ${jsonEncode(c.args)}\n'
    'Result${c.isError ? ' (error)' : ''}:\n${c.result}';

/// [source] as steps for [into] (the CLI as the user knows it), oldest first,
/// or null when it has no request of the user's. It starts with a note on
/// where the conversation came from and ends with the handoff facts (with
/// the cut-off turn in `<cut-turn>`, so the switch's carry-on still reads
/// right). A cut-off turn stays as it was: its calls, no closing reply.
List<ImportStep>? importSteps(NativeImportSource source, {required String into}) {
  final turns = <List<ImportStep>>[];
  for (final stint in source.stints) {
    final record = handoffRecord(stint.events);
    final results = {
      for (final e in record)
        if (e is ToolResult) e.actionId: e,
    };
    for (final e in record) {
      switch (e) {
        case ChatMessage(fromUser: true, :final text):
          final said = userTextOf(text).trim();
          if (said.isEmpty || isHarnessNote(said) || isCarryOn(said)) continue;
          turns.add([UserStep(redactSecrets(said))]);
        case ChatMessage(:final text) when text.trim().isNotEmpty:
          if (turns.isEmpty) continue;
          turns.last.add(AgentStep(redactSecrets(text.trim())));
        case ActionCall():
          if (turns.isEmpty) continue;
          final r = results[e.id];
          turns.last.add(
            CallStep(
              kind: e.actionKind,
              tool: e.toolName,
              args: {
                for (final MapEntry(:key, :value) in e.action.entries)
                  if (key != 'kind') key: _capDeep(value),
              },
              result: r == null ? notFinishedResult : _cap(r.text, handoffTranscriptResultChars),
              finished: r != null,
              isError: r == null || r.outcome != ToolOutcome.ok,
            ),
          );
        default:
      }
    }
  }
  if (turns.isEmpty) return null;
  final leads = {
    for (final s in source.stints)
      if (s.lead.isNotEmpty) s.lead,
  };
  final lastLead = source.stints.isEmpty ? '' : source.stints.last.lead;
  final head = UserStep(
    ours: true,
    'This conversation was led by ${leads.isEmpty ? 'another agent' : leads.join(', ')} until now and was moved '
    "into $into. Earlier tool calls use $into's tool names where one matches; the others are written as text."
    "${source.handoff.cut == null ? '' : ' The last request was stopped by a usage limit before it was done: the calls made for it so far are the last ones in this history.'}",
  );
  // The facts without what the history here already holds: the latest
  // turns and the cut turn's calls (its request stays, so the carry-on's
  // "see <cut-turn>" still reads right).
  final tail = UserStep(
    handoffMessage(_withoutHistory(source.handoff), fromName: lastLead.isEmpty ? null : lastLead),
    ours: true,
  );
  final where = source.handoff.transcript.isEmpty ? '' : '; the whole conversation is in ${source.handoff.transcript}';
  // The newest turns are kept; the oldest give way first (the newest one stays).
  var size = _size(head) + _size(tail) + turns.fold(0, (n, t) => n + t.fold(0, (m, s) => m + _size(s)));
  var dropped = 0;
  while (dropped < turns.length - 1 && size > nativeImportMaxChars) {
    size -= turns[dropped].fold(0, (m, s) => m + _size(s));
    dropped++;
  }
  final kept = <ImportStep?>[for (final t in turns.skip(dropped)) ...t];
  // Still too big (one long turn): the oldest results give way, then the
  // oldest calls with the agent's text before them, as in the facts' cut
  // turn. The requests and the newest call stay.
  final calls = [
    for (final (i, s) in kept.indexed)
      if (s is CallStep) i,
  ];
  final older = calls.isEmpty ? const <int>[] : calls.sublist(0, calls.length - 1);
  for (final i in older) {
    if (size <= nativeImportMaxChars) break;
    final c = kept[i]! as CallStep;
    final short = c.withResult('(result left out to keep this short$where.)');
    size += _size(short) - _size(c);
    kept[i] = short;
  }
  var callsLeftOut = 0;
  for (final i in older) {
    if (size <= nativeImportMaxChars) break;
    for (var j = i; j >= 0 && kept[j] != null && kept[j] is! UserStep; j--) {
      size -= _size(kept[j]!);
      kept[j] = null;
    }
    callsLeftOut++;
  }
  // Requests alone too big for it: the facts handoff is used instead.
  if (size > nativeImportMaxChars) return null;
  final note = AgentStep('($callsLeftOut earlier calls are left out to keep this short$where.)');
  return [
    head,
    if (dropped > 0) UserStep('($dropped earlier turns are left out to keep this short$where.)', ours: true),
    for (final (i, s) in kept.indexed)
      if (s != null) s else if (i + 1 < kept.length && kept[i + 1] != null) note,
    tail,
  ];
}

/// [h] without its latest turns and the cut turn's calls, which a native
/// import writes as history.
Handoff _withoutHistory(Handoff h) => Handoff(
  fromHarness: h.fromHarness,
  fromConversation: h.fromConversation,
  toHarness: h.toHarness,
  createdAt: h.createdAt,
  kind: h.kind,
  coverage: h.coverage,
  since: h.since,
  staleReason: h.staleReason,
  approvedPlan: h.approvedPlan,
  proposedPlan: h.proposedPlan,
  todos: h.todos,
  openQuestions: h.openQuestions,
  lastRequest: h.lastRequest,
  files: h.files,
  git: h.git,
  cut: switch (h.cut) {
    final c? => HandoffCut(request: c.request, earlier: c.earlier, callsLeftOut: c.callsLeftOut + c.calls.length),
    null => null,
  },
  transcript: h.transcript,
);

/// How many of the user's requests [steps] hold.
int importedTurns(List<ImportStep> steps) => steps.whereType<UserStep>().where((s) => !s.ours).length;

int _size(ImportStep s) => switch (s) {
  UserStep(:final text) || AgentStep(:final text) => text.length,
  CallStep() => jsonEncode(s.args).length + s.result.length,
};

String _cap(String text, int max) =>
    text.length <= max ? text : '${text.substring(0, max)}\n[… ${text.length - max} characters cut …]';

Object? _capDeep(Object? v) => switch (v) {
  final String s => _cap(s, nativeImportArgChars),
  final Map<String, Object?> m => {for (final e in m.entries) e.key: _capDeep(e.value)},
  final List<Object?> l => [for (final x in l) _capDeep(x)],
  _ => v,
};

/// [path] made absolute against [cwd].
String absolutePath(String cwd, String path) =>
    path.isEmpty || path.startsWith('/') ? path : '${cwd.endsWith('/') ? cwd : '$cwd/'}$path';

/// [path] relative to [cwd] when it is inside it.
String relativePath(String cwd, String path) {
  final root = cwd.endsWith('/') ? cwd : '$cwd/';
  return path.startsWith(root) ? path.substring(root.length) : path;
}
