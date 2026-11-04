import 'package:flutter/foundation.dart';

import '../domain/agent_mode.dart';
import 'events.dart';

/// How an outside harness reaches EveryAI from inside its session: the MCP
/// server that offers our tools ([mcpUrl], with [mcpToken] as its bearer
/// token), the folder our skills are written to ([skillDir]) and the
/// session text that explains the session ([sessionSkill]: the Markdown from
/// `sessionBriefing(...)`, also saved as `session.md` next to the skills; a
/// driver hands it to the CLI's instructions slot as `BriefingInput.sessionText`).
@immutable
final class DriverBriefing {
  const DriverBriefing({required this.mcpUrl, required this.mcpToken, this.skillDir, this.sessionSkill});

  final String mcpUrl;
  final String mcpToken;
  final String? skillDir;
  final String? sessionSkill;
}

/// What a new coding session needs.
@immutable
final class SessionSpec {
  const SessionSpec({
    required this.workingDir,
    required this.model,
    required this.mode,
    required this.llmBaseUrl,
    required this.llmApiKey,
    required this.sessionTag,
    this.initialMessage,
    this.runInitial = true,
    this.maxInputTokens,
    this.maxOutputTokens = 64000,
    this.vision = false,
    this.initialImages = const [],
    this.persona,
    this.promptSuffix,
    this.effort,
    this.holdClientTools = false,
    this.subagent = false,
    this.mcpConfig = const {},
    this.skills = const [],
    this.tools,
    this.rolePrompt,
    this.clientTools,
    this.autoCompactAt = 0.6,
    this.pathMap = const {},
    this.researchSites,
    this.phaseFlow,
    this.script,
    this.reviewModel,
    this.briefing,
  });

  /// What an outside harness (a coding CLI driven by the app) is handed to
  /// reach EveryAI's own tools and the session's skill; null for the EveryAI
  /// harness, which has them built in.
  final DriverBriefing? briefing;

  /// 'max' or 'ultra': the session runs the phase flow (research → questions
  /// → plan → build → verify) the harness enforces. Null: it doesn't.
  final String? phaseFlow;

  /// A research job's sandbox: no shell, MCP or writes outside its scratch
  /// folder, no secret files, and the web only on these sites. Null: not one.
  final List<String>? researchSites;

  /// Folders the conversation mentions and where they are for this session:
  /// a fork in its own worktree inherits the parent's paths, which its tools
  /// read as the copy's (`{parent folder: copy}`).
  final Map<String, String> pathMap;

  /// The session's worktree.
  final String workingDir;

  /// OpenRouter model id (`anthropic/claude-sonnet-5.5`).
  final String model;
  final AgentMode mode;

  /// The EveryAI gateway (`…/v1`) and the user's gateway key.
  final String llmBaseUrl;
  final String llmApiKey;

  /// Sent as `X-EveryAI-Session` so usage is attributed to the session.
  final String sessionTag;
  final String? initialMessage;

  /// Whether [initialMessage] starts the agent; off, it waits for the next
  /// message (a compacted session's summary, say).
  final bool runInitial;

  /// The model's context window, so the agent condenses its history in time.
  final int? maxInputTokens;

  /// Room for thinking plus a whole-file edit in one reply.
  final int maxOutputTokens;

  /// The model reads images: the harness passes them on instead of dropping them.
  final bool vision;

  /// `data:` URLs sent with [initialMessage].
  final List<String> initialImages;

  /// The persona at the start of the system prompt (see `agentPersona`);
  /// null keeps the harness's default.
  final String? persona;

  /// Appended to the system prompt; defaults to `workingRules`.
  final String? promptSuffix;

  /// Reasoning effort: low, medium, high, xhigh or max (null: the server's).
  final String? effort;

  /// Question cards and plans are held for confirmation and answered inside
  /// the call (a rejection whose reason carries the reply, then a run), so
  /// the agent keeps its turn. Off: the agent ends its turn and the reply is
  /// a new user message.
  final bool holdClientTools;

  /// A child conversation started by another session's `run_subagent` call: no
  /// client tools (so it can't ask the user or start subagents of its own),
  /// and `subagentRules` after the prompt suffix.
  final bool subagent;

