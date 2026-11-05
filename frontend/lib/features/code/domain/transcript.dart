import 'package:flutter/foundation.dart';

import 'phases.dart';
import '../drivers/driver_policy.dart' show hostToolOf;
import '../drivers/usage_limit.dart';
import '../harness/events.dart';
import '../settings/context_files.dart' show splitContextNotes;
import '../workflows/workflow_notes.dart' show splitWorkflowNotes;
import 'agent_mode.dart';
import 'compaction.dart' show splitCompacted, splitHandoff;
import 'notice.dart';
import 'questions.dart';
import 'rewind.dart' show splitRewindNote;
import 'subagents.dart';

/// What the session view shows, folded from harness events by
/// [TranscriptBuilder].
@immutable
sealed class TranscriptItem {
  const TranscriptItem(this.key);

  /// Stable across rebuilds (the first event's id).
  final String key;
}

final class UserTurn extends TranscriptItem {
  const UserTurn(super.key, this.text, {this.mode, this.lead = '', this.workflow = ''});
  final String text;

  /// What the workflow notes it carried said ("Started Bug fix", "Max on"),
  /// shown as a chip; '' for none.
  final String workflow;

  /// The mode note the message carried (shown as a chip), if any.
  final AgentMode? mode;

  /// The harness that got it, by name ('' when not known); shown once a
  /// session has had more than one lead.
  final String lead;
}

final class AgentText extends TranscriptItem {
  const AgentText(super.key, this.text, {this.reasoning = ''});
  final String text;
  final String reasoning;
}

/// One tool call and (once it lands) its result.
@immutable
final class ToolStep {
  const ToolStep(this.call, [this.result]);
  final ActionCall call;
  final ToolResult? result;

  bool get done => result != null;
  bool get failed => result?.outcome == ToolOutcome.error;
  bool get rejected => result?.outcome == ToolOutcome.rejected;

  ToolStep withResult(ToolResult r) => ToolStep(call, r);
}

/// A run of read-only steps ("Explored 3 files, 2 searches"), collapsed.
final class ExploreGroup extends TranscriptItem {
  const ExploreGroup(super.key, this.steps);
  final List<ToolStep> steps;
}

/// A command, an edit, or any other single tool call.
final class StepItem extends TranscriptItem {
  StepItem(this.step) : super(step.call.id);
  final ToolStep step;
}

/// A delegated subagent task: a `run_subagent` call the app runs as a child
/// conversation (or OpenHands' own delegate action, in old sessions).
final class SubagentItem extends TranscriptItem {
  SubagentItem(this.step, {this.report}) : super(step.call.id);
  final ToolStep step;

  /// What the child handed back; null while it works.
  final SubagentReport? report;

  /// A call the app runs (not OpenHands' own delegation).
  bool get ours => isTaskCall(step.call);

  bool get done => ours ? report != null : step.done;

  SubagentTask get task => SubagentTask.of(step.call);

  /// name → task.
  Map<String, String> get tasks => {
    for (final e in ((step.call.action['tasks'] as Map<String, Object?>?) ?? const {}).entries) e.key: '${e.value}',
  };
}

final class PlanItem extends TranscriptItem {
  const PlanItem(super.key, this.tasks);
  final List<PlanTask> tasks;
}

@immutable
final class PlanTask {
  const PlanTask(this.title, this.status, [this.notes = '', this.priority = '', this.active = '']);
  final String title;

  /// todo, in_progress or done.
  final String status;
  final String notes;

  /// The harness's own priority (`high`, `medium`, `low`), or ''.
  final String priority;

  /// What it is doing while in progress, in its own words (Claude's `activeForm`), or ''.
  final String active;
}

/// An `ask_user_question` card. [answers] is null until answered; empty when
/// the user replied in their own words instead.
final class QuestionItem extends TranscriptItem {
  QuestionItem(this.call, this.questions, [this.answers]) : super(call.id);
  final ActionCall call;
  final List<Question> questions;
  final List<QuestionAnswer>? answers;
}

/// One file the agent presented.
@immutable
final class DeliveredFile {
  const DeliveredFile(this.path, {this.title = '', this.description = ''});
  final String path;
  final String title;
  final String description;

  String get name => title.isNotEmpty ? title : path.split(RegExp(r'[\\/]')).last;
}

