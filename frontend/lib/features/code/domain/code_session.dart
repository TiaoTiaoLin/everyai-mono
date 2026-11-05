import 'package:flutter/foundation.dart';

import '../git/git_models.dart';

import 'agent_mode.dart';
import '../settings/agent_prompt.dart' show HarnessTier;

/// A folder the agent works in.
@immutable
final class CodeProject {
  const CodeProject({required this.id, required this.name, required this.path});

  final String id;
  final String name;
  final String path;

  factory CodeProject.fromJson(Map<String, Object?> json) =>
      CodeProject(id: json['id']! as String, name: json['name']! as String, path: json['path']! as String);

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'path': path};
}

enum SessionStatus {
  starting('Starting'),
  running('Working'),
  needsInput('Needs input'),
  idle('Idle'),
  done('Done'),
  failed('Failed');

  const SessionStatus(this.label);
  final String label;
}

/// The stored harness name of sessions on the EveryAI harness (others are
/// in `drivers/driver_registry.dart`).
const everyaiHarnessName = 'everyai';

/// The stored harness name of sessions from the removed OpenHands harness.
const openHandsHarnessName = 'openHands';

/// A harness that led a session before and may lead it again: its
/// conversation (reopened with only what it missed, when its driver can
/// resume) and the model it ran on.
@immutable
final class LeadRecord {
  const LeadRecord({required this.conversationId, this.model = '', this.effort = ''});

  /// '' when there is none to reopen (it gets the whole handoff again).
  final String conversationId;
  final String model;
  final String effort;

  factory LeadRecord.fromJson(Map<String, Object?> json) => LeadRecord(
    conversationId: json['conversation_id'] as String? ?? '',
    model: json['model'] as String? ?? '',
    effort: json['effort'] as String? ?? '',
  );

  Map<String, Object?> toJson() => {'conversation_id': conversationId, 'model': model, 'effort': effort};
}

@immutable
final class CodeSessionInfo {
  const CodeSessionInfo({
    required this.id,
    required this.projectId,
    required this.title,
    required this.conversationId,
    required this.model,
    required this.mode,
    required this.workingDir,
    required this.createdAt,
    this.branch = '',
    this.worktree,
    this.baseline,
    this.harness = everyaiHarnessName,
    this.mainAgent = '',
    this.effort = '',
    this.holdClientTools = false,
    this.compactedFrom = const [],
    this.parentId,
    this.parentCallId = '',
    this.ownTag = false,
    this.ownApprovals = false,
    this.pinned = false,
    this.prNumber,
    this.forkCopy,
    this.tier = HarnessTier.efficient,
    this.leads = const {},
    this.pendingHandoff = '',
    this.nativeMode = '',
    this.pendingRewind = '',
    this.workflow,
    this.toldWorkflow,
  });

  final String id;
  final String projectId;
  final String title;

  /// The harness's conversation id.
  final String conversationId;
  final String model;
  final AgentMode mode;

  /// Where the agent works: the session's worktree, or the project folder
  /// when it isn't a git repository.
  final String workingDir;
  final String branch;

  /// The session's own checkout and branch, for isolated sessions (forks,
  /// subagents, Ultra steps, or when asked for); null when it works in place.
  final SessionWorktree? worktree;

  /// For a session working in place in a git repository: where it started,
  /// so Changes can show what it did.
  final GitBaseline? baseline;

  /// The driver it runs on: [everyaiHarnessName], another registered driver's
  /// id, or [openHandsHarnessName] for sessions from before that harness was
  /// removed (they can't reopen).
  final String harness;

  /// The harnesses that led this session before the current one ([harness],
  /// whose conversation, model and effort are the fields above), by driver
  /// id. Empty for a session that never switched.
  final Map<String, LeadRecord> leads;

  /// A handoff to the current lead not sent yet (the user switched from the
  /// menu): it goes out with their next message. '' when none.
  final String pendingHandoff;

  /// The lead's own mode, picked by its name (`NativeModes`), resent when the
  /// session reopens; '' for none (the EveryAI harness, or not picked). A
  /// lead switch clears it.
  final String nativeMode;

  /// The note telling a lead that kept the conversation that the files were
  /// rewound: it goes out with the next message, even after a restart. ''
  /// when none.
  final String pendingRewind;

  /// Started on a harness the app no longer has.
  bool get removedHarness => harness == openHandsHarnessName;

