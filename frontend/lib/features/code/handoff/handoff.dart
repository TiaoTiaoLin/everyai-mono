// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter/foundation.dart';

import '../../billing/billing_providers.dart' show BillingSummary;
import '../domain/compaction.dart';
import '../domain/fork_files.dart';
import '../domain/phases.dart' show parsePhaseNote;
import '../domain/questions.dart' show Question;
import '../domain/transcript.dart';
import '../git/git_models.dart';
import '../harness/events.dart';
import '../harness/everyai/research_sites.dart' show secretPath;
import '../harness/summarizer.dart' show Summarizer;

export '../domain/compaction.dart' show handoffClose, handoffOpen, splitHandoff;

// The handoff: what a new lead of a Code session gets when another harness
// took the work so far (the old one ran out of plan usage, or the user
// switched). The facts are always read from the session's events and the
// repository, with no model call. A short summary from the utility model is
// added on the user's credits or own key, never on an outside plan, and the
// outgoing lead is never asked (it may be the one out of usage).
//
// Going back to a harness that already has the earlier conversation gets a
// delta: only what happened since it last led. A delta that is too big, or a
// conversation that can't be reopened, gets a full handoff instead.

enum HandoffKind { full, delta }

/// skipped: neither credits nor a key pay for it, or every turn it covers is
/// shown word for word anyway; failed: the call or its reply was bad, so only
/// the facts go out.
enum SummaryState { done, skipped, failed }

/// A delta over this many rendered characters (about 15K tokens) is stale.
/// One that fits is shown whole: the lead coming back reads all it missed.
const handoffDeltaMaxChars = 60000;

/// The newest turns of a full handoff shown word for word (tool output cut
/// short); the summary covers what came before.
const handoffRecentChars = 12000;

/// The user's last message, cut to this many characters.
const handoffRequestChars = 4000;

/// The most changed files the git block lists, the biggest first.
const handoffChanges = 30;

/// What the summarizer reads (about 30K tokens): a handoff summary is short.
const handoffSummaryBudget = CompactionBudget(input: 120000, protectedOutput: 30000);

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
/// maybe a short summary. Stored per session (see `saveHandoff`).
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
    this.summary,
    this.summaryState = SummaryState.skipped,
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
  final String? summary;
  final SummaryState summaryState;

  Handoff withSummary(String? summary, SummaryState state) => Handoff(
    fromHarness: fromHarness,
    fromConversation: fromConversation,
    toHarness: toHarness,
    createdAt: createdAt,
    kind: kind,
    coverage: coverage,
    since: since,
    staleReason: staleReason,
    approvedPlan: approvedPlan,
    proposedPlan: proposedPlan,
    todos: todos,
    openQuestions: openQuestions,
    lastRequest: lastRequest,
    files: files,
    git: git,
    recent: recent,
    summary: summary,
    summaryState: state,
  );

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
    summary: j['summary'] as String?,
    summaryState: SummaryState.values.firstWhere(
      (s) => s.name == j['summary_state'],
      orElse: () => SummaryState.skipped,
    ),
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
    if (summary != null) 'summary': summary,
    'summary_state': summaryState.name,
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
/// files are paths only.
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
  if (lastRequest.length > handoffRequestChars) {
    lastRequest =
        '${lastRequest.substring(0, handoffRequestChars)}\n[… ${lastRequest.length - handoffRequestChars} characters cut …]';
  }

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
  );
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

/// [events] as the next lead and the summarizer may read them: an earlier
/// handoff is split off the user's message (a message that was only that is
/// left out), and the content of calls on files that may hold secrets, and
/// their results, is withheld (only the path is shown).
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
/// knows it (its harness id when not given).
String handoffMessage(Handoff h, {String? fromName}) {
  final from = fromName ?? h.fromHarness;
  final b = StringBuffer()
    ..writeln('$handoffOpen from="${h.fromHarness}" kind="${h.kind.name}">')
    ..writeln(switch (h.kind) {
      HandoffKind.full =>
        'You are taking over a coding session from $from. The facts below were read from the session and the '
            "repository. Your tools work as usual, and the user's next message is what to do.",
      HandoffKind.delta =>
        'While you were away, $from worked on this session. Below is what changed since your last turn. Your '
            "tools work as usual, and the user's next message is what to do.",
    });
  writeTaggedBlock(b, 'summary', 'A short account of the work so far:', h.summary ?? '');
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
  writeTaggedBlock(b, 'recent-turns', 'The latest turns:', h.recent);
  writeTaggedBlock(b, 'last-request', 'What the user asked for last:', h.lastRequest);
  b.write(handoffClose);
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

/// The one line added to the summary request (see [summarizeHandoff]).
const handoffFocus =
    'that it hands the work to a different coding agent that has seen none of it, so keep it short and leave out '
    'the plan, todos, files and git state, which that agent gets separately (write "see below" under those '
    'headings).';

/// Whether the utility summary can be paid for: by the user's own key
/// ([ownKey]), or by credits. Unknown [billing] tries anyway (the gateway
/// refuses with a 402 at no cost, and the handoff goes out with the facts).
bool handoffSummaryPayable({required bool ownKey, BillingSummary? billing}) =>
    ownKey || billing == null || billing.walletMicros + billing.quotaLeftMicros > 0;

/// [h] with a summary of [scope] (the events it covers) from [summarize]: the
/// utility model through the gateway, billed to the session. [summarize] is
/// null when neither credits nor a key pay for it ([handoffSummaryPayable]),
/// which skips it. Only the turns older than [Handoff.recent] are summarized
/// (in [handoffSummaryBudget]); with none, it is skipped. Never throws: a
/// failed call or a bad reply leaves the facts.
Future<Handoff> summarizeHandoff(Handoff h, List<HarnessEvent> scope, Summarizer? summarize) async {
  final head = _olderThanShown(
    handoffRecord(scope),
    h.kind == HandoffKind.delta ? handoffDeltaMaxChars : handoffRecentChars,
  );
  if (summarize == null || !head.any(countsForModel)) return h.withSummary(null, SummaryState.skipped);
  try {
    final reply = await summarize(
      summaryRequest(
        CompactionPlan(head: head, tail: const []),
        focus: handoffFocus,
        budget: handoffSummaryBudget,
      ),
    );
    final summary = cleanSummary(reply);
    return summary == null ? h.withSummary(null, SummaryState.failed) : h.withSummary(summary, SummaryState.done);
  } on Object {
    return h.withSummary(null, SummaryState.failed);
  }
}

/// [events] up to the newest ones that fit in [shown] rendered characters
/// (what [renderSessionRecord] shows word for word).
List<HarnessEvent> _olderThanShown(List<HarnessEvent> events, int shown) {
  var size = 0;
  for (var i = events.length - 1; i >= 0; i--) {
    final n = renderSessionRecord([events[i]], maxChars: 1 << 30).length;
    if (n == 0) continue;
    if (size + n > shown) return events.sublist(0, i + 1);
    size += n + 2;
  }
  return const [];
}