/// A `present_files` call: the files the agent finished with.
final class FilesDelivered extends TranscriptItem {
  FilesDelivered(this.call) : super(call.id);
  final ActionCall call;

  List<DeliveredFile> get files => [
    for (final f in (call.action['files'] as List<Object?>? ?? const []))
      if (f is Map<String, Object?> && '${f['path'] ?? ''}'.trim().isNotEmpty)
        DeliveredFile('${f['path']}'.trim(), title: '${f['title'] ?? ''}', description: '${f['description'] ?? ''}')
      else if (f is String && f.trim().isNotEmpty)
        DeliveredFile(f.trim()),
  ];
}

/// A `present_plan` proposal. [verdict] is null while it waits for the user.
final class PlanProposal extends TranscriptItem {
  PlanProposal(this.call, {this.verdict}) : super(call.id);
  final ActionCall call;
  final PlanVerdict? verdict;

  /// The harness's own plan (no approval here): never waits for the user.
  bool get shown => call.actionKind == 'ProposedPlanAction';

  String get title => call.str('title');
  String get summary => call.str('summary');
  String get verification => call.str('verification');

  /// The plan in the agent's own Markdown (Cursor's `create_plan`), or ''.
  String get body => call.str('body');

  List<PlanStep> get steps => [
    for (final s in (call.action['steps'] as List<Object?>? ?? const []))
      if (s is Map<String, Object?>)
        PlanStep(s['title'] as String? ?? '', s['detail'] as String? ?? '', [
          for (final f in (s['files'] as List<Object?>? ?? const [])) '$f',
        ])
      else if (s is String)
        PlanStep(s, '', const []),
  ];

  List<String> get risks => [for (final r in (call.action['risks'] as List<Object?>? ?? const [])) '$r'];

  /// The plan as Markdown, for copying.
  String get markdown => [
    if (title.isNotEmpty || !shown) '# $title',
    if (summary.isNotEmpty) '\n$summary',
    if (body.trim().isNotEmpty) '\n${body.trim()}',
    '',
    for (final (i, s) in steps.indexed) ...[
      '${i + 1}. ${s.title}${s.detail.isEmpty ? '' : ': ${s.detail}'}',
      if (s.files.isNotEmpty) '   Files: ${s.files.join(', ')}',
    ],
    if (risks.isNotEmpty) ...['', '## Risks', for (final r in risks) '- $r'],
    if (verification.isNotEmpty) ...['', '## Verification', verification],
  ].join('\n');
}

enum PlanVerdict { approved, revised }

@immutable
final class PlanStep {
  const PlanStep(this.title, this.detail, this.files);
  final String title;
  final String detail;
  final List<String> files;
}

/// The message "Start building" sends after a plan is approved.
const planApprovedMessage = 'The plan is approved. Build it now, then verify it works.';

/// The same approval as the result of the held `present_plan` call.
const planApprovedReason =
    'Not an error and not a refusal: the user approved this plan in the app (Plan mode, if it was on, has ended). '
    'You may now edit files and run commands. $planApprovedMessage';

/// Opens the result of a held `present_plan` call when the user wants changes.
const planRevisionLead = 'Not an error: the user wants changes to this plan before building. Their reply:';

/// The title of the row that holds the text an outside agent was briefed with.
const briefingNotice = 'EveryAI briefing';

/// The kind of a note the app adds on a lead switch (see [leadNoticeEvent]).
const leadNoticeKind = 'EveryAILeadNotice';

/// [notice] as an event, so it is kept with the lead timeline and shows
/// again after a restart (the builder folds it back into [notice]).
HarnessEvent leadNoticeEvent(NoticeItem notice) => HarnessEvent.decode({
  'id': '',
  'kind': leadNoticeKind,
  'key': notice.key,
  'message': notice.message,
  if (notice.detail.isNotEmpty) 'detail': notice.detail,
  if (notice.handedOffFrom.isNotEmpty) 'handed_off_from': notice.handedOffFrom,
});

final class NoticeItem extends TranscriptItem {
  const NoticeItem(
    super.key,
    this.message, {
    this.error = false,
    this.detail = '',
    this.limit,
    this.handedOffFrom = '',
  });
  final String message;
  final bool error;

  /// More to show on request (a compaction's summary), or ''.
  final String detail;

  /// The lead stopped on a usage limit (its plan, or EveryAI credits): the
  /// session offers to carry on with another harness.
  final UsageLimit? limit;