  /// The library agent running the session ('' for the EveryAI agent).
  final String mainAgent;

  /// The snapshot Changes diffs against: the worktree, or the in-place
  /// baseline's read-only view.
  SessionWorktree? get diffTarget => worktree ?? baseline?.diffView;

  /// The model's reasoning effort ('' for the server default).
  final String effort;

  /// How hard it works (the effort level); a fork keeps its parent's.
  final HarnessTier tier;

  /// The session-long workflow that is on ('max', the Max approach skill), or
  /// null. Script workflows run once and aren't kept here.
  final String? workflow;

  /// The session-long workflow the current lead was last told is on (see
  /// `maxWorkflowNote`), or null: when it differs from [workflow], the next
  /// message carries a note. A new lead hasn't been told anything.
  final String? toldWorkflow;

  /// Question cards and plans are answered inside the held tool call (see
  /// `SessionSpec.holdClientTools`). Off for sessions started before it.
  final bool holdClientTools;

  /// Conversations this session ran in before it was compacted, oldest first.
  final List<String> compactedFrom;
  final DateTime createdAt;

  /// For a subagent: the session that started it, and the id of its `run_subagent`
  /// call there. Subagents are left out of session lists.
  final String? parentId;
  final String parentCallId;

  /// A child billed under its own id rather than its parent's (an Ultra
  /// step or orchestrator), so its cost can be read alone.
  final bool ownTag;

  /// A child stricter than its parent (a read-only workflow agent, a
  /// `/review`): it neither uses nor adds to the "for this session"
  /// approvals its parent's other children share.
  final bool ownApprovals;

  /// Its approval card's "for this session" covers all the session's forks.
  bool get sharesApprovals => parentId != null && !ownApprovals;

  /// Kept at the top of the sidebar (Pinned) until unpinned.
  final bool pinned;

  /// The pull request opened for this session's branch, once there is one (the sidebar's PR badge).
  final int? prNumber;

  /// A fork's own worktree, merged back into the parent's folder when it
  /// finishes; null for a fork sharing the parent's folder.
  final ForkCopy? forkCopy;

  bool get isSubagent => parentId != null;

  /// An agent a workflow started (its call id is `wf-<run>-<key>`).
  bool get isWorkflowAgent => parentId != null && parentCallId.startsWith('wf-');

  /// The id its model calls are billed under (`X-EveryAI-Session`), and
  /// the tag its processes carry: its own, or its parent's for a subagent.
  String get billingTag => ownTag ? id : parentId ?? id;

  CodeSessionInfo copyWith({
    String? title,
    bool? pinned,
    int? prNumber,
    bool clearPr = false,
    AgentMode? mode,
    String? branch,
    String? conversationId,
    List<String>? compactedFrom,
    String? model,
    String? effort,
    HarnessTier? tier,
    String? harness,
    Map<String, LeadRecord>? leads,
    String? pendingHandoff,
    String? nativeMode,
    String? pendingRewind,
    bool merged = false,
    String? workflow,
    bool clearWorkflow = false,
    String? toldWorkflow,
    bool clearToldWorkflow = false,
  }) => CodeSessionInfo(
    id: id,
    projectId: projectId,
    title: title ?? this.title,
    conversationId: conversationId ?? this.conversationId,
    model: model ?? this.model,
    mode: mode ?? this.mode,
    workingDir: workingDir,
    createdAt: createdAt,
    branch: branch ?? this.branch,
    worktree: worktree,
    baseline: baseline,
    harness: harness ?? this.harness,
    mainAgent: mainAgent,
    effort: effort ?? this.effort,
    holdClientTools: holdClientTools,
    compactedFrom: compactedFrom ?? this.compactedFrom,
    parentId: parentId,
    parentCallId: parentCallId,
    ownTag: ownTag,
    ownApprovals: ownApprovals,
    pinned: pinned ?? this.pinned,
    prNumber: clearPr ? null : prNumber ?? this.prNumber,
    // Once merged back, the copy is gone.
    forkCopy: merged ? null : forkCopy,
    tier: tier ?? this.tier,
    leads: leads ?? this.leads,
    pendingHandoff: pendingHandoff ?? this.pendingHandoff,
    // Another lead's modes have other names.
    nativeMode: nativeMode ?? (harness != null && harness != this.harness ? '' : this.nativeMode),
    pendingRewind: pendingRewind ?? this.pendingRewind,
    workflow: clearWorkflow ? null : workflow ?? this.workflow,
    toldWorkflow: clearToldWorkflow ? null : toldWorkflow ?? this.toldWorkflow,
  );