  /// The session's `mcp_config`: user-configured MCP servers by name
  /// (see `StoredMcpServers.mcpConfigFor`). Empty: no MCP tools.
  final Map<String, Object?> mcpConfig;

  /// Agent Skills in OpenHands' `Skill` shape (see `openHandsSkill`), listed
  /// in the prompt. The app picks them (enabled, and trusted for project
  /// skills).
  final List<Map<String, Object?>> skills;

  /// The tools the agent keeps (`terminal`, `file_editor`, `task_tracker`,
  /// `mcp`); null keeps all. Set by a library agent (see `childSetup`).
  final List<String>? tools;

  /// A library agent's instructions, after `subagentRules` in a child's
  /// system prompt.
  final String? rolePrompt;

  /// The client tools it gets instead of the usual ones (an Ultra
  /// orchestrator's `ultra_plan`); null keeps the defaults.
  final List<Map<String, Object?>>? clientTools;

  /// The share of [maxInputTokens] at which the EveryAI harness compacts the
  /// history in place (0 turns it off).
  final double autoCompactAt;

  /// What `run_script` programs may spend (the tier's defaults, see
  /// `scriptCapsFor`); null: the EveryAI harness offers no run_script.
  final ScriptCaps? script;

  /// Bug fix mode: the model that reviews a step the harness's own check
  /// refused (`bug_check review`): another vendor's when the user has one,
  /// so it isn't the same model marking its own work. Null: the session's.
  final String? reviewModel;
}

/// The session's model helpers: whether it offers `run_script` at all
/// ([enabled]), per-script limits on [decides] fast typed decisions and
/// [queries] cheap-model reads (0: llmQuery is off), [depth] 2 letting an
/// llmQuery write scripts of its own, and [smartCompaction] having old tool
/// output scored before it is cleared.
@immutable
final class ScriptCaps {
  const ScriptCaps({
    this.enabled = true,
    this.decides = 20,
    this.queries = 0,
    this.depth = 1,
    this.timeoutSeconds = 120,
    this.smartCompaction = false,
  });

  final bool enabled;
  final int decides;
  final int queries;
  final int depth;
  final int timeoutSeconds;
  final bool smartCompaction;

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'decides': decides,
    'queries': queries,
    'depth': depth,
    'timeout_seconds': timeoutSeconds,
    'smart_compaction': smartCompaction,
  };

  static ScriptCaps? fromJson(Object? j) => j is Map<String, Object?>
      ? ScriptCaps(
          enabled: j['enabled'] != false,
          decides: (j['decides'] as num?)?.toInt() ?? 20,
          queries: (j['queries'] as num?)?.toInt() ?? 0,
          depth: (j['depth'] as num?)?.toInt() ?? 1,
          timeoutSeconds: (j['timeout_seconds'] as num?)?.toInt() ?? 120,
          smartCompaction: j['smart_compaction'] == true,
        )
      : null;

  @override
  bool operator ==(Object other) =>
      other is ScriptCaps &&
      other.enabled == enabled &&
      other.decides == decides &&
      other.queries == queries &&
      other.depth == depth &&
      other.timeoutSeconds == timeoutSeconds &&
      other.smartCompaction == smartCompaction;

  @override
  int get hashCode => Object.hash(enabled, decides, queries, depth, timeoutSeconds, smartCompaction);
}

/// A running agent conversation. Events arrive on [events] (history first,
/// then live); the methods steer it.
abstract interface class HarnessSession {
  String get id;
  Stream<HarnessEvent> get events;

  /// Sends a user message, with [images] as `data:` URLs. [run] starts the
  /// agent if it is idle.
  Future<void> send(String text, {bool run = true, List<String> images = const []});

  /// Stops the current step (the agent can continue with a new message).
  Future<void> interrupt();
  Future<void> pause();
  Future<void> resume();

  /// Answers the pending actions that need approval: those in [callIds]
  /// (action ids) or, without, all still undecided. Sessions that aren't
  /// [PerCallApprovals] answer the whole batch whatever [callIds] says.
  Future<void> respond({required bool accept, String? reason, List<String>? callIds});