  /// An automatic handoff away from this driver id after its usage limit:
  /// the row offers Change (the picker again), or ''.
  final String handedOffFrom;
}

/// Whether an error is the account running out of EveryAI credits (the
/// gateway's 402), not something about the model or the work.
bool isOutOfCredits(String text) =>
    RegExp(r'out of everyai credits|out_of_credits', caseSensitive: false).hasMatch(text);

/// The notice a compacted session opens with.
const contextCompactedNotice = 'Context compacted';

@immutable
final class Transcript {
  const Transcript({
    this.items = const [],
    this.streaming = '',
    this.streamingReasoning = '',
    this.streamingParts = const [],
    this.phase,
    this.status = ExecutionStatus.idle,
    this.plan = const [],
    this.pending = const [],
    this.held = const [],
    this.notedMode,
    this.retry,
  });

  final List<TranscriptItem> items;

  /// A model call being retried after a transient failure, or null.
  final RetryState? retry;

  /// Subagents started since the user last spoke that haven't reported yet.
  List<SubagentItem> get openSubagents {
    final open = <SubagentItem>[];
    for (final item in items.reversed) {
      if (item is UserTurn) break;
      if (item is SubagentItem && item.ours && item.report == null) open.add(item);
    }
    return open.reversed.toList();
  }

  /// The reply being written.
  final String streaming;
  final String streamingReasoning;

  /// Where a Max or Ultra flow is (its latest phase note), or null.
  final ({String flow, Phase phase, String run, bool stuck})? phase;

  /// The reply being written in order: text (String) and the tool calls
  /// being written between it ([StreamingTool]).
  final List<Object> streamingParts;
  final ExecutionStatus status;

  /// The latest task list, for the sticky plan card.
  final List<PlanTask> plan;

  /// Actions waiting for approval (not client tools: see [held]).
  final List<ActionCall> pending;

  /// Client tool calls (question cards, plans) the server is holding for the
  /// user's reply. Sessions that answer inside the call reject them with the
  /// reply as the reason; others approve them at once.
  final List<ActionCall> held;

  /// The mode the agent was last told about (see `modeNote`).
  final AgentMode? notedMode;

  /// The latest plan proposal still waiting for the user.
  PlanProposal? get openPlan {
    for (final item in items.reversed) {
      if (item is UserTurn) return null;
      if (item is PlanProposal && item.verdict == null && !item.shown) return item;
    }
    return null;
  }

  /// The card waiting for answers: the latest unanswered one since the user
  /// last spoke. The agent's own text after it ("I've asked…") doesn't close it.
  QuestionItem? get openQuestion {
    for (final item in items.reversed) {
      if (item is UserTurn) return null;
      if (item is QuestionItem && item.answers == null) return item;
    }
    return null;
  }

  bool get running => status == ExecutionStatus.running;
}

/// Folds events into a [Transcript]. Mutable on the inside, immutable
/// snapshots out; feed events in order with [add].
final class TranscriptBuilder {
  final _items = <TranscriptItem>[];

  /// actionId → index in [_items].
  final _byAction = <String, int>{};
  final _byToolCall = <String, String>{};
  final _open = <String, ActionCall>{};

  /// A patch's call id → its per-file step ids.
  final _patchParts = <String, List<String>>{};
  final _streaming = StringBuffer();
  final _reasoning = StringBuffer();
  final _parts = <Object>[];
  ({String flow, Phase phase, String run, bool stuck})? _phase;
  var _status = ExecutionStatus.idle;
  var _plan = const <PlanTask>[];
  AgentMode? _notedMode;
  RetryState? _retry;

  /// The harness the events come from now, by name: stamped on user turns,
  /// and the lead a handoff went to. Set by a session that switched leads.
  String lead = '';

  Transcript get snapshot => Transcript(
    items: List.unmodifiable(_items),
    streaming: _streaming.toString(),
    streamingReasoning: _reasoning.toString(),
    streamingParts: List.unmodifiable(_parts),
    phase: _phase,
    status: _status,
    plan: _plan,
    notedMode: _notedMode,
    retry: _retry,
    pending: _status == ExecutionStatus.waitingForConfirmation ? _unanswered(client: false) : const [],
    held: _status == ExecutionStatus.waitingForConfirmation ? _unanswered(client: true) : const [],
  );

