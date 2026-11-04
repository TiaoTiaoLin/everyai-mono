// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter/foundation.dart';

import '../domain/compaction.dart';
import '../domain/fork_files.dart';
import '../domain/phases.dart' show parsePhaseNote;
import '../domain/questions.dart' show Question;
import '../domain/transcript.dart';
import '../git/git_models.dart';
import '../domain/transcript_export.dart' show transcriptSteps;
import '../drivers/usage_limit.dart' show usageLimitOf;
import '../harness/events.dart';
import '../harness/everyai/research_sites.dart' show secretPath;

export '../domain/compaction.dart' show handoffClose, handoffOpen, splitHandoff;

// The handoff: what a new lead of a Code session gets when another harness
// took the work so far (the old one ran out of plan usage, or the user
// switched). Only facts, read from the session's events and the repository:
// no model is asked, so a handoff costs nothing (EveryAI spends nothing on a
// session it doesn't lead, and the outgoing lead may be out of usage). The
// new lead also gets the whole conversation as a Markdown file in the
// project's git-excluded `.everyai/handoffs/`, which it may read and
// summarise for itself, on its own plan.
//
// A turn the usage limit cut off is finished by the new lead: the handoff
// names the request, the calls that already ran (with their results) and
// the diff so far, so nothing is redone and the user repeats nothing.
//
// Going back to a harness that already has the earlier conversation gets a
// delta: only what happened since it last led. A delta that is too big, or a
// conversation that can't be reopened, gets a full handoff instead.

enum HandoffKind { full, delta }

/// A delta over this many rendered characters (about 15K tokens) is stale.
/// One that fits is shown whole: the lead coming back reads all it missed.
const handoffDeltaMaxChars = 60000;

/// The newest turns of a full handoff shown word for word (tool output cut
/// short); the transcript file has the rest.
const handoffRecentChars = 12000;

/// The user's last message, cut to this many characters.
const handoffRequestChars = 4000;

/// The most changed files the git block lists, the biggest first.
const handoffChanges = 30;

/// The calls of a cut-off turn: each result cut to [handoffCallResultChars],
/// and all of them shown in [handoffCutChars] (the oldest results give way
/// first; the transcript file has them).
const handoffCallResultChars = 800;
const handoffCutChars = 16000;

/// Where handoff transcripts go, relative to the session's folder (kept out
/// of git through `info/exclude`).
const handoffTranscriptDir = '.everyai/handoffs';

/// A transcript result over this many characters is cut.
const handoffTranscriptResultChars = 8000;

/// The name a handoff's files share: its time and the harness it went to
/// (the stored JSON and the transcript file).
String handoffStem(DateTime createdAt, String toHarness) =>
    '${createdAt.toUtc().toIso8601String().replaceAll(RegExp('[^0-9]'), '')}-'
    '${toHarness.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}';

/// The transcript file of a handoff made at [createdAt] for [toHarness],
/// relative to the session's folder.
String handoffTranscriptPath(DateTime createdAt, String toHarness) =>
    '$handoffTranscriptDir/${handoffStem(createdAt, toHarness)}.md';

/// The line that follows a handoff when the new lead should carry on at
/// once; with [cut], it finishes the request the old lead was cut off in.
String carryOnMessage(String from, {bool cut = false}) => cut
    ? 'Finish the request $from was working on when it stopped (see <cut-turn> above), without redoing the calls '
          'that already ran.'
    : 'Carry on with the work where $from stopped.';

/// Whether [text] (a user message, notes split off) is only a
/// [carryOnMessage]: the same turn going on, not a new request.
bool isCarryOn(String text) {
  final t = text.trim();
  return (t.startsWith('Carry on with the work where ') && t.endsWith(' stopped.')) ||
      (t.startsWith('Finish the request ') && t.endsWith('without redoing the calls that already ran.'));
}

/// At most this many files, the newest first, each diff cut to [handoffDiffChars]
/// and all of them to [handoffDiffTotalChars].
const handoffFiles = 5;
const handoffDiffChars = 4000;
const handoffDiffTotalChars = 16000;

/// The last event a handoff covers, in the conversation it came from.
@immutable
final class HandoffCoverage {
  const HandoffCoverage({required this.conversationId, required this.eventId});
  final String conversationId;
  final String eventId;

  factory HandoffCoverage.fromJson(Map<String, Object?> j) =>
      HandoffCoverage(conversationId: j['conversation_id'] as String? ?? '', eventId: j['event_id'] as String? ?? '');

  Map<String, Object?> toJson() => {'conversation_id': conversationId, 'event_id': eventId};
}

/// A file the session changed, with its diff since the session started.
@immutable
final class HandoffFile {
  const HandoffFile(this.path, {this.diff = '', this.cut = false, this.withheld = false});
  final String path;

  /// '' when there is no diff to show.
  final String diff;
  final bool cut;

  /// The file may hold secrets (`.env`, keys), so only its path is shown.
  final bool withheld;