  /// Changes the confirmation policy; [holdClientTools] as in [SessionSpec].
  Future<void> setMode(AgentMode mode, {bool holdClientTools = false});

  /// Moves the conversation to [spec]'s model and effort (its LLM fields are
  /// read; the rest is ignored). The history stays; the next model call uses it.
  Future<void> switchLlm(SessionSpec spec);

  /// Moves the conversation's head back to the event [head] (null: the empty
  /// tree), so the agent forgets everything after it; the next message
  /// starts a new branch there (see `domain/rewind.dart`). Only while the
  /// agent is idle. History replayed to new listeners keeps to the new branch.
  Future<void> rewindTo(String? head);
  Future<void> close();
}

/// A session that can answer a question from its own model and history
/// without it becoming part of the conversation (the EveryAI harness): the
/// goal check reads the session with the cached prefix instead of a summary.
abstract interface class AsksAside {
  Future<String> askAside(String question, {int maxTokens = 800});
}

/// A session running the Max or Ultra phase flow (the EveryAI harness).
abstract interface class PhasedSession {
  /// Moves the flow past the phase it is stuck in.
  Future<void> skipPhase();

  /// Starts ('max' or 'ultra', at research) or stops (null) the flow.
  Future<void> setPhaseFlow(String? flow);
}

/// A session that takes one answer per pending call (the EveryAI harness):
/// allowed calls run, refused ones go back to the model as refusals, and the
/// run carries on; only refusing every call at once (no [callIds]) parks it.
abstract interface class PerCallApprovals {}

/// A session that retries failed model calls itself (the EveryAI harness):
/// the user can cut the wait before the next attempt short.
abstract interface class RetriesModelCalls {
  void retryNow();
}

/// A session that compacts its own history in place (the EveryAI harness):
/// `/compact` asks it instead of starting a continuation conversation.
abstract interface class CompactsInPlace {
  /// False when there was nothing to summarize or the summary was unusable.
  Future<bool> compact({String focus = ''});
}

/// A command a session left running in the background.
typedef BackgroundTask = ({
  String id,
  String command,
  String description,
  bool running,
  int? exitCode,
  DateTime startedAt,
});

/// A session whose background shells the app can list and stop (the EveryAI
/// harness).
abstract interface class HasBackgroundShells {
  List<BackgroundTask> get backgroundTasks;
  Future<void> stopBackground(String id);
}

/// A session that takes a message into the turn that is running, without
/// stopping it (a harness with native steering). Others are interrupted and
/// sent the message (see `steerOrResend`).
abstract interface class SteersRuns {
  Future<void> steer(String text, {List<String> images = const []});
}

/// A harness that can start a session from another one's history (the
/// EveryAI harness).
abstract interface class ForksSessions {
  /// A new session that starts from [parentConversationId]'s history up to
  /// now, then [spec]'s initial message as the directive.
  Future<HarnessSession> fork(String parentConversationId, SessionSpec spec);
}

/// A harness that reopens a session with a fresh [DriverBriefing]: an
/// outside CLI started again after the app restarts needs a new host token
/// (the old one died with the app). Without it, a reopened session has no
/// EveryAI tools. [mcpConfig] is the user's approved MCP servers; a driver that
/// can deliver them on reopen does, the others ignore it.
abstract interface class AttachesBriefed {
  Future<HarnessSession> attachBriefed(
    String conversationId,
    DriverBriefing briefing, {
    Map<String, Object?> mcpConfig = const {},
  });
}

/// Starts and reopens agent sessions.
abstract interface class Harness {
  Future<HarnessSession> start(SessionSpec spec);
  Future<HarnessSession> attach(String conversationId);

  /// The execution status of each of [conversationIds] the server knows,
  /// without opening their event streams (for session lists).
  Future<Map<String, ExecutionStatus>> statuses(List<String> conversationIds);
}

/// A harness call that failed: the message is shown as is.
final class HarnessError implements Exception {
  const HarnessError(this.message, {this.status});
  final String message;

  /// The HTTP status, for server errors.
  final int? status;

  @override
  String toString() => message;
}