  /// Every action without a result yet, whatever item it renders as.
  List<ActionCall> _unanswered({required bool client}) =>
      List.unmodifiable(_open.values.where((c) => isHeldTool(c) == client));

  void add(HarnessEvent e) {
    // A retry ends with the next thing the model does (or a stop or failure).
    if (e is! RetryState &&
        e is! ConnectionChange &&
        !(e is StateChange &&
            (e.executionStatus == ExecutionStatus.running || e.executionStatus == ExecutionStatus.unknown))) {
      _retry = null;
    }
    if (e is! StreamDelta && e is! StateChange && e is! ConnectionChange) {
      _streaming.clear();
      _reasoning.clear();
      _parts.clear();
    }
    switch (e) {
      case StreamDelta(:final content, :final reasoning, :final tool):
        _streaming.write(content);
        _reasoning.write(reasoning);
        if (content.isNotEmpty) {
          if (_parts.isNotEmpty && _parts.last is String) {
            _parts.last = '${_parts.last}$content';
          } else {
            _parts.add(content);
          }
        }
        if (tool != null) {
          final at = _parts.indexWhere((p) => p is StreamingTool && p.index == tool.index);
          if (at >= 0) {
            _parts[at] = tool;
          } else {
            _parts.add(tool);
          }
        }
      case StateChange(key: approvedCallsKey, :final raw):
        for (final id in raw['value'] as List<Object?>? ?? const []) {
          _open.remove(id);
        }
      case StateChange(:final executionStatus) when executionStatus != ExecutionStatus.unknown:
        _status = executionStatus;
      case StateChange():
        break;
      // What streamed before the failure is void (cleared above); the reply comes again.
      case RetryState():
        _retry = e;
      case ChatMessage(fromUser: true, text: final all):
        // The briefing is never something the user typed: it is its own row.
        final (briefed, raw) = splitSessionBlock(all);
        if (briefed != null) _items.add(NoticeItem('${e.id}-briefing', briefingNotice, detail: briefed));
        if (briefed != null && raw.isEmpty) return;
        final (mode, noted) = splitModeNote(raw);
        final (_, afterContext) = splitContextNotes(noted);
        final (flows, afterFlows) = splitWorkflowNotes(afterContext);
        var text = splitRewindNote(afterFlows);
        final changed = mode != null && mode != _notedMode;
        if (mode != null) _notedMode = mode;
        // A continuation conversation opens with the summary, not something the user typed.
        if (splitCompacted(text) case final c?) {
          _items.add(NoticeItem(e.id, contextCompactedNotice, detail: c.summary));
          return;
        }
        final (handedOver, said) = splitHandoff(text);
        if (handedOver != null) {
          final from = RegExp(r'from="([^"]*)"').firstMatch(handedOver)?[1] ?? '';
          final title = lead.isNotEmpty ? 'Handoff to $lead' : 'Handed over${from.isEmpty ? '' : ' from $from'}';
          // The handoff, then what the user wrote with it (sent with their next message).
          _items.add(NoticeItem(said.isEmpty ? e.id : '${e.id}-handoff', title, detail: handedOver));
          if (said.isEmpty) return;
          text = said;
        }
        // Notices to an outside lead: one row each, as if the body had come bare.
        if (noticeBodies(text) case final bodies when bodies.isNotEmpty) {
          for (final (i, body) in bodies.indexed) {
            final id = bodies.length == 1 ? e.id : '${e.id}-$i';
            if (parseTaskNotification(body) case final n?) {
              _items.add(
                NoticeItem(
                  id,
                  '${n.title} ${n.status == SubagentStatus.completed ? 'finished' : n.status.label.toLowerCase()} in the background',
                  error: n.status == SubagentStatus.failed,
                  detail: n.result,
                ),
              );
            } else {
              _items.add(UserTurn(id, body, mode: i == 0 && changed ? mode : null, lead: lead));
            }
          }
          return;
        }
        if (_answer(text) || _reported(text)) return;
        if (text.trimLeft().startsWith('<$researchWorkflowTag')) {
          final n = RegExp(r'reports="(\d+)"').firstMatch(text)?[1] ?? '';
          _items.add(NoticeItem(e.id, 'Research workflow: $n reports', detail: text));
          return;
        }
        // Shown by the phase strip above the composer (stuck too), not in the transcript.
        if (parsePhaseNote(text) case final p?) {
          _phase = (flow: p.flow, phase: p.phase, run: p.run, stuck: p.stuck);
          return;
        }
        if (parseTaskNotification(text) case final n?) {
          _items.add(
            NoticeItem(
              e.id,
              '${n.title} ${n.status == SubagentStatus.completed ? 'finished' : n.status.label.toLowerCase()} in the background',
              error: n.status == SubagentStatus.failed,
              detail: n.result,
            ),
          );
          return;
        }
        // A note the app sent alone (a workflow that didn't start) shows as the app's notice instead.
        if (flows.isNotEmpty && text.trim().isEmpty) return;
        _items.add(UserTurn(e.id, text, mode: changed ? mode : null, lead: lead, workflow: flows.join(' · ')));
        _settleOpenCards(text);
      case ChatMessage(:final text, :final reasoning):
        if (text.trim().isEmpty && reasoning.trim().isEmpty) return;
        _items.add(AgentText(e.id, text, reasoning: reasoning));
      case ActionCall():
        _action(e);
      case ToolResult():
        _result(e);
      case ConversationFailure(:final message):
        // EveryAI's own limit is the gateway's 402: no reset time.
        final limit = usageLimitOf(e) ?? (isOutOfCredits(message) ? UsageLimit(message: message) : null);
        _items.add(NoticeItem(e.id, message, error: true, limit: limit));
      case UnknownEvent(kind: leadNoticeKind, :final raw):
        _items.add(
          NoticeItem(
            raw['key'] as String? ?? '',
            raw['message'] as String? ?? '',
            detail: raw['detail'] as String? ?? '',
            handedOffFrom: raw['handed_off_from'] as String? ?? '',
          ),
        );
      case UnknownEvent() || ConnectionChange() || UsageReport() || PlanLimits():
        break;
    }
  }