  factory HandoffFile.fromJson(Map<String, Object?> j) => HandoffFile(
    j['path'] as String? ?? '',
    diff: j['diff'] as String? ?? '',
    cut: j['cut'] == true,
    withheld: j['withheld'] == true,
  );

  Map<String, Object?> toJson() => {
    'path': path,
    if (diff.isNotEmpty) 'diff': diff,
    if (cut) 'cut': true,
    if (withheld) 'withheld': true,
  };
}

/// A tool call of a cut-off turn, as the new lead reads it: the call and its
/// result, both rendered and cut short.
@immutable
final class HandoffCall {
  const HandoffCall({required this.tool, required this.call, this.result = '', this.finished = true});
  final String tool;

  /// The call with its arguments, as [renderStep] shows it.
  final String call;

  /// Its result as [renderStep] shows it ('' when there is none, or it gave
  /// way to newer ones; see [handoffCutChars]).
  final String result;

  /// False when no result came: the call may not have finished.
  final bool finished;

  factory HandoffCall.fromJson(Map<String, Object?> j) => HandoffCall(
    tool: j['tool'] as String? ?? '',
    call: j['call'] as String? ?? '',
    result: j['result'] as String? ?? '',
    finished: j['finished'] != false,
  );

  Map<String, Object?> toJson() => {
    'tool': tool,
    'call': call,
    if (result.isNotEmpty) 'result': result,
    if (!finished) 'finished': false,
  };
}

/// The turn the usage limit cut off: the user's request and the calls made
/// for it so far, oldest first.
@immutable
final class HandoffCut {
  const HandoffCut({
    required this.request,
    this.earlier = const [],
    this.calls = const [],
    this.resultsLeftOut = 0,
    this.callsLeftOut = 0,
  });

  /// The user's newest message in the turn.
  final String request;

  /// Earlier messages of the same turn (sent before the reply to them
  /// finished, like a steer), oldest first.
  final List<String> earlier;
  final List<HandoffCall> calls;

  /// Results not shown to stay within [handoffCutChars].
  final int resultsLeftOut;

  /// The oldest calls left out to stay within [handoffCutChars] (before [calls]).
  final int callsLeftOut;

  factory HandoffCut.fromJson(Map<String, Object?> j) => HandoffCut(
    request: j['request'] as String? ?? '',
    earlier: [for (final r in (j['earlier_requests'] as List<Object?>? ?? const [])) '$r'],
    calls: [
      for (final c in (j['calls'] as List<Object?>? ?? const []))
        if (c case final Map<String, Object?> m) HandoffCall.fromJson(m),
    ],
    resultsLeftOut: (j['results_left_out'] as num?)?.toInt() ?? 0,
    callsLeftOut: (j['calls_left_out'] as num?)?.toInt() ?? 0,
  );

  Map<String, Object?> toJson() => {
    'request': request,
    if (earlier.isNotEmpty) 'earlier_requests': earlier,
    'calls': [for (final c in calls) c.toJson()],
    if (resultsLeftOut > 0) 'results_left_out': resultsLeftOut,
    if (callsLeftOut > 0) 'calls_left_out': callsLeftOut,
  };
}

/// The repository as the handoff found it.
@immutable
final class HandoffGit {
  const HandoffGit({
    required this.branch,
    this.worktree = '',
    this.changes = const [],
    this.uncommitted = 0,
    this.commits = const [],
    this.moreChanges = 0,
    this.moreAdded = 0,
    this.moreRemoved = 0,
  });

  /// [changes] cut to the [handoffChanges] biggest; the rest are counted.
  factory HandoffGit.capped({
    required String branch,
    String worktree = '',
    required List<FileChange> changes,
    int uncommitted = 0,
    List<String> commits = const [],
  }) {
    final sorted = [...changes]..sort((a, b) => (b.added + b.removed).compareTo(a.added + a.removed));
    final rest = sorted.skip(handoffChanges);
    return HandoffGit(
      branch: branch,
      worktree: worktree,
      changes: sorted.take(handoffChanges).toList(),
      uncommitted: uncommitted,
      commits: commits,
      moreChanges: rest.length,
      moreAdded: rest.fold(0, (n, c) => n + c.added),
      moreRemoved: rest.fold(0, (n, c) => n + c.removed),
    );
  }

  final String branch;

  /// The session's own checkout, or '' when it works in the project folder.
  final String worktree;

  /// Files changed since the session started, committed or not: at most
  /// [handoffChanges], the biggest first (see [HandoffGit.capped]).
  final List<FileChange> changes;

  /// The changed files left out of [changes], and their lines.
  final int moreChanges;
  final int moreAdded;
  final int moreRemoved;

  /// Files changed but not committed.
  final int uncommitted;

  /// Subjects of the commits since the session started, newest first.
  final List<String> commits;