  factory CodeSessionInfo.fromJson(Map<String, Object?> json) => CodeSessionInfo(
    id: json['id']! as String,
    projectId: json['project_id']! as String,
    title: json['title'] as String? ?? 'Session',
    conversationId: json['conversation_id']! as String,
    model: json['model'] as String? ?? '',
    mode: AgentMode.values.asNameMap()[json['mode']] ?? AgentMode.ask,
    workingDir: json['working_dir'] as String? ?? '',
    branch: json['branch'] as String? ?? '',
    effort: json['effort'] as String? ?? '',
    holdClientTools: json['hold_client_tools'] == true,
    compactedFrom: [
      for (final id in json['compacted_from'] as List<Object?>? ?? const [])
        if (id is String) id,
    ],
    worktree: json['worktree'] is Map<String, Object?>
        ? SessionWorktree.fromJson(json['worktree']! as Map<String, Object?>)
        : null,
    harness: json['harness'] as String? ?? openHandsHarnessName,
    mainAgent: json['main_agent'] as String? ?? '',
    baseline: json['baseline'] is Map<String, Object?>
        ? GitBaseline.fromJson(json['baseline']! as Map<String, Object?>)
        : null,
    createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ?? DateTime.now(),
    parentId: json['parent_id'] as String?,
    parentCallId: json['parent_call_id'] as String? ?? '',
    // Ultra children saved before the flag was kept billed under their own id too.
    pinned: json['pinned'] == true,
    prNumber: json['pr'] as int?,
    ownTag: json['own_tag'] == true || (json['parent_call_id'] as String? ?? '').startsWith('ultra-'),
    ownApprovals: json['own_approvals'] == true,
    forkCopy: ForkCopy.fromJson(json['fork_copy']),
    // Max and Ultra were tiers, and Bug fix a mode: Max is a workflow now, kept on the session; Ultra and Bug
    // fix run once, so those sessions go on as Thorough with none.
    tier: json['harness_mode'] == 'bugFix' ? HarnessTier.thorough : HarnessTier.parse(json['tier']),
    leads: {
      if (json['leads'] case final Map<String, Object?> leads)
        for (final MapEntry(:key, :value) in leads.entries)
          if (value case final Map<String, Object?> lead) key: LeadRecord.fromJson(lead),
    },
    pendingHandoff: json['pending_handoff'] as String? ?? '',
    nativeMode: json['native_mode'] as String? ?? '',
    pendingRewind: json['pending_rewind'] as String? ?? '',
    workflow: json['workflow'] as String? ?? (json['tier'] == 'max' ? 'max' : null),
    // An old Max session's lead never heard of the workflow, so it is told on the next message.
    toldWorkflow: json['told_workflow'] as String?,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'project_id': projectId,
    'title': title,
    'conversation_id': conversationId,
    'model': model,
    'mode': mode.name,
    'working_dir': workingDir,
    'branch': branch,
    'worktree': ?worktree?.toJson(),
    'baseline': ?baseline?.toJson(),
    'harness': harness,
    if (mainAgent.isNotEmpty) 'main_agent': mainAgent,
    'effort': effort,
    if (holdClientTools) 'hold_client_tools': true,
    if (compactedFrom.isNotEmpty) 'compacted_from': compactedFrom,
    'created_at': createdAt.toIso8601String(),
    'parent_id': ?parentId,
    if (parentCallId.isNotEmpty) 'parent_call_id': parentCallId,
    if (ownTag) 'own_tag': true,
    if (ownApprovals) 'own_approvals': true,
    if (pinned) 'pinned': true,
    'pr': ?prNumber,
    if (forkCopy case final f?) 'fork_copy': f.toJson(),
    'tier': tier.name,
    if (leads.isNotEmpty) 'leads': {for (final MapEntry(:key, :value) in leads.entries) key: value.toJson()},
    if (pendingHandoff.isNotEmpty) 'pending_handoff': pendingHandoff,
    if (nativeMode.isNotEmpty) 'native_mode': nativeMode,
    if (pendingRewind.isNotEmpty) 'pending_rewind': pendingRewind,
    'workflow': ?workflow,
    'told_workflow': ?toldWorkflow,
  };
}