  /// Starts a new builder with [items] as they are: what an earlier
  /// conversation showed (a compacted session), kept when the transcript is
  /// folded again.
  void carry(List<TranscriptItem> items) {
    assert(_items.isEmpty, 'carry before adding events');
    _items.addAll(items);
  }

  /// A card raised by the app itself (not by the agent): it has no tool call
  /// to answer, so [settleLocal] closes it.
  void addLocalQuestion(ActionCall call, List<Question> questions) {
    _push(call.id, QuestionItem(call, questions));
  }

  /// Closes subagent cards the app settled itself (stopped without a reply
  /// the agent would read).
  void settleSubagents(Iterable<String> ids, SubagentReport report) {
    for (final id in ids) {
      final i = _byAction[id];
      if (i == null) continue;
      if (_items[i] case SubagentItem(:final step, report: null)) _items[i] = SubagentItem(step, report: report);
    }
  }

  void settleLocal(String id, List<QuestionAnswer> answers) {
    final i = _byAction[id];
    if (i == null) return;
    if (_items[i] case QuestionItem(:final call, :final questions)) _items[i] = QuestionItem(call, questions, answers);
  }

  /// Closes plan card [id] at once, before the agent's result arrives (an
  /// outside agent's host call answered in the app).
  void settlePlan(String id, PlanVerdict verdict) {
    final i = _byAction[id];
    if (i == null) return;
    if (_items[i] case PlanProposal(:final call, verdict: null)) _items[i] = PlanProposal(call, verdict: verdict);
  }

  /// A note the app adds itself (not from the agent).
  void addNotice(NoticeItem notice) => _items.add(notice);