  factory HandoffGit.fromJson(Map<String, Object?> j) => HandoffGit(
    branch: j['branch'] as String? ?? '',
    worktree: j['worktree'] as String? ?? '',
    changes: [
      for (final c in (j['changes'] as List<Object?>? ?? const []))
        if (c case {'path': final String path, 'kind': final String kind})
          FileChange(
            path,
            ChangeKind.values.firstWhere((k) => k.letter == kind, orElse: () => ChangeKind.modified),
            added: (c['added'] as num?)?.toInt() ?? 0,
            removed: (c['removed'] as num?)?.toInt() ?? 0,
          ),
    ],
    uncommitted: (j['uncommitted'] as num?)?.toInt() ?? 0,
    commits: [for (final c in (j['commits'] as List<Object?>? ?? const [])) '$c'],
    moreChanges: (j['more_changes'] as num?)?.toInt() ?? 0,
    moreAdded: (j['more_added'] as num?)?.toInt() ?? 0,
    moreRemoved: (j['more_removed'] as num?)?.toInt() ?? 0,
  );

  Map<String, Object?> toJson() => {
    'branch': branch,
    if (worktree.isNotEmpty) 'worktree': worktree,
    'changes': [
      for (final c in changes) {'path': c.path, 'kind': c.kind.letter, 'added': c.added, 'removed': c.removed},
    ],
    'uncommitted': uncommitted,
    'commits': commits,
    if (moreChanges > 0) ...{'more_changes': moreChanges, 'more_added': moreAdded, 'more_removed': moreRemoved},
  };
}

/// What a new lead gets: facts from the session and the repository, and
/// where the whole conversation is. Stored per session (see `saveHandoff`).
@immutable
final class Handoff {
  const Handoff({
    required this.fromHarness,
    required this.fromConversation,
    required this.toHarness,
    required this.createdAt,
    required this.kind,
    required this.coverage,
    this.since,
    this.staleReason,
    this.approvedPlan = '',
    this.proposedPlan = '',
    this.todos = const [],
    this.openQuestions = const [],
    this.lastRequest = '',
    this.files = const [],
    this.git,
    this.recent = '',
    this.cut,
    this.transcript = '',
  });

  final String fromHarness;
  final String fromConversation;
  final String toHarness;
  final DateTime createdAt;
  final HandoffKind kind;

  /// The last event this handoff covers.
  final HandoffCoverage coverage;

  /// Where a delta starts (the last event [toHarness] saw); null for a full one.
  final HandoffCoverage? since;

  /// Why a delta was asked for but a full handoff was built.
  final String? staleReason;

  /// The plan the user approved, as Markdown ('' when none).
  final String approvedPlan;

  /// A plan still waiting for the user.
  final String proposedPlan;
  final List<PlanTask> todos;

  /// Questions the agent asked that the user hasn't answered.
  final List<String> openQuestions;

  /// The user's last message (mode and context notes split off), cut to
  /// [handoffRequestChars].
  final String lastRequest;

  /// The newest files changed, at most [handoffFiles].
  final List<HandoffFile> files;
  final HandoffGit? git;

  /// The newest turns as text.
  final String recent;

  /// The turn the usage limit cut off, which the new lead finishes; null
  /// when the last request was answered (or no limit stopped it).
  final HandoffCut? cut;

  /// The whole conversation as Markdown, relative to the session's folder
  /// (see [handoffTranscriptPath]); '' when it couldn't be written.
  final String transcript;