  void _action(ActionCall call) {
    _byToolCall[call.toolCallId] = call.id;
    _open[call.id] = call;
    // An outside agent's call to the app's MCP host is the same card.
    final card = hostToolOf(call) ?? call.toolName;
    if (card == askUserQuestionTool) {
      _push(call.id, QuestionItem(call, Question.listFrom(call.action)));
      return;
    }
    if (card == presentPlanTool) {
      _push(call.id, PlanProposal(call));
      return;
    }
    if (call.toolName == presentFilesTool) {
      _push(call.id, FilesDelivered(call));
      return;
    }
    if (isTaskCall(call)) {
      if (call.thought.isNotEmpty) _items.add(AgentText('${call.id}-t', call.thought));
      _push(call.id, SubagentItem(ToolStep(call)));
      return;
    }
    switch (call.actionKind) {
      // The harness's plan text (Claude's ExitPlanMode, a Codex plan item), shown as a card.
      case 'ProposedPlanAction':
        _push(call.id, PlanProposal(call));
      case 'TaskTrackerAction':
        final tasks = [
          for (final t in (call.action['task_list'] as List<Object?>? ?? const []))
            if (t is Map<String, Object?>)
              PlanTask(
                t['title'] as String? ?? '',
                t['status'] as String? ?? 'todo',
                t['notes'] as String? ?? '',
                t['priority'] as String? ?? '',
                t['active'] as String? ?? '',
              ),
        ];
        if (tasks.isEmpty) return;
        _plan = tasks;
        // Consecutive plan updates replace each other.
        if (_items.lastOrNull is PlanItem) _items.removeLast();
        _push(call.id, PlanItem(call.id, tasks));
      // A patch shows as one edit step per file it changes.
      case 'ApplyPatchAction':
        if (call.thought.isNotEmpty) _items.add(AgentText('${call.id}-t', call.thought));
        final files = [...(call.action['files'] as List<Object?>? ?? const []).whereType<Map<String, Object?>>()];
        if (files.isEmpty) {
          _push(call.id, StepItem(ToolStep(call)));
          return;
        }
        final ids = <String>[];
        for (final (i, f) in files.indexed) {
          final path = '${f['to'] ?? f['path'] ?? ''}';
          final part = ActionCall(
            id: i == 0 ? call.id : '${call.id}#$i',
            raw: call.raw,
            toolName: call.toolName,
            toolCallId: call.toolCallId,
            summary: call.summary,
            risk: call.risk,
            action: {
              'kind': f['op'] == 'add' ? 'WriteFileAction' : 'EditAction',
              'path': path,
              'file_path': path,
              'patch_op': f['op'],
              if (f['to'] != null) 'from': f['path'],
            },
          );
          _push(part.id, StepItem(ToolStep(part)));
          ids.add(part.id);
        }
        _patchParts[call.id] = ids;
      case 'ThinkAction':
        _items.add(AgentText(call.id, '', reasoning: call.str('thought')));
      case 'FinishAction':
        final message = call.str('message');
        if (message.isNotEmpty) _items.add(AgentText(call.id, message));
      case 'DelegateAction' || 'TaskAction':
        if (call.thought.isNotEmpty) _items.add(AgentText('${call.id}-t', call.thought));
        _push(call.id, SubagentItem(ToolStep(call)));
      default:
        if (call.thought.isNotEmpty) _items.add(AgentText('${call.id}-t', call.thought));
        if (AgentMode.isReadOnly(call)) {
          if (_items.lastOrNull case final ExploreGroup g) {
            _items[_items.length - 1] = ExploreGroup(g.key, [...g.steps, ToolStep(call)]);
            _byAction[call.id] = _items.length - 1;
          } else {
            _push(call.id, ExploreGroup(call.id, [ToolStep(call)]));
          }
        } else {
          _push(call.id, StepItem(ToolStep(call)));
        }
    }
  }

  void _push(String actionId, TranscriptItem item) {
    _items.add(item);
    _byAction[actionId] = _items.length - 1;
  }

  void _result(ToolResult r) {
    final actionId = r.actionId.isNotEmpty ? r.actionId : (_byToolCall[r.toolCallId] ?? '');
    _open.remove(actionId);
    if (_patchParts.remove(actionId) case final parts?) {
      // Each file's step gets its own part of the result (its diff).
      final files = [...(r.observation['files'] as List<Object?>? ?? const []).whereType<Map<String, Object?>>()];
      for (final (i, id) in parts.indexed) {
        final at = _byAction[id];
        if (at == null) continue;
        if (_items[at] case StepItem(:final step)) {
          final file = i < files.length ? files[i] : null;
          _items[at] = StepItem(
            step.withResult(
              ToolResult(
                id: i == 0 ? r.id : '${r.id}#$i',
                raw: r.raw,
                actionId: id,
                toolName: r.toolName,
                outcome: r.outcome,
                observation: {
                  ...r.observation,
                  if (file != null) ...{
                    'path': file['path'],
                    'old_content': file['old_content'],
                    'new_content': file['new_content'],
                  },
                },
              ),
            ),
          );
        }
      }
      return;
    }
    final i = _byAction[actionId];
    if (i == null) return;
    _items[i] = switch (_items[i]) {
      StepItem(:final step) => StepItem(step.withResult(r)),
      // A held call's result is the report, or the reason it was cut short.
      SubagentItem(:final step, :final report) when step.call.toolName == taskTool => SubagentItem(
        step.withResult(r),
        report:
            report ??
            (r.outcome != ToolOutcome.rejected
                ? null
                : parseSubagentReports(_reason(r))[step.call.id] ?? SubagentReport(SubagentStatus.stopped, _reason(r))),
      ),
      SubagentItem(:final step) => SubagentItem(step.withResult(r)),
      ExploreGroup(:final key, :final steps) => ExploreGroup(key, [
        for (final s in steps) s.call.id == actionId ? s.withResult(r) : s,
      ]),
      // A held card is answered by rejecting the call with the answers as the reason.
      QuestionItem(:final call, :final questions, :final answers) when r.outcome == ToolOutcome.rejected =>
        QuestionItem(call, questions, answers ?? parseAnswers(_reason(r), questions) ?? const []),
      PlanProposal(:final call, verdict: null, shown: false) when r.outcome == ToolOutcome.rejected => PlanProposal(
        call,
        verdict: _reason(r).startsWith(planApprovedReason) ? PlanVerdict.approved : PlanVerdict.revised,
      ),
      // A host call's result is the answer itself; an error (timed out, the
      // session ended) closes the card unanswered.
      QuestionItem(:final call, :final questions, answers: null) when hostToolOf(call) != null => QuestionItem(
        call,
        questions,
        r.outcome == ToolOutcome.ok ? parseAnswers(r.text, questions) ?? const [] : const [],
      ),
      PlanProposal(:final call, verdict: null, shown: false) when hostToolOf(call) != null => PlanProposal(
        call,
        verdict: r.outcome == ToolOutcome.ok && r.text.trimLeft().startsWith(planApprovedReason)
            ? PlanVerdict.approved
            : PlanVerdict.revised,
      ),
      final other => other,
    };
  }

  static String _reason(ToolResult r) => '${r.observation['reason'] ?? ''}';

  /// A reply in the user's own words settles any card still open: a
  /// question counts as answered in chat, a plan as approved or revised.
  void _settleOpenCards(String text) {
    for (var i = _items.length - 2; i >= 0; i--) {
      final item = _items[i];
      if (item is UserTurn) return;
      if (item is QuestionItem && item.answers == null) {
        _items[i] = QuestionItem(item.call, item.questions, const []);
      } else if (item is PlanProposal && item.verdict == null && !item.shown) {
        final approved = text.startsWith(planApprovedMessage);
        _items[i] = PlanProposal(item.call, verdict: approved ? PlanVerdict.approved : PlanVerdict.revised);
      }
    }
  }

  /// Attaches the reports in a subagent results message to their cards.
  bool _reported(String text) {
    final reports = parseSubagentReports(text);
    if (reports.isEmpty) return false;
    for (final e in reports.entries) {
      final i = _byAction[e.key];
      if (i == null) continue;
      if (_items[i] case SubagentItem(:final step)) _items[i] = SubagentItem(step, report: e.value);
    }
    return true;
  }

  /// Attaches an answers message to the open question card.
  bool _answer(String text) {
    for (var i = _items.length - 1; i >= 0; i--) {
      final item = _items[i];
      if (item is UserTurn) return false;
      if (item is QuestionItem && item.answers == null) {
        final answers = parseAnswers(text, item.questions);
        if (answers == null) return false;
        _items[i] = QuestionItem(item.call, item.questions, answers);
        return true;
      }
    }
    return false;
  }
}

/// Whether [text] (a user-role message, mode and context notes split off)
/// came from the app or the harness rather than from the user: a compaction
/// continuation, a phase note, a background task's notification, subagent
/// reports, a research workflow's reports, or answers to a question card.
/// [TranscriptBuilder] shows none of these as a [UserTurn]; nor is any of
/// them a request a handoff finishes.
bool isHarnessNote(String text) {
  final t = unwrapNotice(text.trimLeft());
  return splitCompacted(t) != null ||
      t.startsWith('<$researchWorkflowTag') ||
      parsePhaseNote(t) != null ||
      parseTaskNotification(t) != null ||
      parseSubagentReports(t).isNotEmpty ||
      t.startsWith(answersHeading) ||
      t.startsWith(answersReasonLead);
}