  factory Handoff.fromJson(Map<String, Object?> j) => Handoff(
    fromHarness: j['from_harness'] as String? ?? '',
    fromConversation: j['from_conversation'] as String? ?? '',
    toHarness: j['to_harness'] as String? ?? '',
    createdAt: DateTime.tryParse(j['created_at'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
    kind: j['kind'] == 'delta' ? HandoffKind.delta : HandoffKind.full,
    coverage: HandoffCoverage.fromJson(j['coverage'] as Map<String, Object?>? ?? const {}),
    since: switch (j['since']) {
      final Map<String, Object?> s => HandoffCoverage.fromJson(s),
      _ => null,
    },
    staleReason: j['stale_reason'] as String?,
    approvedPlan: j['approved_plan'] as String? ?? '',
    proposedPlan: j['proposed_plan'] as String? ?? '',
    todos: [
      for (final t in (j['todos'] as List<Object?>? ?? const []))
        if (t case final Map<String, Object?> m)
          PlanTask(m['title'] as String? ?? '', m['status'] as String? ?? 'todo', m['notes'] as String? ?? ''),
    ],
    openQuestions: [for (final q in (j['open_questions'] as List<Object?>? ?? const [])) '$q'],
    lastRequest: j['last_request'] as String? ?? '',
    files: [
      for (final f in (j['files'] as List<Object?>? ?? const []))
        if (f case final Map<String, Object?> m) HandoffFile.fromJson(m),
    ],
    git: switch (j['git']) {
      final Map<String, Object?> g => HandoffGit.fromJson(g),
      _ => null,
    },
    recent: j['recent'] as String? ?? '',
    // Handoffs stored before 2026-11-04 may carry a `summary` from a utility
    // model: it is no longer used.
    cut: switch (j['cut']) {
      final Map<String, Object?> c => HandoffCut.fromJson(c),
      _ => null,
    },
    transcript: j['transcript'] as String? ?? '',
  );

  Map<String, Object?> toJson() => {
    'from_harness': fromHarness,
    'from_conversation': fromConversation,
    'to_harness': toHarness,
    'created_at': createdAt.toUtc().toIso8601String(),
    'kind': kind.name,
    'coverage': coverage.toJson(),
    if (since != null) 'since': since!.toJson(),
    if (staleReason != null) 'stale_reason': staleReason,
    'approved_plan': approvedPlan,
    'proposed_plan': proposedPlan,
    'todos': [
      for (final t in todos) {'title': t.title, 'status': t.status, if (t.notes.isNotEmpty) 'notes': t.notes},
    ],
    'open_questions': openQuestions,
    'last_request': lastRequest,
    'files': [for (final f in files) f.toJson()],
    if (git != null) 'git': git!.toJson(),
    'recent': recent,
    if (cut != null) 'cut': cut!.toJson(),
    if (transcript.isNotEmpty) 'transcript': transcript,
  };
}

/// The events a handoff covers. With [since], those after it (a delta),
/// unless it is stale: [since] isn't in [events], the target can't reopen
/// its old conversation ([resumable] false), or the delta renders to more
/// than [handoffDeltaMaxChars]. Then all of [events] (a full handoff), with
/// the reason. The size is measured as [handoffRecord] shows it.
///
/// [events] is the session's record, oldest first. Event ids are unique per
/// conversation, so the last match counts.
({List<HarnessEvent> events, HandoffKind kind, String? staleReason}) handoffScope(
  List<HarnessEvent> events, {
  HandoffCoverage? since,
  bool resumable = true,
}) {
  ({List<HarnessEvent> events, HandoffKind kind, String? staleReason}) full([String? why]) =>
      (events: events, kind: HandoffKind.full, staleReason: why);
  if (since == null) return full();
  if (!resumable) return full("its earlier conversation can't be reopened");
  final at = events.lastIndexWhere((e) => e.id.isNotEmpty && e.id == since.eventId);
  if (at < 0) return full('the last turn it saw is no longer in the session record');
  final delta = events.sublist(at + 1);
  final size = renderSessionRecord(handoffRecord(delta), maxChars: 1 << 30).length;
  if (size > handoffDeltaMaxChars) return full('too much happened since it last led ($size characters)');
  return (events: delta, kind: HandoffKind.delta, staleReason: null);
}

/// The handoff from [from] to [to] for a session whose record is [events]
/// (oldest first), working in [workingDir]. The plan, todos, open questions
/// and last request are current state, so they come from all of [events];
/// the files and the recent turns come from the scope (see [handoffScope]).
/// [git] and [diffs] (by path) come from `handoffGit`; without them the
/// files are paths only. [transcript] is where the conversation was saved
/// (see [handoffTranscript]). No model is asked and nothing is fetched.
Handoff buildHandoff(
  List<HarnessEvent> events, {
  required String from,
  required String fromConversation,
  required String to,
  required String workingDir,
  HandoffCoverage? since,
  bool resumable = true,
  DateTime? now,
  HandoffGit? git,
  Map<String, FileDiff> diffs = const {},
  String transcript = '',
}) {
  final scope = handoffScope(events, since: since, resumable: resumable);
  final builder = TranscriptBuilder();
  for (final e in events) {
    builder.add(e);
  }
  final t = builder.snapshot;
  // A Max/Ultra flow that started over for a new task (its phase notes
  // carry a new run id) dropped the plan it had: only a later one stands.
  final current = {for (final e in events.sublist(_lastRestart(events))) e.id};
  var approved = '';
  var lastRequest = '';
  for (final item in t.items.reversed) {
    if (approved.isEmpty &&
        item is PlanProposal &&
        item.verdict == PlanVerdict.approved &&
        current.contains(item.key)) {
      approved = item.markdown;
    }
    if (lastRequest.isEmpty && item is UserTurn) lastRequest = item.text.trim();
    if (approved.isNotEmpty && lastRequest.isNotEmpty) break;
  }
  lastRequest = _capRequest(lastRequest);

  // Files the agent wrote, the newest first; else what git saw change (an
  // outside agent's patch may not name its files), the biggest first.
  var paths = recentWrites(scope.events, workingDir, max: handoffFiles);
  if (paths.isEmpty && git != null) {
    paths = [
      for (final c in [...git.changes]..sort((a, b) => (b.added + b.removed).compareTo(a.added + a.removed))) c.path,
    ].take(handoffFiles).toList();
  }
  var room = handoffDiffTotalChars;
  final files = <HandoffFile>[];
  for (final path in paths) {
    if (_secret(path)) {
      files.add(HandoffFile(path, withheld: true));
      continue;
    }
    final d = diffs[path] ?? diffs.entries.where((e) => e.key.endsWith('/$path')).firstOrNull?.value;
    final text = d == null ? '' : _diffText(d);
    final max = room.clamp(0, handoffDiffChars);
    final cut = text.length > max;
    final shown = cut ? '${text.substring(0, max)}\n[… ${text.length - max} characters cut …]' : text;
    room -= cut ? max : text.length;
    files.add(HandoffFile(path, diff: shown, cut: cut));
  }

  final last = events.lastWhere(
    countsForModel,
    orElse: () => const UnknownEvent(id: '', raw: {}, kind: ''),
  );
  return Handoff(
    fromHarness: from,
    fromConversation: fromConversation,
    toHarness: to,
    createdAt: now ?? DateTime.now(),
    kind: scope.kind,
    coverage: HandoffCoverage(conversationId: fromConversation, eventId: last.id),
    since: scope.kind == HandoffKind.delta ? since : null,
    staleReason: scope.staleReason,
    approvedPlan: approved,
    proposedPlan: t.openPlan?.markdown ?? '',
    todos: t.plan,
    openQuestions: [for (final q in t.openQuestion?.questions ?? const <Question>[]) q.question],
    lastRequest: lastRequest,
    files: files,
    git: git,
    recent: renderSessionRecord(
      handoffRecord(scope.events),
      maxChars: scope.kind == HandoffKind.delta ? handoffDeltaMaxChars : handoffRecentChars,
    ),
    cut: cutTurn(events),
    transcript: transcript,
  );
}

String _capRequest(String text) => text.length <= handoffRequestChars
    ? text
    : '${text.substring(0, handoffRequestChars)}\n[… ${text.length - handoffRequestChars} characters cut …]';

/// The turn the usage limit cut off in [events] (the session's record,
/// oldest first), or null. That is the last request from the user (a
/// message that only hands over or says to carry on doesn't count: the
/// same turn goes on; nor does a note from the app or the harness, see
/// [isHarnessNote]) whose turn the limit stopped before the agent's reply
/// finished. A reply finished when a turn end (idle or finished) follows
/// the agent's text with no tool call between; a limit after that hit a
/// turn that was already done. Earlier requests whose replies never
/// finished (the user steered, or wrote mid-turn) belong to the same turn,
/// up to [handoffCutRequests]. The calls are those made since the earliest
/// of them by every lead, files that may hold secrets withheld; within
/// [handoffCutChars] the oldest results give way first, then the oldest
/// calls.
HandoffCut? cutTurn(List<HarnessEvent> events) {
  final record = handoffRecord(events);
  // The user's requests, newest first; harness notes (phase notes, task
  // notifications, reports, answers, compaction) and carry-ons are not.
  final requests = <({int at, String text})>[];
  for (var i = record.length - 1; i >= 0; i--) {
    if (record[i] case ChatMessage(fromUser: true, :final text)) {
      final said = userTextOf(text).trim();
      if (said.isEmpty || isCarryOn(said) || isHarnessNote(said)) continue;
      requests.add((at: i, text: said));
    }
  }
  if (requests.isEmpty) return null;
  // A request sent while an earlier one was still unfinished (a steer, or a
  // message in the middle of the turn) goes on with it: both are the turn.
  var first = 0;
  while (first + 1 < requests.length &&
      first + 1 < handoffCutRequests &&
      !_settle(record.sublist(requests[first + 1].at + 1, requests[first].at)).ended) {
    first++;
  }
  final turn = record.sublist(requests[first].at + 1);
  if (!_settle(turn).cut) return null;
  final results = {
    for (final e in turn)
      if (e is ToolResult) e.actionId: e,
  };
  final all = [
    for (final e in turn)
      if (e is ActionCall)
        (call: e, result: results[e.id] == null ? '' : renderStep(results[e.id]!, outputCap: handoffCallResultChars)),
  ];
  // The oldest results give way first, then the oldest calls (the newest one stays).
  var size = all.fold(0, (n, c) => n + renderStep(c.call).length + c.result.length);
  var left = 0;
  final shown = [for (final c in all) c.result.isNotEmpty];
  for (var i = 0; i < all.length && size > handoffCutChars; i++) {
    if (!shown[i]) continue;
    shown[i] = false;
    size -= all[i].result.length;
    left++;
  }
  var dropped = 0;
  while (dropped < all.length - 1 && size > handoffCutChars) {
    size -= renderStep(all[dropped].call).length + (shown[dropped] ? all[dropped].result.length : 0);
    if (shown[dropped]) left++;
    dropped++;
  }
  return HandoffCut(
    request: _capRequest(requests.first.text),
    earlier: [for (final r in requests.sublist(1, first + 1).reversed) _capRequest(r.text)],
    calls: [
      for (final (i, c) in all.indexed.skip(dropped))
        HandoffCall(
          tool: c.call.toolName,
          call: renderStep(c.call),
          result: shown[i] ? c.result : '',
          finished: results.containsKey(c.call.id),
        ),
    ],
    resultsLeftOut: left,
    callsLeftOut: dropped,
  );
}

/// At most this many requests of the user make up one cut turn (see [cutTurn]).
const handoffCutRequests = 5;

/// How the events after a request went: whether the agent's reply ever
/// finished (a turn end after its text, with no call between), and whether
/// a usage limit cut it short after its last finished reply.
({bool ended, bool cut}) _settle(List<HarnessEvent> turn) {
  var cut = false;
  var replied = false;
  var finished = false;
  var ended = false;
  for (final e in turn) {
    switch (e) {
      case ChatMessage(fromUser: true):
        // A carry-on or a note: the agent works on the same request.
        replied = false;
        finished = false;
      case ChatMessage(:final text) when text.trim().isNotEmpty:
        replied = true;
      case ActionCall():
        replied = false;
      case StateChange(executionStatus: ExecutionStatus.idle || ExecutionStatus.finished) when replied:
        finished = true;
        ended = true;
        cut = false;
      default:
        if (usageLimitOf(e) != null && !finished) cut = true;
    }
  }
  return (ended: ended, cut: cut);
}

/// One lead's stint for [handoffTranscript]: the lead as the user knows it,
/// its conversation and the events it added.
typedef HandoffStint = ({String lead, String conversationId, List<HarnessEvent> events});

/// The whole session so far as plain Markdown, for the new lead to read:
/// every lead's stint, oldest first, with each message, tool call and result
/// (long results cut). Withheld the same way as the facts ([handoffRecord]).
String handoffTranscript(List<HandoffStint> stints, {required String title}) {
  final b = StringBuffer('# $title: the session so far\n\n')
    ..writeln(
      'Every conversation of this Code session, oldest first, with each tool call and its result (results over '
      '$handoffTranscriptResultChars characters are cut). Files that may hold secrets are named but not shown.',
    );
  for (final s in stints) {
    final steps = transcriptSteps(handoffRecord(s.events), resultCap: handoffTranscriptResultChars);
    if (steps.trim().isEmpty) continue;
    b
      ..writeln()
      ..writeln('---')
      ..writeln()
      ..writeln('# ${s.lead}${s.conversationId.isEmpty ? '' : ' (conversation ${s.conversationId})'}')
      ..writeln()
      ..write(steps);
  }
  return b.toString();
}

/// Where the flow last started over: the first event of its newest run
/// (0 when it never did).
int _lastRestart(List<HarnessEvent> events) {
  String? run;
  var at = 0;
  for (final (i, e) in events.indexed) {
    if (e is! ChatMessage || !e.fromUser) continue;
    final note = parsePhaseNote(userTextOf(e.text));
    if (note == null) continue;
    if (run != null && note.run != run) at = i;
    run = note.run;
  }
  return at;
}

/// [events] as the next lead may read them (in the facts and the transcript file): an earlier
/// handoff is split off the user's message (a message that was only that is
/// left out); the content of calls on files that may hold secrets, and
/// their results, is withheld (only the path is shown); so are the results
/// of shell commands that name such a file (`cat .env`). Anything left that
/// looks like a credential (`API_KEY=…`, a private key, a known token shape)
/// is redacted (see [redactSecrets]).
List<HarnessEvent> handoffRecord(List<HarnessEvent> events) {
  final withheld = <String>{};
  final out = <HarnessEvent>[];
  for (final e in events) {
    switch (e) {
      case ChatMessage(fromUser: true, :final text):
        final (block, said) = splitHandoff(userTextOf(text));
        if (block == null) {
          out.add(e);
        } else if (said.isNotEmpty) {
          out.add(ChatMessage(id: e.id, raw: e.raw, fromUser: true, text: said));
        }
      case ActionCall() when _callPaths(e).any(_secret):
        withheld.add(e.id);
        out.add(
          ActionCall(
            id: e.id,
            raw: const {},
            toolName: e.toolName,
            toolCallId: e.toolCallId,
            action: {
              if (e.actionKind.isNotEmpty) 'kind': e.actionKind,
              'paths': _callPaths(e).toList(),
              'content': _withheldText,
            },
          ),
        );
      case ToolResult() when withheld.contains(e.actionId):
        out.add(
          ToolResult(
            id: e.id,
            raw: const {},
            actionId: e.actionId,
            toolName: e.toolName,
            toolCallId: e.toolCallId,
            outcome: e.outcome,
            observation: const {
              'content': [
                {'type': 'text', 'text': _withheldText},
              ],
            },
          ),
        );
      case ActionCall(:final action):
        if (action['command'] case final String command when _commandWords(command).any(_secret)) {
          withheld.add(e.id);
        }
        final redacted = _redactDeep(action);
        out.add(
          identical(redacted, action)
              ? e
              : ActionCall(
                  id: e.id,
                  raw: const {},
                  toolName: e.toolName,
                  toolCallId: e.toolCallId,
                  action: redacted as Map<String, Object?>,
                  thought: e.thought,
                  summary: e.summary,
                  risk: e.risk,
                ),
        );
      case ToolResult(:final observation):
        final redacted = _redactDeep(observation);
        out.add(
          identical(redacted, observation)
              ? e
              : ToolResult(
                  id: e.id,
                  raw: const {},
                  actionId: e.actionId,
                  toolName: e.toolName,
                  toolCallId: e.toolCallId,
                  outcome: e.outcome,
                  observation: redacted as Map<String, Object?>,
                ),
        );
      default:
        out.add(e);
    }
  }
  return out;
}

const _withheldText = '(not shown: the file may hold secrets)';

/// Every path [call] names: what it writes, and what it reads or views.
Set<String> _callPaths(ActionCall call) => {
  ...writeTargets(call),
  for (final key in const ['path', 'file_path'])
    if (call.action[key] case final String p when p.isNotEmpty) p,
  ...?(call.action['paths'] as List<Object?>?)?.whereType<String>(),
};

/// The words of a shell [command] that could be paths (quotes, redirects
/// and separators split off).
Iterable<String> _commandWords(String command) =>
    command.split(RegExp('[\\s;|&<>()`\'"=]+')).where((w) => w.isNotEmpty && !w.startsWith('-'));

final _secretPatterns = [
  // A private key block, to its end (or the end of the text, when cut).
  RegExp(r'-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)'),
  // NAME=value or "name": "value", where the name says it is a credential
  // (API_KEY, GITHUB_TOKEN, "password", "client_secret"), and the value is
  // long enough to be one (not `$VAR` or a short placeholder).
  RegExp(
    r'''\b([A-Z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIALS?)[A-Z0-9_]*|'''
    r'''(?:[a-z]+[_-]?)?(?:api[_-]?key|access[_-]?key|token|secret|password|passwd))'''
    r'''(["']?\s*[=:]\s*["']?)([^\s"',;$(){}\[\]]{8,})''',
  ),
  // Well-known token shapes.
  RegExp(
    r'\b(?:sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|'
    r'xox[abprs]-[A-Za-z0-9-]{10,})',
  ),
];

/// [text] with what looks like a credential replaced by `(redacted)`.
String redactSecrets(String text) {
  var out = text;
  for (final (i, p) in _secretPatterns.indexed) {
    out = out.replaceAllMapped(p, (m) => i == 1 ? '${m[1]}${m[2]}(redacted)' : '(redacted)');
  }
  return out;
}

/// [value] with every string in it redacted; the same object when nothing changed.
Object? _redactDeep(Object? value) {
  switch (value) {
    case final String s:
      final r = redactSecrets(s);
      return r == s ? s : r;
    case final Map<String, Object?> m:
      Map<String, Object?>? copy;
      for (final MapEntry(:key, value: v) in m.entries) {
        final r = _redactDeep(v);
        if (!identical(r, v)) (copy ??= {...m})[key] = r;
      }
      return copy ?? m;
    case final List<Object?> l:
      List<Object?>? copy;
      for (final (i, v) in l.indexed) {
        final r = _redactDeep(v);
        if (!identical(r, v)) (copy ??= [...l])[i] = r;
      }
      return copy ?? l;
    default:
      return value;
  }
}

String _diffText(FileDiff d) {
  if (d.binary) return '(binary)';
  return [
    for (final h in d.hunks) ...[h.header, ...h.lines],
  ].join('\n');
}

/// Files that may hold secrets: only their paths go out. [secretPath]
/// matches folders like `.ssh/` by a leading slash, which a relative path lacks.
bool _secret(String path) => secretPath(path.startsWith('/') ? path : '/$path');

/// The message the new lead gets before the user's own next message: our
/// words, the facts in tagged blocks in a fixed order (the most volatile
/// last), empty blocks left out. [fromName] is the outgoing lead as the user
/// knows it (its harness id when not given). With a cut-off turn, that turn
/// is what to do first.
String handoffMessage(Handoff h, {String? fromName}) {
  final from = fromName ?? h.fromHarness;
  final cut = h.cut;
  final next = cut == null
      ? "Your tools work as usual, and the user's next message is what to do."
      : 'Your tools work as usual. $from was cut off by its usage limit in the middle of a request: finish it '
            '(see <cut-turn>); the user will not repeat it.';
  final b = StringBuffer()
    ..writeln('$handoffOpen from="${h.fromHarness}" kind="${h.kind.name}">')
    ..writeln(switch (h.kind) {
      HandoffKind.full =>
        'You are taking over a coding session from $from. The facts below were read from the session and the '
            'repository. $next',
      HandoffKind.delta =>
        'While you were away, $from worked on this session. Below is what changed since your last turn. $next',
    });
  writeTaggedBlock(b, 'approved-plan', 'The plan the user approved, which still stands:', h.approvedPlan);
  writeTaggedBlock(b, 'proposed-plan', 'A plan that was proposed and still waits for the user:', h.proposedPlan);
  writeTaggedBlock(
    b,
    'todos',
    'The checklist as it was last written:',
    checklist([for (final t in h.todos) (title: t.title, status: t.status)]),
  );
  writeTaggedBlock(
    b,
    'open-questions',
    'Questions put to the user that are not answered yet:',
    [for (final q in h.openQuestions) '- $q'].join('\n'),
  );
  if (h.git case final g?) writeTaggedBlock(b, 'git', 'The repository now:', _gitText(g));
  writeTaggedBlock(
    b,
    'files',
    'The files changed most recently, with their diffs since the session started (read them before editing):',
    [
      for (final f in h.files)
        '<file path="${f.path}">\n${f.withheld
            ? '(diff not shown: the file may hold secrets)'
            : f.diff.isEmpty
            ? '(no diff available)'
            : f.diff}\n</file>',
    ].join('\n'),
  );
  writeTaggedBlock(
    b,
    'transcript',
    'The whole conversation so far, with every tool call and its result, is saved in this file (relative to the '
        'working directory). Read it when the facts here are not enough, and summarise it for yourself as you need:',
    h.transcript,
  );
  writeTaggedBlock(b, 'recent-turns', 'The latest turns:', h.recent);
  if (cut != null) {
    writeTaggedBlock(b, 'cut-turn', _cutLead, _cutText(cut, transcript: h.transcript.isNotEmpty));
  } else {
    writeTaggedBlock(b, 'last-request', 'What the user asked for last:', h.lastRequest);
  }
  b.write(handoffClose);
  return b.toString();
}

/// Only the `<cut-turn>` block of [h], for a lead whose own session already
/// holds the conversation (a native import); '' when no turn was cut.
String cutTurnMessage(Handoff h) {
  final cut = h.cut;
  if (cut == null) return '';
  final b = StringBuffer();
  writeTaggedBlock(b, 'cut-turn', _cutLead, _cutText(cut, transcript: h.transcript.isNotEmpty));
  return b.toString().trim();
}

const _cutLead =
    'The request the previous agent was working on when its usage limit stopped it. Finish it. The calls below '
    'already ran (results cut short): do not run them again unless a result shows it failed. A call with no result '
    'may not have finished, so check what it did before running it again. The diff so far is in <files> and <git>.';

/// [transcript]: whether the transcript file was written, so left-out parts
/// can point at it.
String _cutText(HandoffCut c, {required bool transcript}) {
  final b = StringBuffer();
  if (c.earlier.isEmpty) {
    b.write('Request:\n${c.request}');
  } else {
    b.write("The user's messages in this turn, oldest first (where they differ, the newest decides):");
    for (final (i, r) in [...c.earlier, c.request].indexed) {
      b.write('\n\n${i + 1}. $r');
    }
  }
  if (c.calls.isEmpty && c.callsLeftOut == 0) {
    b.write('\n\nNo tool calls were made for it yet.');
    return b.toString();
  }
  final where = transcript ? 'the transcript file has them' : 'check <files> and <git> for what they did';
  b.write('\n\nCalls already made, oldest first:');
  if (c.callsLeftOut > 0) b.write('\n\n(${c.callsLeftOut} earlier calls left out to keep this short; $where.)');
  for (final (i, call) in c.calls.indexed) {
    b.write('\n\n${c.callsLeftOut + i + 1}. ${call.call}');
    if (call.result.isNotEmpty) {
      b.write('\n${call.result}');
    } else if (!call.finished) {
      b.write('\n(no result came: it may not have finished)');
    } else {
      b.write(transcript ? '\n(result left out here; it is in the transcript file)' : '\n(result left out here)');
    }
  }
  if (c.resultsLeftOut > 0) {
    b.write(
      '\n\n${c.resultsLeftOut} older results were left out to keep this short'
      '${transcript ? '; the transcript file has them' : ''}.',
    );
  }
  return b.toString();
}

String _gitText(HandoffGit g) => [
  'Branch: ${g.branch}${g.worktree.isEmpty ? '' : ' (the session\'s own checkout at ${g.worktree})'}',
  if (g.changes.isNotEmpty) ...[
    'Changed since the session started:',
    for (final c in g.changes) '${c.kind.letter} +${c.added} -${c.removed} ${c.path}',
    if (g.moreChanges > 0) '… and ${g.moreChanges} more files (+${g.moreAdded} -${g.moreRemoved})',
  ],
  'Files not committed yet: ${g.uncommitted}',
  if (g.commits.isNotEmpty) ...['Commits since the session started, newest first:', for (final c in g.commits) '- $c'],
].join('\n');