/// A short label for a tool step ("Read lib/a.dart", "Ran flutter test").
String stepTitle(ActionCall call) {
  final path = call.str('path');
  return switch (call.actionKind) {
    'FileEditorAction' => switch (call.str('command')) {
      'view' => 'Read $path',
      'create' => 'Created $path',
      'undo_edit' => 'Undid edit to $path',
      _ => 'Edited $path',
    },
    'ReadFileAction' => 'Read ${call.str('file_path').isEmpty ? path : call.str('file_path')}',
    'WriteFileAction' when call.str('mode') == 'append' =>
      'Added to ${call.str('file_path').isEmpty ? path : call.str('file_path')}',
    'WriteFileAction' => 'Wrote ${call.str('file_path').isEmpty ? path : call.str('file_path')}',
    'BrowserAction' => browserStepTitle(call),
    'ScreenshotAction' => call.str('app').isEmpty ? 'Took a screenshot' : 'Took a screenshot of ${call.str('app')}',
    'EditAction' when call.str('patch_op') == 'delete' => 'Deleted $path',
    'EditAction' when call.str('patch_op') == 'move' => 'Moved ${call.str('from')} to $path',
    'EditAction' => 'Edited ${call.str('file_path').isEmpty ? path : call.str('file_path')}',
    'ApplyPatchAction' => 'Patched ${(call.action['paths'] as List<Object?>?)?.length ?? 0} files',
    'GrepAction' => 'Searched for ${call.str('pattern')}',
    'GlobAction' => 'Listed ${call.str('pattern')}',
    'ListDirectoryAction' => 'Listed ${call.str('dir_path').isEmpty ? path : call.str('dir_path')}',
    'TerminalAction' => call.str('command'),
    'MCPToolAction' => 'Used ${call.toolName}',
    'InvokeSkillAction' => 'Loaded the ${call.str('name')} skill',
    'MemoryAction' => call.str('reason').isEmpty ? 'Updated the project memory' : 'Remembered: ${call.str('reason')}',
    'ScriptAction' => call.str('description').isEmpty ? 'Ran a script' : call.str('description'),
    _ => call.summary.isNotEmpty ? call.summary : call.toolName,
  };
}

/// A browser step in the user's words: "Opened localhost:5173", "Clicked #start".
String browserStepTitle(ActionCall call) {
  String sel() => call.str('selector').isNotEmpty ? call.str('selector') : '(${call.action['x']}, ${call.action['y']})';
  return switch (call.str('action')) {
    'open' => 'Opened ${call.str('url').replaceFirst(RegExp(r'^https?://'), '')}',
    'click' => '${(call.action['count'] as num?) == 2 ? 'Double-clicked' : 'Clicked'} ${sel()}',
    'type' => 'Typed into ${call.str('selector').isEmpty ? 'the page' : call.str('selector')}',
    'press' => 'Pressed ${call.str('key')}',
    'scroll' => 'Scrolled the page',
    'wait' => call.str('selector').isEmpty ? 'Waited' : 'Waited for ${call.str('selector')}',
    'eval' => 'Ran a script in the page',
    'screenshot' => 'Took a screenshot of the page',
    'console' => 'Read the page\'s console',
    'resize' => 'Resized the page to ${call.action['width']}×${call.action['height']}',
    'close' => 'Closed the browser',
    _ => 'Used the browser',
  };
}

/// "Explored 2 files, 1 search".
String exploreSummary(List<ToolStep> steps) {
  var files = 0, searches = 0, commands = 0;
  for (final s in steps) {
    switch (s.call.actionKind) {
      case 'FileEditorAction' || 'ReadFileAction':
        files++;
      case 'GrepAction' || 'GlobAction' || 'ListDirectoryAction':
        searches++;
      case 'TerminalAction':
        final c = s.call.str('command').trimLeft();
        if (c.startsWith('grep') || c.startsWith('rg') || c.startsWith('find')) {
          searches++;
        } else {
          commands++;
        }
      default:
        commands++;
    }
  }
  String n(int count, String one, String many) => '$count ${count == 1 ? one : many}';
  return [
    if (files > 0) n(files, 'file', 'files'),
    if (searches > 0) n(searches, 'search', 'searches'),
    if (commands > 0) n(commands, 'command', 'commands'),
  ].join(', ');
}
