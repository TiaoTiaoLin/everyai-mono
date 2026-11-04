import 'dart:async';
import 'dart:convert';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/preferences.dart';
import '../../core/providers.dart';
import '../agents/agents_providers.dart' show AgentDefinition, agentLibrarySettingsProvider, childSetup, codeAgentsFor;
import '../attachments/attachment.dart';
import '../models/domain/model_catalog.dart';
import '../billing/billing_providers.dart' show formatMicros;
import '../models/models_providers.dart';
import '../settings/byok_keys.dart' show byokUltraCapProvider;
import '../settings/domain/byok_providers.dart' show ModelBilling;
import '../skills/data/skill_import.dart' show findImportCandidates;
import '../skills/data/skill_store.dart' show folderFiles;
import '../skills/domain/skill_catalog.dart' show InstalledSkill;
import '../skills/skills_providers.dart' show codeInstalledSkillsFor, codeSkillsFor, installedSkillsProvider;
import '../slash/skills/learn.dart';
import '../slash/skills/learn_sources.dart';
import '../slash/skills/skill_draft.dart' show skillDrafterProvider;
import '../usage/usage_totals.dart';
import 'domain/agent_mode.dart';
import 'domain/code_session.dart';
import 'domain/compaction.dart';
import 'domain/doom_loop.dart';
import 'domain/git_commands.dart';
import 'domain/goal.dart';
import 'domain/no_spend.dart';
import 'domain/review.dart';
import 'domain/rewind.dart';
import 'domain/spill.dart';
import 'domain/phases.dart'
    show
        Phase,
        bugCheckTool,
        flowLabel,
        isResearchWorker,
        maxResearchAtOnce,
        parseResearchAngles,
        researchAnglesQuestion,
        researchCallPrefix,
        researchTimeout,
        researchWorkflowMessage;
import 'domain/fork_files.dart';
import 'domain/subagents.dart';
import 'domain/questions.dart';
import 'domain/session_commands.dart';
import 'domain/transcript.dart';
import 'gateway_key.dart';
import 'agent_models.dart' show codeAgentProvider;
import 'drivers/usage_limit.dart';
import 'handoff/handoff.dart';
import 'handoff/handoff_git.dart';
import 'handoff/handoff_store.dart';
import 'handoff/lead_timeline.dart';
import 'git/git_service.dart';
import 'domain/transcript_export.dart';
import 'drivers/acp/acp_driver.dart' show AcpDriver;
import 'drivers/briefing/briefing_types.dart' show everyaiServerName;
import 'drivers/briefing/session_skill.dart';
import 'drivers/briefing/skill_export.dart';
import 'drivers/briefing/skill_render.dart' show defuseInlineCommands;
import 'drivers/driver.dart';
import 'drivers/driver_policy.dart';
import 'drivers/driver_process.dart' show closeAllDriverProcesses;
import 'drivers/driver_registry.dart';
import 'harness/everyai/everyai.dart';
import 'harness/events.dart';
import 'harness/fake_harness.dart';
import 'harness/harness.dart';
import 'harness/session_processes.dart';
import 'harness/summarizer.dart';
import 'host/host.dart';
import 'host/host_notes.dart';
import 'host/host_providers.dart';
import 'code_settings_providers.dart' show codeSettingsProvider, withSystemPrompts;
import 'mcp_providers.dart';
import 'permissions_providers.dart';
import 'settings/context_files.dart';
import 'settings/script_caps.dart';
import 'settings/settings.dart';
import 'session_notifications.dart';
import 'spill/spill.dart';
import 'uploads/uploads.dart';

part 'session_builtins.dart';

/// Projects under this scheme run on the scripted [FakeHarness].
const demoScheme = 'demo://';

bool isDemoPath(String path) => path.startsWith(demoScheme);

/// Sessions whose folder isn't on this machine (the scripted demo). Local
/// files, git and processes are skipped for them.
bool noLocalFolder(String path) => isDemoPath(path);

/// The scripted harness for demo projects.
final harnessProvider = Provider<Harness>((ref) => FakeHarness());

/// The harness a session in [workingDir] runs on: the scripted one for demo
/// projects, else the driver stored as [harness] (see `driver_registry.dart`).
/// Sessions from the removed OpenHands harness can't reopen.
Future<Harness> harnessFor(Ref ref, String workingDir, {String harness = everyaiHarnessName}) async {
  if (isDemoPath(workingDir)) return ref.read(harnessProvider);
  if (harness == openHandsHarnessName) throw const HarnessError(removedHarnessNotice);
  return ref.read(driverRegistryProvider).resolve(harness) ??
      (throw HarnessError("This session ran on $harness, which this version of the app doesn't have."));
}

/// What a session from the removed OpenHands harness shows instead of its history.
const removedHarnessNotice =
    'This session ran on the OpenHands harness, which was removed, so it can\'t be reopened. Start a new session.';

/// Whether a session on [harness] in [workingDir] runs on an outside agent
/// (a coding CLI the app drives) rather than the EveryAI harness or the demo.
/// Where the approval card asks the backend's decider for a risk label on a
/// command of [info]: its folder, or null for none (the demo's commands
/// never run, and an outside lead spends nothing of EveryAI's).
String? riskLabelDir(CodeSessionInfo info) =>
    isDemoPath(info.workingDir) || isOutsideLead(info.harness, info.workingDir) ? null : info.workingDir;

bool isOutsideLead(String harness, String workingDir) =>
    harness != everyaiHarnessName && harness != openHandsHarnessName && !isDemoPath(workingDir);

/// Why [info] may not run yet: a subscription CLI needs the user's
/// "Use my own installed CLIs" for it ([ownClis]). Null when it may.
String? consentProblem(DriverInfo info, Set<String> ownClis) => info.needsConsent && !ownClis.contains(info.consentId)
    ? "Turn on 'Use my own installed CLIs' for ${info.label} in Settings → Code to use it."
    : null;

/// The harnesses in [listed] a session on [current] can move to now:
/// nothing in their way ([leadBlocked]: checked, installed, signed in, and
/// allowed by the user's "Use my own installed CLIs", [ownClis]).
List<DriverInfo> readyLeads(
  Iterable<HarnessDriver> listed,
  Map<String, DriverStatus>? statuses,
  Set<String> ownClis, {
  required String current,
}) => [
  for (final d in listed)
    if (d.info.id != current &&
        leadBlocked(d.info, statuses?[d.info.id], consented: ownClis.contains(d.info.consentId)) == null)
      d.info,
];

/// The note a session shows when its outside agent's EveryAI tools expired.
const hostToolsExpired =
    "This session's EveryAI tools (question cards, plans, project memory) expired after a long idle time. Start a "
    'new session to use them again.';

/// Where the app keeps its data (`GitService.dataDir`); outside sessions'
/// briefings go under `<it>/driver-sessions/<session id>`. Tests point it
/// at a temporary folder.
final driverDataDirProvider = Provider<Future<String> Function()>((ref) => GitService.dataDir);

/// The host token of each outside session opened in this run, by session
/// id. Never stored: tokens die with the app.
final _hostTokensProvider = Provider<Map<String, String>>((ref) => {});

/// What the session text tells an outside agent about each host tool, in
/// `hostToolSpecs` order. bug_check is left out until outside agents get Bug
/// fix mode.
const _hostToolInfos = <HostToolInfo>[
  (
    name: askUserQuestionTool,
    when:
        'a decision is the user\'s to make (scope, design, trade-offs) and the code can\'t answer it. The call '
        'waits while they answer in the app; the answers are its result.',
  ),
  (
    name: presentPlanTool,
    when:
        'in Plan mode, once the plan is ready. The call waits while the user reads it; the result says whether they '
        'approved it (build it then) or want changes.',
  ),
  (
    name: 'memory',
    when:
        'you learned something a later session would otherwise rediscover: how to build and test, conventions the '
        'user stated, pitfalls and their fixes.',
  ),
  (name: savedPlansTool, when: 'the task continues earlier work: list and read the plans the user approved before.'),
];

/// Ends the outside CLIs and the MCP host when the app quits (provider
/// disposal doesn't run then). The shell listens to it from app start, so
/// every CLI is covered, however it was spawned.
final driverShutdownProvider = Provider<void>((ref) {
  Future<void> closeAll() => closeAllDriverProcesses().timeout(const Duration(seconds: 3), onTimeout: () {});
  final lifecycle = AppLifecycleListener(
    onExitRequested: () async {
      await closeAll();
      await ref.read(hostServerProvider).stop();
      return AppExitResponse.exit;
    },
    onDetach: () => unawaited(closeAll()),
  );
  ref.onDispose(lifecycle.dispose);
});

/// The lead harness new sessions start on, and the model and effort picked
/// for each outside one (Preferences `code.lead`). The EveryAI harness's
/// model stays in `codeAgentProvider`.
final codeLeadProvider = NotifierProvider<CodeLead, CodeLeadChoice>(CodeLead.new);

@immutable
final class CodeLeadChoice {
  const CodeLeadChoice({this.harness = everyaiHarnessName, this.models = const {}});

  /// The driver id (`DriverInfo.id`).
  final String harness;

  /// Driver id → its model ('' its default) and effort ('' the model's).
  final Map<String, ({String model, String effort})> models;

  ({String model, String effort}) of(String harness) => models[harness] ?? (model: '', effort: '');
}

final class CodeLead extends Notifier<CodeLeadChoice> {
  static const key = 'code.lead';

  @override
  CodeLeadChoice build() {
    final raw = ref.read(preferencesProvider)[key];
    if (raw == null) return const CodeLeadChoice();
    try {
      final json = jsonDecode(raw);
      if (json is! Map<String, Object?>) return const CodeLeadChoice();
      return CodeLeadChoice(
        harness: json['harness'] as String? ?? everyaiHarnessName,
        models: {
          if (json['models'] case final Map<String, Object?> models)
            for (final MapEntry(:key, :value) in models.entries)
              if (value case final Map<String, Object?> m)
                key: (model: m['model'] as String? ?? '', effort: m['effort'] as String? ?? ''),
        },
      );
    } on FormatException {
      return const CodeLeadChoice();
    }
  }

  void _set(CodeLeadChoice next) {
    state = next;
    ref.read(preferencesProvider)[key] = jsonEncode({
      'harness': next.harness,
      'models': {
        for (final MapEntry(:key, :value) in next.models.entries) key: {'model': value.model, 'effort': value.effort},
      },
    });
  }

  void chooseHarness(String harness) => _set(CodeLeadChoice(harness: harness, models: state.models));

  void chooseModel(String harness, String model, String effort) =>
      _set(CodeLeadChoice(harness: state.harness, models: {...state.models, harness: (model: model, effort: effort)}));
}

/// An outside driver's own models (empty for the EveryAI harness, whose
/// models come from the catalog, and while a driver can't list them).
/// Not kept once unwatched, so a CLI signed in since lists its models.
final driverModelsProvider = FutureProvider.autoDispose.family<List<DriverModel>, String>((ref, id) async {
  try {
    return await ref.read(driverRegistryProvider).resolve(id)?.models() ?? const [];
  } on Object {
    return const [];
  }
});

/// What an outside session's calls to the host reach: its controller
/// ([controller], null once the session is gone), after the session is
/// saved ([ready]); the token is minted before that.
final class _HostForward implements HostTools {
  _HostForward(this.controller, this.ready);

  final CodeSessionController? Function() controller;
  final Future<void> ready;

  @override
  Future<HostResult> call(HostCall call) async {
    await ready;
    final c = controller();
    if (c == null) return (text: 'Error: this session is closed.', isError: true);
    return c.call(call);
  }
}

/// A host call that waits for the user, and the card (the agent's own row
/// for the call, by action id) it is answered on.
final class _HostWait {
  _HostWait(this.call);

  final HostCall call;
  final done = Completer<HostResult>();
  String? row;
}

/// The EveryAI harness: the agent loop in the app, sessions kept under App
/// Support.
final everyaiHarnessProvider = Provider<Harness>(
  (ref) => everyAIHarness(dataDir: GitService.dataDir, gatewayKey: () => gatewayKey(ref)),
);

/// The user's `sk-eai-` key for the backend's OpenAI-compatible gateway; the
/// harness sends its LLM calls there. Kept in the keychain (see [GatewayKeys]).
Future<String> gatewayKey(Ref ref) => ref.read(gatewayKeysProvider).key();

/// The backend's OpenAI-compatible gateway (`…/v1`), the agent's LLM provider.
String gatewayBaseUrl(Ref ref) => ref.read(appConfigProvider).apiBaseUrl.resolve('v1').toString();

/// A user message on its way to the agent: text (with the attachments note)
/// and the images the model can see.
@immutable
final class Outgoing {
  const Outgoing(this.text, {this.images = const []});
  final String text;
  final List<String> images;
}

bool _sees(Ref ref, String model) =>
    ref.read(modelCatalogProvider)[ModelId(model)]?.accepts(AttachmentKind.image) ?? false;

/// Saves [files] into the project and builds the message that points the agent
/// at them. Demo projects have no folder: the note alone.
Future<Outgoing> prepareMessage(
  Ref ref, {
  required String text,
  required String workingDir,
  required String model,
  List<Attachment> files = const [],
}) async {
  if (files.isEmpty) return Outgoing(text);
  final paths = noLocalFolder(workingDir) ? [for (final f in files) f.name] : await saveUploads(workingDir, files);
  final note = attachedNote(paths);
  return Outgoing(
    text.isEmpty ? note : '$text\n\n$note',
    images: _sees(ref, model)
        ? [
            for (final f in files)
              if (f.kind == AttachmentKind.image) f.dataUrl,
          ]
        : const [],
  );
}

/// Sessions started in this run of the app, by session id.
final _liveProvider = Provider<Map<String, HarnessSession>>((ref) => {});

/// Folders the user opened as projects (stored in preferences).
final codeProjectsProvider = NotifierProvider<CodeProjects, List<CodeProject>>(CodeProjects.new);

final class CodeProjects extends Notifier<List<CodeProject>> {
  static const _key = 'code.projects';

  @override
  List<CodeProject> build() {
    final raw = ref.read(preferencesProvider)[_key];
    if (raw == null) return const [];
    return [for (final p in jsonDecode(raw) as List<Object?>) CodeProject.fromJson(p! as Map<String, Object?>)];
  }

  void _save() => ref.read(preferencesProvider)[_key] = jsonEncode([for (final p in state) p.toJson()]);

  CodeProject add(String path, {String? name}) {
    final existing = state.where((p) => p.path == path).firstOrNull;
    if (existing != null) return existing;
    final project = CodeProject(
      id: const Uuid().v7(),
      name: name ?? path.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).lastOrNull ?? path,
      path: path,
    );
    state = [project, ...state];
    _save();
    return project;
  }

  void remove(String id) {
    state = [
      for (final p in state)
        if (p.id != id) p,
    ];
    _save();
  }
}

/// Every coding session, newest first (stored in preferences; transcripts
/// live with the harness, under App Support).
final codeSessionsProvider = NotifierProvider<CodeSessions, List<CodeSessionInfo>>(CodeSessions.new);

final class CodeSessions extends Notifier<List<CodeSessionInfo>> {
  static const _key = 'code.sessions';

  @override
  List<CodeSessionInfo> build() {
    final raw = ref.read(preferencesProvider)[_key];
    if (raw == null) return const [];
    return [for (final s in jsonDecode(raw) as List<Object?>) CodeSessionInfo.fromJson(s! as Map<String, Object?>)];
  }

  void _save() => ref.read(preferencesProvider)[_key] = jsonEncode([for (final s in state) s.toJson()]);

  CodeSessionInfo? byId(String id) => state.where((s) => s.id == id).firstOrNull;

  /// Starts a session on [project] with [prompt] as the first message.
  Future<CodeSessionInfo> start({
    required CodeProject project,
    required String prompt,
    required String model,
    required AgentMode mode,
    String? effort,
    List<Attachment> files = const [],
    bool isolated = false,
    HarnessTier? tier,
    HarnessMode? harnessMode,
    String harness = everyaiHarnessName,
  }) async {
    final id = const Uuid().v7();
    harnessMode ??= ref.read(codeSettingsProvider).harnessMode;
    final title = titleFor(prompt.isEmpty ? files.first.name : prompt);
    // Sessions work in the project folder itself, in a real shell, unless asked
    // to be isolated (then a worktree on its own branch). A remote host's
    // folder can't be branched or snapshotted from here.
    final local = !noLocalFolder(project.path);
    final runner = await harnessFor(ref, project.path, harness: harness);
    final driver = runner is HarnessDriver && isOutsideLead(harness, project.path) ? runner : null;
    // Before anything is made for the session.
    if (driver != null) {
      if (consentProblem(driver.info, ref.read(codeSettingsProvider).ownClis) case final why?) throw HarnessError(why);
    }
    final worktree = local && isolated ? await _worktreeFor(project, title, id) : null;
    final baseline = local && worktree == null ? await _baselineFor(project.path) : null;
    final workingDir = worktree?.path ?? project.path;
    tier ??= ref.read(codeSettingsProvider).tier;
    if (driver != null) {
      // Max, Ultra and Bug fix need the EveryAI harness's phase control; outside agents get them later.
      if (tier.phased) tier = HarnessTier.thorough;
      harnessMode = HarnessMode.build;
    }
    // The scripted demo answers client tools with new messages, not inside the call.
    final hold = !isDemoPath(project.path);
    // An outside agent's host calls wait until the session is saved below.
    final saved = Completer<void>();
    final HarnessSession live;
    try {
      final first = await prepareMessage(ref, text: prompt, workingDir: workingDir, model: model, files: files);
      final briefing = driver == null
          ? null
          : await _brief(
              id,
              projectDir: project.path,
              workingDir: workingDir,
              driver: driver,
              model: model,
              ready: saved.future,
            );
      try {
        live = await runner.start(
          await specFor(
            sessionId: id,
            projectDir: project.path,
            workingDir: workingDir,
            model: model,
            mode: mode,
            effort: effort,
            holdClientTools: hold,
            initialMessage: modeNote(mode, first.text),
            initialImages: first.images,
            isolated: worktree != null,
            tier: tier,
            harnessMode: harnessMode,
            harness: harness,
            briefing: briefing,
          ),
        );
      } on Object {
        if (briefing != null) await _unbrief(id);
        rethrow;
      }
    } on Object {
      // A session that didn't start leaves no branch behind.
      if (worktree != null) await _dropWorktree(worktree);
      rethrow;
    } finally {
      saved.complete();
    }
    ref.read(_liveProvider)[id] = live;
    final info = CodeSessionInfo(
      id: id,
      projectId: project.id,
      title: title,
      conversationId: live.id,
      model: model,
      mode: mode,
      workingDir: workingDir,
      createdAt: DateTime.now(),
      branch: worktree?.branch ?? baseline?.branch ?? '',
      worktree: worktree,
      baseline: baseline,
      harness: harness,
      effort: effort ?? '',
      holdClientTools: hold,
      tier: tier,
      harnessMode: harnessMode,
    );
    state = [info, ...state];
    _save();
    return info;
  }

  /// What a conversation for session [sessionId] starts with. A session
  /// that is compacted gets the same system prompt and tools again, so the
  /// model's cached prefix still holds.
  Future<SessionSpec> specFor({
    required String sessionId,
    required String projectDir,
    required String workingDir,
    required String model,
    required AgentMode mode,
    required bool holdClientTools,
    String? effort,
    String? initialMessage,
    List<String> initialImages = const [],
    bool runInitial = true,
    bool subagent = false,
    String? sessionTag,
    List<String>? tools,
    String? rolePrompt,
    List<Map<String, Object?>>? clientTools,
    bool isolated = false,
    Map<String, String> pathMap = const {},
    HarnessTier? tier,
    HarnessMode? harnessMode,
    List<String>? researchSites,
    String? harness,
    DriverBriefing? briefing,
  }) async {
    final demo = isDemoPath(projectDir);
    // An outside agent brings its own prompt, model, keys and skill loading: none of the EveryAI harness's parts apply.
    final outside = isOutsideLead(harness ?? byId(sessionId)?.harness ?? everyaiHarnessName, projectDir);
    // A session's own tier and mode; a new one's come from the caller, else the defaults.
    tier ??= byId(sessionId)?.tier ?? ref.read(codeSettingsProvider).tier;
    harnessMode ??= byId(sessionId)?.harnessMode ?? HarnessMode.build;
    final bugFix = harnessMode == HarnessMode.bugFix;
    // The demo and remote hosts have no local folder: the server's default prompt, no project files.
    final local = !noLocalFolder(projectDir) && !outside;
    final projectId = ref.read(codeProjectsProvider).where((p) => p.path == projectDir).firstOrNull?.id;
    // The agents it may start (a subagent can't start any): built-in, global, and trusted project ones.
    final agents = !local || subagent ? const <AgentDefinition>[] : await _agentsFor(projectId);
    // Settings and commit style come from the main checkout (local settings aren't in worktrees).
    final agentPrompt = !local
        ? null
        : await agentPromptFor(
            projectDir,
            agents: [for (final a in agents) (name: a.name, description: a.oneLine)],
            isolated: isolated,
            tier: tier,
            // Only a main session forks (forks are one level deep).
            forks: !subagent,
            models: !subagent ? _childModels(model) : const {},
            harnessMode: harnessMode,
          );
    // AGENTS.md and friends from the project folder up to the repository root.
    final context = !local ? const <ContextFile>[] : await _startContext(workingDir, projectDir);
    // MCP servers come from the app's list (global plus this project's), never from repository files. An
    // outside agent gets them too, except one named like the app's own host.
    final mcpConfig = noLocalFolder(projectDir)
        ? const <String, Object?>{}
        : {...ref.read(codeMcpServersProvider).mcpConfigFor(projectId)};
    if (outside) mcpConfig.remove(everyaiServerName);
    // Skills likewise: the app's enabled ones, and project skills only once trusted.
    final skills = !local ? const <Map<String, Object?>>[] : await codeSkillsFor(ref, projectId);
    return SessionSpec(
      workingDir: workingDir,
      model: model,
      mode: mode,
      llmBaseUrl: demo || outside ? '' : gatewayBaseUrl(ref),
      llmApiKey: demo || outside ? '' : await gatewayKey(ref),
      sessionTag: sessionTag ?? sessionId,
      initialMessage: initialMessage,
      initialImages: initialImages,
      runInitial: runInitial,
      vision: _sees(ref, model),
      maxInputTokens: ref.read(modelCatalogProvider)[ModelId(model)]?.contextLength,
      persona: agentPrompt?.persona,
      promptSuffix: agentPrompt == null
          ? null
          : withSystemPrompts(
              withProjectContext(agentPrompt.suffix, context),
              global: ref.read(codeSettingsProvider).globalPrompt,
              project: projectId == null ? '' : ref.read(codeSettingsProvider).promptFor(projectId),
            ),
      effort: effort == null || effort.isEmpty ? null : effort,
      holdClientTools: holdClientTools,
      subagent: subagent,
      mcpConfig: mcpConfig,
      skills: skills,
      tools: tools,
      rolePrompt: rolePrompt,
      researchSites: researchSites,
      // Only a main session runs the Max or Ultra flow.
      phaseFlow: subagent || outside
          ? null
          : bugFix
          ? (tier == HarnessTier.ultra ? 'bugfix-ultra' : 'bugfix')
          : tier.phased
          ? tier.name
          : null,
      // Bug fix's second opinion (the mode can be switched on later, so every main session gets one).
      reviewModel: subagent || outside ? null : bugReviewModel(model, ref.read(libraryProvider).value ?? const []),
      clientTools: clientTools,
      autoCompactAt: ref.read(codeSettingsProvider).autoCompactPercent / 100,
      // run_script and the decider: the tier's limits, or the user's level.
      script: !demo && !outside ? scriptCapsFor(tier, model, level: ref.read(codeSettingsProvider).scripts) : null,
      pathMap: pathMap,
      briefing: briefing,
    );
  }

  /// Hands outside session [id] what its agent needs to reach EveryAI: a
  /// host token for its calls (answered once [ready]), and the briefing
  /// folder under the app's data (our skills, and the session text with the
  /// project's notes). Throws when the user hasn't let the app run this CLI.
  /// The session's current token is revoked first, unless [keepCurrent] (a
  /// lead switch, which revokes it only once the new lead is up).
  Future<DriverBriefing> _brief(
    String id, {
    required String projectDir,
    required String workingDir,
    required HarnessDriver driver,
    required String model,
    Future<void>? ready,
    bool keepCurrent = false,
  }) async {
    if (consentProblem(driver.info, ref.read(codeSettingsProvider).ownClis) case final why?) throw HarnessError(why);
    ref.read(driverShutdownProvider);
    final host = ref.read(hostServerProvider);
    final tokens = ref.read(_hostTokensProvider);
    if (!keepCurrent) {
      if (tokens.remove(id) case final old?) await host.revoke(old);
    }
    final forward = _HostForward(
      () => ref.mounted && byId(id) != null ? ref.read(codeSessionProvider(id).notifier) : null,
      ready ?? Future<void>.value(),
    );
    final token = await host.mint(id, forward);
    try {
      final export = await _exportBriefing(
        id,
        projectDir: projectDir,
        workingDir: workingDir,
        driver: driver,
        model: model,
      );
      tokens[id] = token.token;
      return DriverBriefing(
        mcpUrl: '${token.url}',
        mcpToken: token.token,
        skillDir: export.skillDir,
        sessionSkill: export.text,
        host: forward,
      );
    } on Object {
      await host.revoke(token.token);
      rethrow;
    }
  }

  /// Writes session [id]'s briefing folder for [driver] on [model]: our
  /// skills, and the session text. The text names only the lead: it is the
  /// start of a resumed conversation's prompt, so it must not change when
  /// other harnesses lead meanwhile (the handoff names them).
  Future<({String skillDir, String text})> _exportBriefing(
    String id, {
    required String projectDir,
    required String workingDir,
    required HarnessDriver driver,
    required String model,
  }) async {
    final projectId = ref.read(codeProjectsProvider).where((p) => p.path == projectDir).firstOrNull?.id;
    final notes = await hostProjectNotes(workingDir);
    final text = [
      sessionBriefing(
        SessionSkillInput(
          worktree: workingDir,
          projectRoot: projectDir,
          lead: (name: driver.info.label, model: model.isEmpty ? 'its default model' : model),
          hostTools: _hostToolInfos,
        ),
      ),
      // Volatile, so last; the memory is text earlier sessions wrote.
      if (notes.isNotEmpty) defuseInlineCommands(notes),
    ].join('\n');
    final export = await exportSkills(await _driverDir(id), await _skillsFor(projectId), sessionText: text);
    return (skillDir: export.skillDir, text: text);
  }

  /// A lead switch from [info]'s lead failed: the briefing folder is its
  /// lead's again (the new lead's export replaced it), or gone when that lead
  /// isn't an outside agent.
  Future<void> _restoreBriefing(CodeSessionInfo info) async {
    try {
      final driver = ref.read(driverRegistryProvider).resolve(info.harness);
      if (driver == null || !isOutsideLead(info.harness, info.workingDir)) {
        await removeBriefing(await _driverDir(info.id));
        return;
      }
      final project = ref.read(codeProjectsProvider).where((p) => p.id == info.projectId).firstOrNull;
      await _exportBriefing(
        info.id,
        projectDir: project?.path ?? info.workingDir,
        workingDir: info.workingDir,
        driver: driver,
        model: info.model,
      );
    } on Object {
      // The lead keeps its tools; only its skill files may be the other lead's.
    }
  }

  Future<String> _driverDir(String id) async => '${await ref.read(driverDataDirProvider)()}/driver-sessions/$id';

  /// Where session [id] keeps what earlier leads did (the timeline journal)
  /// and the handoffs between them.
  Future<String> timelineDir(String id) async => '${await ref.read(driverDataDirProvider)()}/code-timelines/$id';

  /// Starts a new conversation on [harness] for session [info], which is
  /// moving to that lead: briefed like a new session when it is an outside
  /// agent (host calls wait for [ready]), with [initialMessage] run at once.
  /// The tier and harness mode are the ones the new lead may use. The
  /// current lead's token stays; on a failure only the new one is revoked.
  Future<HarnessSession> _startLead(
    CodeSessionInfo info, {
    required String harness,
    required String model,
    required String effort,
    required AgentMode mode,
    required HarnessTier tier,
    required HarnessMode harnessMode,
    String? initialMessage,
    Future<void>? ready,
  }) async {
    final runner = await harnessFor(ref, info.workingDir, harness: harness);
    final driver = runner is HarnessDriver && isOutsideLead(harness, info.workingDir) ? runner : null;
    final projectDir = ref.read(codeProjectsProvider).where((p) => p.id == info.projectId).firstOrNull?.path;
    final briefing = driver == null
        ? null
        : await _brief(
            info.id,
            projectDir: projectDir ?? info.workingDir,
            workingDir: info.workingDir,
            driver: driver,
            model: model,
            ready: ready,
            keepCurrent: true,
          );
    try {
      return await runner.start(
        await specFor(
          sessionId: info.id,
          projectDir: projectDir ?? info.workingDir,
          workingDir: info.workingDir,
          model: model,
          mode: mode,
          effort: effort,
          holdClientTools: info.holdClientTools,
          sessionTag: info.billingTag,
          initialMessage: initialMessage,
          isolated: info.worktree != null,
          tier: tier,
          harnessMode: harnessMode,
          harness: harness,
          briefing: briefing,
        ),
      );
    } on Object {
      if (briefing != null) await ref.read(hostServerProvider).revoke(briefing.mcpToken);
      rethrow;
    }
  }

  Future<List<InstalledSkill>> _skillsFor(String? projectId) async {
    try {
      return await codeInstalledSkillsFor(ref, projectId);
    } on Object {
      // Unreadable skill folders only lose the skills.
      return const [];
    }
  }

  /// Ends outside session [id]'s host token and deletes its briefing.
  Future<void> _unbrief(String id) async {
    ref.read(_hostTokensProvider).remove(id);
    try {
      await ref.read(hostServerProvider).revokeSession(id);
      await removeBriefing(await _driverDir(id));
    } on Object {
      // A briefing left behind is only disk space.
    }
  }

  /// Reopens [info]'s conversation on its harness. An outside agent gets a
  /// fresh briefing (the old token died with the app) when its driver can
  /// take one; otherwise it reopens without EveryAI's tools. A child session
  /// (subagent, review, fork) started without a briefing, so it reopens without one.
  /// With [keepCurrent] (a lead switch) the session's current token stays.
  Future<HarnessSession> attachSession(CodeSessionInfo info, {bool keepCurrent = false}) async {
    final harness = await harnessFor(ref, info.workingDir, harness: info.harness);
    final project = ref.read(codeProjectsProvider).where((p) => p.id == info.projectId).firstOrNull;
    // The user's approved MCP servers, as at start (specFor): the app's list for the project found by
    // its folder, never repository files.
    final mcp = <String, Object?>{
      if (!noLocalFolder(project?.path ?? info.workingDir))
        ...ref.read(codeMcpServersProvider).mcpConfigFor(project?.id),
    }..remove(everyaiServerName);
    if (harness is! HarnessDriver || info.parentId != null || !isOutsideLead(info.harness, info.workingDir)) {
      // A child session has no briefing, but an ACP agent still gets the user's servers back.
      if (harness is AcpDriver && info.parentId != null) return harness.attachWithMcp(info.conversationId, mcp);
      return harness.attach(info.conversationId);
    }
    if (consentProblem(harness.info, ref.read(codeSettingsProvider).ownClis) case final why?) throw HarnessError(why);
    if (harness is! AttachesBriefed) return harness.attach(info.conversationId);
    // Whatever token the session had before (a run that ended without its quit hook) ends now.
    if (!keepCurrent) await ref.read(hostServerProvider).revokeSession(info.id);
    final briefing = await _brief(
      info.id,
      projectDir: project?.path ?? info.workingDir,
      workingDir: info.workingDir,
      driver: harness,
      model: info.model,
      keepCurrent: keepCurrent,
    );
    try {
      return await (harness as AttachesBriefed).attachBriefed(info.conversationId, briefing, mcpConfig: mcp);
    } on Object {
      ref.read(_hostTokensProvider).remove(info.id);
      await ref.read(hostServerProvider).revoke(briefing.mcpToken);
      rethrow;
    }
  }

  Future<List<AgentDefinition>> _agentsFor(String? projectId) async {
    try {
      return await codeAgentsFor(ref, projectId);
    } on Object {
      // Unreadable agent folders only lose the agent list.
      return const [];
    }
  }

  /// The subagent session started for [parentId]'s `run_subagent` call [callId].
  CodeSessionInfo? subagentFor(String parentId, String callId) =>
      state.where((s) => s.parentId == parentId && s.parentCallId == callId).firstOrNull;

  /// Starts a child conversation for [parent]'s `run_subagent` [call]: the parent's
  /// folder, model and effort, [mode], and the task as its first message.
  /// Its model calls are billed to the parent, and the parent's Stop ends
  /// the processes it leaves running (they share the session tag).
  Future<CodeSessionInfo> startSubagent({
    required CodeSessionInfo parent,
    required ActionCall call,
    required AgentMode mode,
    bool onParentModel = false,
  }) => startTask(
    parent: parent,
    task: SubagentTask.of(call),
    callId: call.id,
    mode: mode,
    isolation: call.str('isolation'),
    onParentModel: onParentModel,
    model: call.str('model').trim(),
  );

  /// [startSubagent] for a task the app starts itself (an Ultra research
  /// worker): [callId] names it under [parent].
  Future<CodeSessionInfo> startTask({
    required CodeSessionInfo parent,
    required SubagentTask task,
    required String callId,
    required AgentMode mode,
    String isolation = '',
    bool onParentModel = false,
    String model = '',
  }) async {
    final project = ref.read(codeProjectsProvider).where((p) => p.id == parent.projectId).firstOrNull;
    final projectDir = project?.path ?? parent.workingDir;
    AgentType? role;
    AgentDefinition? agent;
    if (task.agent.isNotEmpty && !noLocalFolder(projectDir)) {
      // A library agent first (checked and trusted now), then a settings.json role.
      agent = (await _agentsFor(parent.projectId)).where((a) => a.name == task.agent).firstOrNull;
      if (agent == null) {
        try {
          role = (await loadAgentSettings(projectDir)).agents[task.agent];
        } on Object {
          // An unreadable settings file only loses the role's instructions.
        }
      } else {
        role = AgentType(name: agent.name, description: agent.oneLine);
      }
    }
    var setup = childSetup(
      agent,
      parentMode: mode,
      parentModel: parent.model,
      parentEffort: parent.effort,
      preferred: agent == null
          ? null
          : onParentModel
          ? (model: parent.model, effort: parent.effort)
          // The orchestrator's pick for this task, else the user's for the role.
          : model.isNotEmpty
          ? (model: model, effort: '')
          : ref.read(agentLibrarySettingsProvider).preferredFor(agent.name),
      // A role's model must be one the catalog has and that can call tools; else the orchestrator's.
      modelKnown: (m) {
        final catalog = ref.read(modelCatalogProvider);
        if (catalog.length == 0) return true;
        return catalog[ModelId(m)]?.tools ?? false;
      },
    );
    // The orchestrator asked for another model without a role: a fresh
    // general child on it, when the model can call tools.
    final known = ref.read(modelCatalogProvider);
    final asked = !onParentModel && agent == null && role == null && model.isNotEmpty && model != parent.model
        ? (known.length == 0 || (known[ModelId(model)]?.tools ?? false) ? model : null)
        : null;
    if (asked != null) {
      setup = (mode: setup.mode, model: asked, effort: null, tools: null, rolePrompt: null);
    }
    // A subagent is a fork, starting from the parent's whole conversation
    // (and its cached prefix), unless its role runs on another model: then it
    // is a fresh child with the role's instructions. The scripted demo can't
    // fork; its children start fresh.
    final fork =
        !isDemoPath(parent.workingDir) && (agent == null ? role == null && asked == null : setup.model == parent.model);
    // A researcher is sandboxed: the research sites only, no shell, no secrets.
    final research = agent?.name == 'researcher' || task.agent == 'researcher';
    final sites = research ? ref.read(codeSettingsProvider).researchSites : null;
    // A fork gets its own worktree unless the user's setting or the call says to share the folder.
    final isolate =
        fork &&
        !research &&
        isolation != 'shared' &&
        (isolation == 'worktree' || ref.read(codeSettingsProvider).forksIsolated);
    ForkCopy? copy;
    if (isolate) {
      try {
        copy = await GitService.forkCopy(
          parent.workingDir,
          worktreesDir: '${await GitService.dataDir()}/forks',
          slug: sessionSlug(task.title, const Uuid().v7()),
        );
      } on Object {
        copy = null; // Shares the folder instead.
      }
    }
    return startChild(
      parent: parent,
      title: task.title,
      brief: fork
          ? forkBrief(
              task,
              copyAt: copy?.path,
              parentDir: copy == null ? null : parent.workingDir,
              role: setup.rolePrompt,
              research: sites,
            )
          : subagentBrief(task, role: role),
      fork: fork,
      forkCopy: copy,
      mode: setup.mode,
      callId: callId,
      projectDir: projectDir,
      // A fork keeps the parent's model, effort and tools, so the cache holds.
      model: fork ? null : setup.model,
      effort: fork ? null : setup.effort,
      tools: fork ? null : setup.tools,
      rolePrompt: fork ? null : setup.rolePrompt,
      researchSites: sites,
    );
  }

  /// Starts a child conversation of [parent] working on [brief]: the
  /// parent's folder, model and effort (unless [model] or [effort] say
  /// otherwise), [mode], billed to the parent. A `run_subagent` child has the
  /// call's id as [callId]; one the app starts itself (a `/review`) has its
  /// own. [tools] and [rolePrompt] come from a library agent. An Ultra
  /// child may work in its own [workingDir] (a step worktree), bill under
  /// its own id ([ownTag], so its cost can be read alone) and get other
  /// [clientTools].
  Future<CodeSessionInfo> startChild({
    required CodeSessionInfo parent,
    required String title,
    required String brief,
    required AgentMode mode,
    required String callId,
    String? projectDir,
    String? model,
    String? effort,
    List<String>? tools,
    String? rolePrompt,
    String? workingDir,
    bool ownTag = false,
    List<Map<String, Object?>>? clientTools,
    bool fork = false,
    ForkCopy? forkCopy,
    List<String>? researchSites,
  }) async {
    model ??= parent.model;
    effort ??= parent.effort;
    final id = const Uuid().v7();
    projectDir ??=
        ref.read(codeProjectsProvider).where((p) => p.id == parent.projectId).firstOrNull?.path ?? parent.workingDir;
    workingDir ??= forkCopy?.path ?? parent.workingDir;
    final harness = await harnessFor(ref, parent.workingDir, harness: parent.harness);
    // A driver that can't fork can't start one from the parent's history yet.
    if (harness case final HarnessDriver d when fork && !d.caps.contains(DriverCap.fork)) throw forkUnavailable(d.info);
    Future<HarnessSession> begin(SessionSpec spec) =>
        (fork ? forkSession(harness, parent.conversationId, spec) : null) ?? harness.start(spec);
    final live = await begin(
      await specFor(
        isolated: workingDir != parent.workingDir || parent.worktree != null,
        sessionId: id,
        sessionTag: ownTag ? id : parent.id,
        projectDir: projectDir,
        workingDir: workingDir,
        model: model,
        mode: mode,
        effort: effort,
        holdClientTools: false,
        subagent: true,
        initialMessage: modeNote(mode, brief, subagent: true),
        tools: tools,
        rolePrompt: rolePrompt,
        clientTools: clientTools,
        pathMap: forkCopy == null ? const {} : {parent.workingDir: forkCopy.path, forkCopy.repoRoot: forkCopy.root},
        // The parent's, so a fork's prompt (and cache) matches it.
        tier: parent.tier,
        researchSites: researchSites,
        // The child isn't saved yet, so its harness (the parent's) can't be looked up by id.
        harness: parent.harness,
      ),
    );
    ref.read(_liveProvider)[id] = live;
    final info = CodeSessionInfo(
      id: id,
      projectId: parent.projectId,
      title: title,
      conversationId: live.id,
      model: model,
      mode: mode,
      workingDir: workingDir,
      createdAt: DateTime.now(),
      branch: parent.branch,
      harness: parent.harness,
      effort: effort,
      parentId: parent.id,
      parentCallId: callId,
      ownTag: ownTag,
      forkCopy: forkCopy,
      tier: parent.tier,
    );
    state = [...state, info];
    _save();
    return info;
  }

  /// The user's models a child may run on besides [own]: those that can call tools, a few.
  Map<String, String> _childModels(String own) => {
    for (final m in (ref.read(libraryProvider).value ?? const <ModelSpec>[]).where((m) => m.tools).take(8))
      if (m.id.value != own) m.id.value: m.name,
  };

  static Future<List<ContextFile>> _startContext(String workingDir, String projectDir) async {
    try {
      return await (await ProjectContext.forSession(workingDir: workingDir, projectDir: projectDir)).atStart();
    } on Object {
      return const [];
    }
  }

  /// A worktree for the session when [project] is a git repository with a commit to branch from. A fresh
  /// `git init` has none, so its session runs in the folder itself, like a folder outside git.
  static Future<SessionWorktree?> _worktreeFor(CodeProject project, String title, String id) async {
    final root = await GitService.repoRoot(project.path);
    if (root == null || !await GitService.hasCommits(root)) return null;
    final data = await GitService.dataDir();
    final repoName = root.split('/').last;
    return GitService.createWorktree(
      repoRoot: root,
      slug: sessionSlug(title, id),
      worktreesDir: '$data/worktrees/$repoName-${project.id.substring(project.id.length - 6)}',
      hooksDir: '$data/git-hooks',
    );
  }

  static Future<void> _dropWorktree(SessionWorktree w) async {
    try {
      await GitService.removeWorktree(w, hooksDir: '${await GitService.dataDir()}/git-hooks');
    } on Object {
      // Left behind, it is only disk space and a branch.
    }
  }

  /// The in-place session's starting point; a snapshot that fails only costs
  /// the Changes view.
  static Future<GitBaseline?> _baselineFor(String dir) async {
    try {
      return await GitService.baseline(dir);
    } on Object {
      return null;
    }
  }

  void update(CodeSessionInfo info) {
    state = [for (final s in state) s.id == info.id ? info : s];
    _save();
  }

  /// Removes session [id] and the subagents it started; an outside agent's
  /// host token ends and its briefing is deleted (done when this completes).
  Future<void> remove(String id) async {
    final gone = {
      id,
      for (final s in state)
        if (s.parentId == id) s.id,
    };
    // Any outside lead the session had left a briefing (and maybe a token).
    final outside = [
      for (final s in state)
        if (gone.contains(s.id) && [s.harness, ...s.leads.keys].any((h) => isOutsideLead(h, s.workingDir))) s.id,
    ];
    final switched = [
      for (final s in state)
        if (gone.contains(s.id) && s.leads.isNotEmpty) s.id,
    ];
    for (final g in gone) {
      unawaited(ref.read(_liveProvider).remove(g)?.close());
      ref.read(preferencesProvider)['$codeUsageReportsPrefix$g'] = null;
    }
    state = [
      for (final s in state)
        if (!gone.contains(s.id)) s,
    ];
    _save();
    await Future.wait([for (final g in outside) _unbrief(g), for (final g in switched) _dropTimeline(g)]);
  }

  Future<void> _dropTimeline(String id) async {
    try {
      await removeTimeline(await timelineDir(id));
    } on Object {
      // Left behind, it is only disk space.
    }
  }

  static String titleFor(String prompt) {
    final line = prompt.trim().split('\n').first;
    return line.length <= 48 ? line : '${line.substring(0, line.lastIndexOf(' ', 48).clamp(24, 48))}…';
  }
}

@immutable
final class CodeSessionState {
  const CodeSessionState({
    this.transcript = const Transcript(),
    this.mode = AgentMode.ask,
    this.queued = const [],
    this.connected = false,
    this.error,
    this.subagentNeedsInput = false,
    this.asides = const [],
    this.goal,
    this.decided = const {},
    this.waited = '',
    this.switching = false,
  });

  final Transcript transcript;

  /// The session is moving to another lead harness; messages wait for the new one.
  final bool switching;

  /// The usage-limit notice the user chose Wait on: its offer to carry on
  /// with another harness stays closed.
  final String waited;

  /// Answers given so far to the calls waiting for approval (action id →
  /// allowed), for sessions that take one answer per call: their rows on the
  /// approval card are settled while the others still wait.
  final Map<String, bool> decided;

  /// The standing objective set with `/goal`, if any.
  final Goal? goal;

  /// `/btw` answers and `/cost` cards beside the session (never sent to the agent).
  final List<Aside> asides;

  /// A subagent this session is waiting on needs the user (an approval).
  final bool subagentNeedsInput;
  final AgentMode mode;

  /// Messages typed while the agent was busy; sent when it stops.
  final List<Outgoing> queued;
  final bool connected;
  final String? error;

  SessionStatus get status => switch (transcript) {
    _ when error != null => SessionStatus.failed,
    Transcript(pending: [_, ...]) => SessionStatus.needsInput,
    final t when t.openQuestion != null || t.openPlan != null => SessionStatus.needsInput,
    // The call (or the turn) waits on subagents; the session is still at work.
    Transcript(openSubagents: [_, ...]) => subagentNeedsInput ? SessionStatus.needsInput : SessionStatus.running,
    Transcript(status: ExecutionStatus.running) => SessionStatus.running,
    Transcript(status: ExecutionStatus.error || ExecutionStatus.stuck) => SessionStatus.failed,
    Transcript(status: ExecutionStatus.finished) => SessionStatus.done,
    _ when !connected => SessionStatus.starting,
    _ => SessionStatus.idle,
  };

  CodeSessionState copyWith({
    Transcript? transcript,
    AgentMode? mode,
    List<Outgoing>? queued,
    bool? connected,
    String? error,
    bool? subagentNeedsInput,
    List<Aside>? asides,
    Goal? goal,
    bool clearGoal = false,
    bool clearError = false,
    Map<String, bool>? decided,
    String? waited,
    bool? switching,
  }) => CodeSessionState(
    switching: switching ?? this.switching,
    decided: decided ?? this.decided,
    waited: waited ?? this.waited,
    transcript: transcript ?? this.transcript,
    mode: mode ?? this.mode,
    queued: queued ?? this.queued,
    connected: connected ?? this.connected,
    error: clearError ? null : error ?? this.error,
    subagentNeedsInput: subagentNeedsInput ?? this.subagentNeedsInput,
    asides: asides ?? this.asides,
    goal: clearGoal ? null : goal ?? this.goal,
  );
}

/// How [CodeSessionController.compact] went.
@immutable
final class CompactOutcome {
  const CompactOutcome.compacted(this.summary) : kind = CompactKind.compacted, message = '';
  const CompactOutcome.nothing() : kind = CompactKind.nothing, message = '', summary = '';
  const CompactOutcome.busy() : kind = CompactKind.busy, message = '', summary = '';
  const CompactOutcome.failed(this.message) : kind = CompactKind.failed, summary = '';

  final CompactKind kind;

  /// Why it failed.
  final String message;
  final String summary;
}

enum CompactKind {
  compacted,

  /// The conversation is too short to shorten.
  nothing,

  /// The agent is working or waiting for an answer; try again when it stops.
  busy,
  failed,
}

/// How [CodeSessionController.switchLead] went.
@immutable
final class LeadSwitchOutcome {
  const LeadSwitchOutcome.switched(this.kind) : message = '', busy = false, failed = false;
  const LeadSwitchOutcome.busy() : message = '', kind = null, busy = true, failed = false;
  const LeadSwitchOutcome.failed(this.message) : kind = null, busy = false, failed = true;

  /// The handoff the new lead got: full, or only what it missed.
  final HandoffKind? kind;

  /// The agent is working or waiting for an answer; stop it first.
  final bool busy;
  final bool failed;

  /// Why it failed.
  final String message;
}

/// One session's live state; talks to the harness.
final codeSessionProvider = NotifierProvider.family<CodeSessionController, CodeSessionState, String>(
  CodeSessionController.new,
);

final class CodeSessionController extends Notifier<CodeSessionState> with _SessionBuiltins implements HostTools {
  CodeSessionController(this.sessionId);
  @override
  final String sessionId;

  HarnessSession? _session;

  /// The session as Markdown (see [transcriptMarkdown]): this conversation's
  /// events, with the usage so far.
  /// A session that wasn't open loads its history first (up to [wait]).
  Future<String> exportMarkdown({Duration wait = const Duration(seconds: 8)}) async {
    final until = DateTime.now().add(wait);
    while (_events.whereType<ChatMessage>().isEmpty && DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final info = ref.read(codeSessionsProvider.notifier).byId(sessionId);
    if (info == null) return '';
    return transcriptMarkdown(info, _events, usage: ref.read(codeUsageProvider(sessionId)).value);
  }

  /// What the session left running in the background (EveryAI harness).
  List<BackgroundTask> get backgroundTasks =>
      _session is HasBackgroundShells ? (_session! as HasBackgroundShells).backgroundTasks : const [];

  Future<void> stopBackground(String id) async {
    if (_session case final HasBackgroundShells s) await s.stopBackground(id);
  }

  @override
  bool get _backgroundBusy => _background.isNotEmpty;

  /// The open harness session, for the built-ins mixed in.
  @override
  HarnessSession? get _harnessSession => _session;
  StreamSubscription<HarnessEvent>? _sub;
  var _builder = TranscriptBuilder();

  /// What earlier conversations showed (before a compaction): kept on screen
  /// when [rewind] folds the transcript again.
  List<TranscriptItem> _carried = const [];

  /// The approval set we already answered (so one prompt gets one answer).
  String _answered = '';

  /// Patterns approved "for this session" on the approval card.
  final _sessionAllowed = <String>{};

  /// Permission rules from the project's `settings.json` files.
  PermissionRules _settingsRules = PermissionRules.none;

  /// The project's instruction files; nested ones go out with the next message.
  ProjectContext? _context;

  final _doom = DoomLoopDetector();

  /// A loop card is waiting for the user: the run is paused and nothing is auto-approved.
  bool _doomOpen = false;

  /// Events before this are history being replayed, which never raise a loop card.
  bool _live = false;

  /// How long after attaching the session's events count as live (the
  /// history a reattached harness replays comes first).
  @visibleForTesting
  static Duration liveAfter = const Duration(milliseconds: 1500);

  /// What earlier leads did, oldest first (a session that switched harness).
  List<LeadSegment> _timeline = const [];

  /// Ids of the current conversation's events already in [_timeline]: a lead
  /// that came back replays them, and they are shown once.
  final _replayed = <String>{};

  /// The lead just changed: its first message carries the whole mode note.
  bool _freshLead = false;
  bool _switching = false;

  /// What the current conversation has seen (no deltas), for [compact].
  @override
  final _events = <HarnessEvent>[];

  /// Every event as it is folded in (deltas too), for devices mirroring this
  /// session (`HostMirror`); null means the log was folded again (a compaction
  /// or rewind), so [mirrorEvents] should be sent over from the start.
  final _mirror = StreamController<HarnessEvent?>.broadcast(sync: true);
  Stream<HarnessEvent?> get mirrorTap => _mirror.stream;

  /// What the transcript is folded from now (no deltas), for a device that
  /// starts mirroring: earlier leads' stints, then the current conversation
  /// without what they already hold. Read it and listen to [mirrorTap] in the same turn.
  List<HarnessEvent> get mirrorEvents => List.unmodifiable([
    for (final s in _timeline) ...[...s.events, _statusEvent('idle')],
    for (final e in _events)
      if (!_replayed.contains(e.id)) e,
  ]);
  bool _compacting = false;

  /// Subagents this session waits on, by `run_subagent` call id: the child session,
  /// and the subscription that watches it finish.
  final _childOf = <String, String>{};
  final _childSubs = <String, ProviderSubscription<CodeSessionState>>{};
  final _spawning = <String>{};

  /// Calls stopped while their subagent was still starting.
  final _abandoned = <String>{};

  /// Reports not yet handed to the agent, by call id.
  final _reports = <String, SubagentReport>{};
  final _childWaiting = <String>{};

  /// Background subagents by call id: their call was answered at the start,
  /// and their report goes to this session as a task notification.
  final _background = <String, ({String childId, String title})>{};

  /// Whether forks left in the background before a restart are watched again.
  bool _resumedBackground = false;
  bool _delivering = false;

  /// An outside agent's host calls that wait for the user (question cards,
  /// plans), oldest first.
  final _hostWaits = <_HostWait>[];

  /// An outside agent's call to the app's MCP host. Question cards and plans
  /// are the agent's own row for the call (see `hostToolOf`), so the card,
  /// its replay and the remote mirror work as for the EveryAI harness; the
  /// call waits until the user answers there. Memory and saved plans run in
  /// the session's folder, like the EveryAI harness's own tools.
  @override
  Future<HostResult> call(HostCall call) async {
    final dir = ref.read(codeSessionsProvider.notifier).byId(sessionId)?.workingDir;
    if (dir == null) return (text: 'Error: this session is closed.', isError: true);
    switch (call.name) {
      case askUserQuestionTool || presentPlanTool:
        final wait = _HostWait(call);
        _hostWaits.add(wait);
        // Given up (timed out, the agent left): its card closes with the agent's error result.
        unawaited(
          call.ended.then((_) {
            _hostWaits.remove(wait);
            if (!wait.done.isCompleted) wait.done.complete((text: 'Error: no longer waiting.', isError: true));
          }),
        );
        _bindHostWaits();
        return wait.done.future;
      case 'memory':
        return hostMemory(dir, call.args);
      case savedPlansTool:
        return hostSavedPlans(dir, call.args);
      case bugCheckTool:
        return (text: "Error: bug_check is for Bug fix mode, which this session isn't in.", isError: true);
      default:
        return (text: 'Error: there is no EveryAI tool called ${call.name}.', isError: true);
    }
  }

  /// Pairs each waiting host call with an open card of its tool, from the
  /// user's last message on: one with the call's arguments first, newest
  /// calls with newest cards. The agent's row and its call to the host
  /// arrive in either order, so this runs on both and pairs afresh each
  /// time: a call that took a card left open by an earlier run (the app quit
  /// while it waited) moves to its own card once that arrives.
  void _bindHostWaits() {
    if (_hostWaits.isEmpty) return;
    final items = state.transcript.items;
    final open = [
      for (final item in items.skip(items.lastIndexWhere((i) => i is UserTurn) + 1).toList().reversed)
        if (switch (item) {
              QuestionItem(:final call, answers: null) || PlanProposal(:final call, verdict: null) => call,
              _ => null,
            }
            case final call? when hostToolOf(call) != null)
          call,
    ];
    final waits = _hostWaits.reversed.toList();
    for (final w in waits) {
      w.row = null;
    }
    // Matching arguments first, so a call never takes the card another call's arguments match.
    for (final exact in [true, false]) {
      for (final wait in waits.where((w) => w.row == null)) {
        final call = open
            .where((c) => hostToolOf(c) == wait.call.name && (!exact || _sameArgs(c, wait.call.args)))
            .firstOrNull;
        if (call == null) continue;
        wait.row = call.id;
        open.remove(call);
      }
    }
  }

  /// Whether the agent's row [call] carries host call arguments [args].
  static bool _sameArgs(ActionCall call, Map<String, Object?> args) =>
      args.entries.every((e) => jsonEncode(call.action[e.key]) == jsonEncode(e.value));

  /// The host call card [rowId] answers, if one waits.
  _HostWait? _hostFor(String rowId) => _hostWaits.where((w) => w.row == rowId && !w.done.isCompleted).firstOrNull;

  void _answerHost(_HostWait wait, String text, {bool isError = false}) {
    _hostWaits.remove(wait);
    if (!wait.done.isCompleted) wait.done.complete((text: text, isError: isError));
  }

  /// A chat message closes every host card still waiting: the call's result
  /// says the user replied in chat (for a plan, that they want changes), and
  /// the message follows once the agent's turn ends.
  void _releaseHostCards() {
    for (final w in [..._hostWaits]) {
      _answerHost(w, w.call.name == presentPlanTool ? '$planRevisionLead see their next message.' : repliedInChat);
    }
  }

  @override
  CodeSessionState build() {
    final info = ref.read(codeSessionsProvider.notifier).byId(sessionId);
    ref.onDispose(() {
      _sub?.cancel();
      unawaited(_mirror.close());
      _gitTimer?.cancel();
      _disposeBuiltins();
      _researchTimer?.cancel();
      for (final s in [..._childSubs.values, ..._researchSubs.values]) {
        s.close();
      }
    });
    // Subagents and forks don't notify: an approval they wait on shows on the
    // parent (subagentNeedsInput), and their questions are the orchestrator's.
    if (info?.parentId == null) {
      final alerts = StatusAlerts(
        ref,
        () => ref.read(codeSessionsProvider.notifier).byId(sessionId)?.title ?? 'Code session',
      );
      ref.onDispose(alerts.dispose);
      listenSelf((prev, next) => alerts.onChange(prev?.status, next.status));
    }
    // The budget holds whether or not the session is on screen: every new
    // reading (and a lowered budget) is checked here.
    if (info != null) {
      final owner = info.parentId ?? sessionId;
      ref.listen(codeUsageProvider(sessionId), (_, _) => _enforceBudget());
      ref.listen(codeSettingsProvider.select((s) => s.budgets[owner]), (_, _) => _enforceBudget());
    }
    // After build returns, so the connected flag isn't overwritten.
    if (info != null) unawaited(Future.microtask(() => _connect(info)));
    return CodeSessionState(mode: info?.mode ?? AgentMode.ask);
  }

  /// The session whose budget this one spends: itself, or the one that started it.
  String get _budgetOwner => ref.read(codeSessionsProvider.notifier).byId(sessionId)?.parentId ?? sessionId;

  /// The budget note shown once spending reaches it, or null under it.
  String? get budgetReached {
    final owner = _budgetOwner;
    final own = ref.read(codeSettingsProvider).budgets[owner];
    // Ultra never runs uncapped: no budget of its own means the Ultra cap
    // (Settings → Add API keys; $25 unless changed), on credits too.
    final info = ref.read(codeSessionsProvider.notifier).byId(owner);
    final ownKey = info != null && byokUltraCapped(info.tier, ModelId(info.model), ModelBilling.current);
    final keyCap = own == null && info?.tier == HarnessTier.ultra ? ref.read(byokUltraCapProvider) : null;
    final budget = own ?? keyCap;
    final spent = budgetSpentMicros(
      owner,
      sessions: ref.read(codeSessionsProvider),
      usage: (id) => ref.exists(codeUsageProvider(id)) ? ref.read(codeUsageProvider(id)).value?.spentMicros : null,
    );
    if (budget == null || budget <= 0 || spent < budget * 1e6) return null;
    if (keyCap != null) {
      return ownKey
          ? 'This Ultra session reached your \$${budget.toStringAsFixed(2)} spend cap on your own key. '
                'Set a budget in the top bar, or raise the cap in Settings → Add API keys, to carry on.'
          : 'This Ultra session reached the \$${budget.toStringAsFixed(2)} Ultra spend cap. Set a budget in the '
                'top bar, or raise the cap in Settings → Add API keys, to carry on.';
    }
    return 'This session reached its \$${budget.toStringAsFixed(2)} budget. Raise it in the top bar to carry on.';
  }

  /// Stops the run once the budget is reached, and tells the session that
  /// owns the budget (an Ultra step bills under its own id, so its spend
  /// only shows there through this).
  void _enforceBudget() {
    if (!ref.mounted) return;
    final note = budgetReached;
    if (note == null) {
      if (state.error == _budgetNote) state = state.copyWith(clearError: true);
      _budgetNote = null;
    } else {
      final t = state.transcript;
      final busy = t.running || t.pending.isNotEmpty || t.held.isNotEmpty || t.openSubagents.isNotEmpty;
      final last = _budgetStoppedAt;
      // Readings arrive often; one Stop at a time (again if the run carries on).
      if (busy && (last == null || DateTime.now().difference(last) > const Duration(seconds: 10))) {
        _budgetStoppedAt = DateTime.now();
        unawaited(stop());
      }
      if (_budgetNote != note) state = state.copyWith(error: _budgetNote = note);
    }
    // A child billed under its own id: its spend only reaches the owner's
    // budget through here (after this listener returns).
    final owner = _budgetOwner;
    final info = ref.read(codeSessionsProvider.notifier).byId(sessionId);
    if (owner != sessionId && (info?.ownTag ?? false)) {
      scheduleMicrotask(() {
        if (ref.mounted && ref.exists(codeSessionProvider(owner))) {
          ref.read(codeSessionProvider(owner).notifier)._enforceBudget();
        }
      });
    }
  }

  String? _budgetNote;
  DateTime? _budgetStoppedAt;

  /// False (with the budget note shown) when the budget is spent: nothing
  /// more is sent, resumed or approved until it is raised.
  bool _withinBudget() {
    final note = budgetReached;
    if (note == null) {
      if (_budgetNote != null && state.error == _budgetNote) state = state.copyWith(clearError: true);
      _budgetNote = null;
      return true;
    }
    state = state.copyWith(error: _budgetNote = note);
    return false;
  }

  Future<void> _connect(CodeSessionInfo info) async {
    try {
      if (info.leads.isNotEmpty) await _loadTimeline(info);
      _builder.lead = _leadLabel(info.harness);
      final live = ref.read(_liveProvider);
      final session = _session = live[sessionId] ?? await ref.read(codeSessionsProvider.notifier).attachSession(info);
      live[sessionId] = session;
      await _openContext(info);
      // Closed meanwhile: nothing would cancel a subscription made now.
      if (!ref.mounted) return;
      _sub = session.events.listen(_onEvent);
      Timer(liveAfter, () {
        _live = true;
        // Calls still waiting after the history replayed (an app restart).
        if (ref.mounted) _syncSubagents();
      });
      state = state.copyWith(connected: true);
      await _loadSettingsRules(info);
    } on Object catch (e) {
      state = state.copyWith(error: '$e');
    }
  }

  /// Shows what earlier leads did, before the current one's history replays.
  Future<void> _loadTimeline(CodeSessionInfo info) async {
    if (info.leads.isEmpty || noLocalFolder(info.workingDir)) return;
    try {
      _timeline = await readTimeline(await ref.read(codeSessionsProvider.notifier).timelineDir(sessionId));
    } on Object {
      // Without it, only the current lead's turns show.
      return;
    }
    for (final s in _timeline) {
      _builder.lead = _leadLabel(s.harness);
      s.events.forEach(_builder.add);
      _settleSegment();
    }
    _carried = _builder.snapshot.items;
    _markReplayed(info.conversationId);
    state = state.copyWith(transcript: _builder.snapshot);
  }

  /// A lead's stint is over: whatever it last said about running or waiting no longer holds.
  void _settleSegment() {
    if (_builder.snapshot.status case ExecutionStatus.running || ExecutionStatus.waitingForConfirmation) {
      _builder.add(_statusEvent('idle'));
    }
  }

  /// A status the app folds in itself (it is not one of the lead's events).
  static HarnessEvent _statusEvent(String status) => HarnessEvent.decode({
    'id': '',
    'kind': 'ConversationStateUpdateEvent',
    'key': 'execution_status',
    'value': status,
  });

  void _markReplayed(String conversationId) {
    _replayed
      ..clear()
      ..addAll([
        for (final s in _timeline)
          if (s.conversationId == conversationId)
            for (final e in s.events)
              if (e.id.isNotEmpty) e.id,
      ]);
  }

  /// [harness] as the user knows it.
  @override
  String _leadLabel(String harness) => ref.read(driverRegistryProvider).resolve(harness)?.info.label ?? harness;

  /// Before the history replays, so files it shows delivered aren't sent again.
  Future<void> _openContext(CodeSessionInfo info) async {
    if (noLocalFolder(info.workingDir)) return;
    final project = ref.read(codeProjectsProvider).where((p) => p.id == info.projectId).firstOrNull;
    try {
      final c = await ProjectContext.forSession(
        workingDir: info.workingDir,
        projectDir: project?.path ?? info.workingDir,
      );
      await c.atStart();
      _context = c;
    } on Object {
      // Without it, nested instruction files just aren't delivered.
    }
  }

  Future<void> _loadSettingsRules(CodeSessionInfo info) async {
    if (noLocalFolder(info.workingDir)) return;
    final project = ref.read(codeProjectsProvider).where((p) => p.id == info.projectId).firstOrNull;
    try {
      final s = await loadAgentSettings(project?.path ?? info.workingDir);
      _settingsRules = PermissionRules(allow: s.allow, deny: s.deny);
    } on Object {
      return;
    }
    if (!ref.mounted) return;
    // Only a batch still left for the user is decided again: one answered
    // before the rules arrived keeps its answer (resetting [_answered] here
    // sent it a second time while it still showed as pending).
    _autoRespond(state.transcript);
  }

  /// What decides this session's actions: stored rules (global, project),
  /// then `settings.json` rules, plus approvals remembered for the session.
  PermissionPolicy get policy {
    final info = ref.read(codeSessionsProvider.notifier).byId(sessionId);
    return PermissionPolicy(
      rules: ref.read(codePermissionsProvider).rulesFor(info?.projectId) + _settingsRules,
      session: {..._sessionAllowed},
      workingDir: info == null || isDemoPath(info.workingDir) ? null : info.workingDir,
      hostTools: info != null && isOutsideLead(info.harness, info.workingDir),
    );
  }

  void _onEvent(HarnessEvent event) {
    if (event is ConnectionChange) {
      state = state.copyWith(connected: event.connected);
      return;
    }
    // A lead that came back replays its conversation; the timeline already shows the old part.
    if (event.id.isNotEmpty && _replayed.contains(event.id)) {
      _events.add(event);
      _trackContext(event);
      return;
    }
    if (_live && event is ConversationFailure && isGatewayAuthFailure(event.message)) {
      unawaited(_renewGatewayKey());
    }
    if (event is ChatMessage && event.fromUser) {
      _doom.reset();
      _doomOpen = false;
    }
    final looped = event is ActionCall && _doom.add(event) && _live;
    event = _spilled(event);
    // Live only, like deltas: a retry note is not part of what the session replays.
    if (event is! StreamDelta && event is! RetryState) _events.add(event);
    // A state change refreshes the meter; the cost lives in our ledger, or an outside driver reports it.
    if (event is StateChange) ref.read(codeUsageProvider(sessionId).notifier).refreshSoon();
    if (event is UsageReport) ref.read(codeUsageProvider(sessionId).notifier).report(event);
    final wasRunning = state.transcript.running;
    _trackContext(event);
    _builder.add(event);
    if (!_mirror.isClosed) _mirror.add(event);
    final transcript = _builder.snapshot;
    state = state.copyWith(transcript: transcript);
    if (_hostWaits.isNotEmpty) _bindHostWaits();
    // An answer goes with its call's result, and the rest when the run ends.
    // Not when the batch moves on: a driver that runs each call once it is
    // allowed (OpenCode) can ask about the next one while the first still
    // runs, and that one must not be asked about again.
    final ended = !transcript.running && transcript.pending.isEmpty && transcript.held.isEmpty;
    final settled = event is ToolResult ? event.actionId : null;
    if (_decided.isNotEmpty && (ended || _decided.containsKey(settled))) {
      if (ended) {
        _decided.clear();
      } else {
        _decided.remove(settled);
      }
      state = state.copyWith(decided: Map.unmodifiable(_decided));
    }
    // Edits and commands change files: refresh Changes as they land, not just at turn end.
    if (event is ToolResult && editsFiles(event.toolName)) _refreshGitSoon();
    if (wasRunning && !transcript.running) {
      _refreshGitSoon();
      // The ledger can trail the last model call, so read it again once it settles.
      ref.read(codeUsageProvider(sessionId).notifier)
        ..refreshSoon(delay: const Duration(milliseconds: 300))
        ..refreshSoon(delay: const Duration(seconds: 4), force: true);
    }
    if (looped) _raiseDoomLoop(_doom.looped!);
    _autoRespond(transcript);
    _ultraResearch(transcript);
    _syncSubagents();
    _syncForkTools();
    _deliver();
    _goalTick(turnEnded: wasRunning && !transcript.running);
    _sendQueued();
  }

  /// Sends the next queued message once nothing runs or waits (and no lead switch is under way).
  void _sendQueued() {
    final t = state.transcript;
    if (_switching || t.running || t.pending.isNotEmpty || t.openSubagents.isNotEmpty || state.queued.isEmpty) return;
    final [next, ...rest] = state.queued;
    state = state.copyWith(queued: rest);
    if (_withinBudget()) unawaited(_checkpoint().then((_) => _sendNow(next)));
  }

  /// [event] with a result over the output limits cut to a preview; the whole
  /// text goes to `.everyai/spill/` in the project.
  HarnessEvent _spilled(HarnessEvent event) {
    if (event is! ToolResult) return event;
    final spill = spillOf(event);
    final info = ref.read(codeSessionsProvider.notifier).byId(sessionId);
    if (spill == null || info == null || noLocalFolder(info.workingDir)) return event;
    final id = event.toolCallId.isNotEmpty ? event.toolCallId : event.id;
    final path = saveSpill(info.workingDir, Spill.fileName(id), spill.text);
    return path == null ? event : withPreview(event, spillPreview(spill, path));
  }

  /// Pauses the run and asks the user what to do about [call] repeating.
  void _raiseDoomLoop(ActionCall call) {
    _doomOpen = true;
    final what = loopedStep(call);
    final card = ActionCall(
      id: 'doom-${call.id}',
      raw: const {},
      toolName: askUserQuestionTool,
      toolCallId: 'doom-${call.id}',
      action: const {},
    );
    _builder.addLocalQuestion(card, [
      Question(
        header: 'Repeating',
        question: 'The agent has run the same step $doomLoopRepeats times in a row ($what). It is paused. What now?',
        options: const [
          QuestionOption('Let it continue', 'It may be waiting on something slow; keep going as before.'),
          QuestionOption('Stop and change approach', 'Tell it to stop repeating this and try something different.'),
        ],
      ),
    ]);
    state = state.copyWith(transcript: _builder.snapshot);
    unawaited(_session?.pause());
  }

  Future<void> _answerDoomLoop(QuestionItem item, List<QuestionAnswer> answers) async {
    final session = _session;
    if (session == null) return;
    final a = answers.firstOrNull ?? const QuestionAnswer();
    _builder.settleLocal(item.call.id, answers);
    state = state.copyWith(transcript: _builder.snapshot);
    _doom.reset();
    _doomOpen = false;
    if (a.other.trim().isEmpty && !a.selected.contains(1)) {
      await session.resume();
      _autoRespond(state.transcript);
      return;
    }
    final said = a.other.trim().isEmpty ? '' : ' The user says: ${a.other.trim()}';
    final text =
        'You called the same tool with the same input $doomLoopRepeats times in a row without making progress. '
        'Do not repeat it. Take a different approach, or explain what is blocking you.$said';
    final pending = state.transcript.pending;
    if (pending.isNotEmpty) {
      _answered = pending.map((c) => c.id).join(',');
      await session.respond(accept: false, reason: text);
    }
    // It becomes a user turn like any other, so it gets a checkpoint to rewind to.
    await _checkpoint();
    await session.send(_noted(text));
  }

  void _trackContext(HarnessEvent event) {
    final c = _context;
    if (c == null) return;
    switch (event) {
      case ActionCall():
        unawaited(c.touch(event).catchError((Object _) {}));
      case ChatMessage(fromUser: true, :final text):
        final (paths, _) = splitContextNotes(splitModeNote(text).$2);
        if (paths.isNotEmpty) c.delivered(paths);
      default:
        break;
    }
  }

  Timer? _gitTimer;

  /// Coalesces bursts of edits into one `git diff`.
  void _refreshGitSoon() {
    if (_gitTimer?.isActive ?? false) return;
    _gitTimer = Timer(const Duration(milliseconds: 400), () {
      if (ref.mounted && ref.exists(codeGitProvider(sessionId))) {
        unawaited(ref.read(codeGitProvider(sessionId).notifier).refresh());
      }
    });
  }

  /// Whether this session answers cards and plans inside the held call.
  bool get _holds => ref.read(codeSessionsProvider.notifier).byId(sessionId)?.holdClientTools ?? false;

  bool get _isSubagent => ref.read(codeSessionsProvider.notifier).byId(sessionId)?.isSubagent ?? false;

  /// The plan last approved on the user's behalf (Full auto, Max flow).
  String _autoPlanned = '';

  /// Approves or refuses pending actions the mode decides on its own.
  void _autoRespond(Transcript t) {
    if (_doomOpen) return;
    // In Full auto a Max or Ultra plan goes ahead once the user has answered
    // the flow's questions; in other modes it waits for them.
    final plan = t.openPlan?.call;
    if (state.mode == AgentMode.fullAuto && t.phase?.phase == Phase.plan && plan != null && _autoPlanned != plan.id) {
      // Not before the call is held (the status comes one event after it):
      // approving earlier goes out as a message, which closes the held plan
      // as "the user wants changes", so the flow never leaves plan.
      if (_holds && !t.held.any((c) => c.id == plan.id)) return;
      _autoPlanned = plan.id;
      unawaited(startBuilding());
      return;
    }
    // A held card or plan waits for the user (one answer covers every
    // pending action, so the rest wait with it); sessions that don't hold
    // them approve them at once, as the agent ends its turn after the call.
    if (t.held.isNotEmpty && _holds) return;
    final waiting = [...t.pending, ...t.held];
    if (waiting.isEmpty) return;
    final key = waiting.map((c) => c.id).join(',');
    if (key == _answered) return;
    if (perCall) return _autoRespondEach(waiting, t);
    // Before any mode's rules: a file a running subagent works on, or a
    // project file before a Max/Ultra plan is approved, is not touched.
    if (_mustWait(waiting, t) case final reason?) {
      _answered = key;
      final session = _session;
      unawaited(session?.respond(accept: false, reason: reason).then((_) => session.resume()));
      return;
    }
    final verdict = _gated(waiting, policy.decideAll(waiting, state.mode, askMcp: beforeBuild(t.phase?.phase)));
    if (verdict == null) return;
    // Over budget: nothing is approved on its own; the run stops instead.
    if (verdict.accept && !_withinBudget()) {
      unawaited(stop());
      return;
    }
    _answered = key;
    final session = _session;
    if (verdict.accept) {
      unawaited(session?.respond(accept: true));
    } else {
      // The server parks the conversation after a rejection; run it again so
      // the agent reads the refusal (Plan mode, the safety floor, a deny
      // rule) and carries on (a user's own "No" still stops it).
      unawaited(session?.respond(accept: false, reason: verdict.reason).then((_) => session.resume()));
    }
  }

  /// Whether the session takes one answer per pending call.
  bool get perCall => _session is PerCallApprovals;

  /// The driver the session runs on (the demo's is the EveryAI one).
  HarnessDriver get _driver {
    final registry = ref.read(driverRegistryProvider);
    final name = ref.read(codeSessionsProvider.notifier).byId(sessionId)?.harness ?? everyaiHarnessName;
    return registry.resolve(name) ?? registry.resolve(everyaiHarnessName)!;
  }

  /// [verdict], except that an outside driver's own tools (kinds the rules
  /// can't judge) are never approved without the user, even in Full auto.
  ({bool accept, String? reason})? _gated(List<ActionCall> calls, ({bool accept, String? reason})? verdict) {
    if (verdict == null || !verdict.accept || _driver.info.id == everyaiHarnessName) return verdict;
    return calls.every(autoDecidable) ? verdict : null;
  }

  /// Answers given to the calls waiting now (see [CodeSessionState.decided]).
  final _decided = <String, bool>{};

  void _markDecided(Iterable<String> ids, {required bool accept}) {
    for (final id in ids) {
      _decided[id] = accept;
    }
    state = state.copyWith(decided: Map.unmodifiable(_decided));
  }

  /// [_autoRespond] for sessions that take one answer per call: each call
  /// the rules settle is answered at once, so the card only shows the rest.
  void _autoRespondEach(List<ActionCall> waiting, Transcript t) {
    final session = _session;
    if (session == null) return;
    for (final call in waiting) {
      if (_decided.containsKey(call.id)) continue;
      // A fork's question waits for the agent that started it (answerFromOrchestrator).
      if (_isSubagent && isHeldTool(call)) continue;
      final verdict = switch (_mustWait([call], t)) {
        final reason? => (accept: false, reason: reason),
        null => _gated([call], policy.decideAll([call], state.mode, askMcp: beforeBuild(t.phase?.phase))),
      };
      if (verdict == null) continue;
      // Over budget: nothing is approved on its own; the run stops instead.
      if (verdict.accept && !_withinBudget()) {
        unawaited(stop());
        return;
      }
      _markDecided([call.id], accept: verdict.accept);
      unawaited(session.respond(accept: verdict.accept, reason: verdict.reason, callIds: [call.id]));
    }
  }

  /// Why the [waiting] actions are refused before the mode decides: one
  /// changes a file a running subagent works on, or writes a project file in a
  /// Max/Ultra phase before Build.
  String? _mustWait(List<ActionCall> waiting, Transcript t) {
    final dir = ref.read(codeSessionsProvider.notifier).byId(sessionId)?.workingDir;
    if (dir == null) return null;
    final p = t.phase;
    final owned = _subagentFiles();
    for (final call in waiting) {
      if (p != null) {
        if (refusedBeforeBuild(call, p.phase, flowLabel(p.flow), dir) case final reason?) return reason;
      }
      if (waitForSubagent(call, owned, dir) case final reason?) return reason;
    }
    return null;
  }

  /// The files each running subagent works on, by its title, relative to its
  /// folder (which is this session's, or its own copy of it): the ones it has
  /// written so far, and for a fork that builds, the ones its task names.
  Map<String, Set<String>> _subagentFiles() {
    final sessions = ref.read(codeSessionsProvider.notifier);
    final out = <String, Set<String>>{};
    for (final MapEntry(key: callId, value: childId) in _childOf.entries) {
      final child = sessions.byId(childId);
      if (child == null) continue;
      final call = _calls[callId];
      final task = call == null ? null : SubagentTask.of(call);
      final files = {
        if (ref.exists(codeSessionProvider(childId)))
          ...filesWritten(ref.read(codeSessionProvider(childId).notifier).mirrorEvents, child.workingDir),
        if (task != null && task.agent.isEmpty) ...filesNamed('${task.description}\n${task.prompt}'),
      };
      if (files.isNotEmpty) out.update(child.title, (f) => f..addAll(files), ifAbsent: () => files);
    }
    return out;
  }

  /// Snapshots the worktree before the next user turn, so "Restore files"
  /// can bring it back. Turn 1 needs none: it's the base commit.
  Future<void> _checkpoint() async {
    final w = ref.read(codeSessionsProvider.notifier).byId(sessionId)?.worktree;
    final turn = state.transcript.items.whereType<UserTurn>().length + 1;
    if (w == null || turn < 2) return;
    try {
      await GitService.checkpoint(w, turn);
    } on Object {
      // A missing checkpoint only disables rewinding to this turn.
    }
  }

  /// Moves the session to [tier] from the next message: the system prompt
  /// keeps its first tier (the cache holds), and a note says what changed.
  void setTier(HarnessTier tier) {
    final sessions = ref.read(codeSessionsProvider.notifier);
    final info = sessions.byId(sessionId);
    if (info == null || info.tier == tier) return;
    sessions.update(info.copyWith(tier: tier));
    _tierNote = tierChangeNote(tier, forks: !info.isSubagent);
    _syncFlow();
  }

  /// The flow the session's tier and mode call for, on the harness.
  void _syncFlow() {
    final info = ref.read(codeSessionsProvider.notifier).byId(sessionId);
    if (info == null || info.isSubagent) return;
    final flow = info.harnessMode == HarnessMode.bugFix
        ? (info.tier == HarnessTier.ultra ? 'bugfix-ultra' : 'bugfix')
        : info.tier.phased
        ? info.tier.name
        : null;
    if (_session case final PhasedSession phased) unawaited(phased.setPhaseFlow(flow));
  }

  /// Moves the session between Build and Bug fix; the flow starts over.
  void setHarnessMode(HarnessMode mode) {
    final sessions = ref.read(codeSessionsProvider.notifier);
    final info = sessions.byId(sessionId);
    if (info == null || info.harnessMode == mode) return;
    sessions.update(info.copyWith(harnessMode: mode));
    _tierNote = mode == HarnessMode.bugFix
        ? 'The user moved this session to Bug fix mode. From now on these rules apply:\n$bugFixRules'
        : 'The user moved this session back to Build mode: the Bug fix rules no longer apply.';
    _syncFlow();
  }

  String _tierNote = '';

  /// `/skip-phase`: moves the Max or Ultra flow past where it is stuck.
  void skipPhase() {
    if (_session case final PhasedSession phased) unawaited(phased.skipPhase());
  }

  /// [text] with a mode note: the full one after a mode change, else a short reminder.
  /// Nested instruction files found since the last message go first, after the mode note.
  String _noted(String text) {
    final told = state.transcript.notedMode;
    final context = [_context?.takeNote() ?? '', _tierNote].where((n) => n.isNotEmpty).join('\n\n');
    _tierNote = '';
    final body = context.isEmpty ? text : (text.isEmpty ? context : '$context\n\n$text');
    final subagent = ref.read(codeSessionsProvider.notifier).byId(sessionId)?.isSubagent ?? false;
    final full = told != state.mode || _freshLead;
    _freshLead = false;
    return modeNote(state.mode, body, full: full, from: told, subagent: subagent);
  }

  Future<Outgoing?> _outgoing(String text, List<Attachment> files) async {
    final t = text.trim();
    if (t.isEmpty && files.isEmpty) return null;
    final info = ref.read(codeSessionsProvider.notifier).byId(sessionId);
    if (info == null) return Outgoing(t);
    try {
      return await prepareMessage(ref, text: t, workingDir: info.workingDir, model: info.model, files: files);
    } on Object catch (e) {
      state = state.copyWith(error: "Couldn't save the attachments: $e");
      return null;
    }
  }

  /// Sends [text] (and [files], saved into the project), or queues it while the agent is busy.
  @override
  Future<void> send(String text, {List<Attachment> files = const []}) async {
    if (!_withinBudget()) return;
    final out = await _outgoing(text, files);
    if (out == null) return;
    // An outside agent waiting on a card is mid-turn: free it, so the turn can end and the message go out.
    _releaseHostCards();
    final t = state.transcript;
    // During a lead switch it waits for the new lead.
    if (_switching || t.running || t.pending.isNotEmpty || t.openSubagents.isNotEmpty) {
      state = state.copyWith(queued: [...state.queued, out]);
      return;
    }
    await _checkpoint();
    await _sendNow(out);
  }

  /// Sends [out]. A card or plan still held for the user is closed first: the
  /// call's result says the user replied in chat, and the message follows.
  Future<void> _sendNow(Outgoing out) async {
    final session = _session;
    if (session == null) return;
    _releaseHostCards();
    _touchHost();
    final held = state.transcript.held;
    if (held.isNotEmpty) {
      _answered = [...state.transcript.pending, ...held].map((c) => c.id).join(',');
      final plan = held.any((c) => c.toolName == presentPlanTool);
      final reason = plan
          ? '$planRevisionLead see their next message.'
          : held.every(isTaskCall)
          ? subagentInterrupted
          : repliedInChat;
      await session.respond(accept: false, reason: reason);
    }
    // A handoff not sent yet (the user switched from the menu) goes with this message.
    final sessions = ref.read(codeSessionsProvider.notifier);
    final pending = sessions.byId(sessionId)?.pendingHandoff ?? '';
    await session.send(_noted(pending.isEmpty ? out.text : '$pending\n\n${out.text}'), images: out.images);
    if (pending.isNotEmpty) {
      if (sessions.byId(sessionId) case final info?) sessions.update(info.copyWith(pendingHandoff: ''));
    }
  }

  /// Keeps an outside session's host token alive at each turn; one that
  /// already expired (a long idle time) gets a note, and the session goes on
  /// without EveryAI's tools.
  void _touchHost() {
    final tokens = ref.read(_hostTokensProvider);
    final token = tokens[sessionId];
    if (token == null || ref.read(hostServerProvider).touch(token)) return;
    tokens.remove(sessionId);
    _builder.addNotice(NoticeItem('host-expired-${_events.length}', hostToolsExpired));
    state = state.copyWith(transcript: _builder.snapshot);
  }

  /// Interrupts the agent and sends [text] right away.
  Future<void> steer(String text, {List<Attachment> files = const []}) async {
    if (!_withinBudget()) return;
    final out = await _outgoing(text, files);
    final session = _session;
    if (out == null || session == null) return;
    // The lead is changing: it goes to the new one, like a message.
    if (_switching) {
      state = state.copyWith(queued: [...state.queued, out]);
      return;
    }
    // An outside agent blocked on a card reads the steer only once the call returns.
    _releaseHostCards();
    _touchHost();
    await steerOrResend(
      session,
      _driver.caps,
      steer: (s) => s.steer(_noted(out.text), images: out.images),
      resend: () async {
        await _stopSubagents();
        await _checkpoint();
        await _sendNow(out);
      },
    );
  }

  /// Shortens the agent's context: old tool output is cleared, the older part
  /// of the conversation is summarized by [compactionModel] (keeping what
  /// [focus] asks for), and the session moves to a new conversation that
  /// starts with the summary and the newest turns word for word. With
  /// [resume] the agent carries on at once; otherwise it waits for the next
  /// message. The transcript so far stays on screen.
  ///
  /// [summarizer] replaces the gateway call (tests).
  Future<CompactOutcome> compact({String focus = '', bool resume = false, Summarizer? summarizer}) async {
    final info = ref.read(codeSessionsProvider.notifier).byId(sessionId);
    final old = _session;
    if (info == null || old == null) return const CompactOutcome.failed('The session is not connected.');
    if (isDemoPath(info.workingDir)) return const CompactOutcome.failed("The demo session can't be compacted.");
    final t = state.transcript;
    if (_compacting || _switching || t.running || t.pending.isNotEmpty || t.held.isNotEmpty) {
      return const CompactOutcome.busy();
    }
    if (old case final CompactsInPlace inPlace) {
      // The EveryAI harness summarizes with the session's own model and keeps
      // the conversation; the "Context compacted" notice arrives as an event.
      _compacting = true;
      try {
        if (!await inPlace.compact(focus: focus)) return const CompactOutcome.nothing();
        if (resume) await old.resume();
        return const CompactOutcome.compacted('');
      } on Object catch (e) {
        return CompactOutcome.failed('$e');
      } finally {
        _compacting = false;
      }
    }
    // An outside CLI keeps its own context: a summary through the gateway would bill credits and a fresh
    // conversation would lose its EveryAI tools.
    if (isOutsideLead(info.harness, info.workingDir)) {
      return CompactOutcome.failed('${_driver.info.label} keeps its own context and compacts it on its own.');
    }
    final plan = planCompaction(_events);
    if (plan == null) return const CompactOutcome.nothing();
    _compacting = true;
    try {
      final summarize =
          summarizer ??
          gatewaySummarizer(
            baseUrl: gatewayBaseUrl(ref),
            apiKey: await gatewayKey(ref),
            sessionTag: info.billingTag,
            onUnauthorized: (k) => remintGatewayKey(ref, k),
          );
      final summary = cleanSummary(await summarize(summaryRequest(plan, focus: focus)));
      if (summary == null) return const CompactOutcome.failed("The summary didn't come back in the expected form.");
      final message = continuationMessage(summary: summary, recent: renderTail(plan), resume: resume);
      final project = ref.read(codeProjectsProvider).where((p) => p.id == info.projectId).firstOrNull;
      final sessions = ref.read(codeSessionsProvider.notifier);
      final spec = await sessions.specFor(
        sessionId: info.id,
        projectDir: project?.path ?? info.workingDir,
        workingDir: info.workingDir,
        model: info.model,
        mode: state.mode,
        effort: info.effort,
        holdClientTools: info.holdClientTools,
        // A compacted subagent still bills where it did.
        sessionTag: info.billingTag,
        initialMessage: modeNote(state.mode, message),
        runInitial: resume,
        isolated: info.worktree != null,
      );
      final live = await (await harnessFor(ref, info.workingDir, harness: info.harness)).start(spec);
      if (!ref.mounted) {
        unawaited(live.close());
        return const CompactOutcome.failed('The session was closed.');
      }
      // Swap conversations; the transcript builder keeps what's on screen.
      await _sub?.cancel();
      unawaited(old.close());
      ref.read(_liveProvider)[sessionId] = live;
      _session = live;
      _events.clear();
      if (!_mirror.isClosed) _mirror.add(null);
      _carried = _builder.snapshot.items;
      _answered = '';
      _doom.reset();
      sessions.update(
        info.copyWith(conversationId: live.id, compactedFrom: [...info.compactedFrom, info.conversationId]),
      );
      // Nested instruction files were in the old context; they go out again when touched.
      await _openContext(info);
      _sub = live.events.listen(_onEvent);
      return CompactOutcome.compacted(summary);
    } on Object catch (e) {
      return CompactOutcome.failed('$e');
    } finally {
      _compacting = false;
    }
  }

  /// The agent is working, or waits on the user or on subagents.
  bool get _busy {
    final t = state.transcript;
    return t.running || t.pending.isNotEmpty || t.held.isNotEmpty || t.openSubagents.isNotEmpty;
  }

  /// Whether a switch to [to] moves the session off the EveryAI harness while
  /// children of it still work with no card open: background forks and Ultra
  /// research workers (queued or starting too). They would keep spending, so
  /// the switch stops them, once the user agrees.
  bool leaveStopsChildren(String to) {
    final info = ref.read(codeSessionsProvider.notifier).byId(sessionId);
    if (info == null || isOutsideLead(info.harness, info.workingDir) || !isOutsideLead(to, info.workingDir)) {
      return false;
    }
    return _background.isNotEmpty ||
        _researchQueue.isNotEmpty ||
        _researchLaunching > 0 ||
        _researchStarting != null ||
        _researchers.any((r) => !_researchReports.containsKey(r.parentCallId));
  }

  /// Stops the background forks and the research round's workers, and drops
  /// the queued ones; their reports don't go to the next lead.
  Future<void> _stopEveryaiChildren() async {
    _researchQueue.clear();
    _researchTimer?.cancel();
    _researchTimer = null;
    _researchStarting = null;
    _researchSent = _researchRun;
    for (final sub in _researchSubs.values) {
      sub.close();
    }
    _researchSubs.clear();
    final children = {
      for (final r in _researchers)
        if (!_researchReports.containsKey(r.parentCallId)) r.id,
    };
    for (final MapEntry(key: callId, value: bg) in _background.entries) {
      children.add(bg.childId);
      _calls.remove(callId);
      _childOf.remove(callId);
      _childSubs.remove(callId)?.close();
      _childWaiting.remove(callId);
    }
    _background.clear();
    state = state.copyWith(subagentNeedsInput: _childWaiting.isNotEmpty);
    await Future.wait([
      for (final c in children)
        if (ref.exists(codeSessionProvider(c))) ref.read(codeSessionProvider(c).notifier).stop(),
    ]);
  }

  /// Whether the session is led by an outside harness now: the research
  /// workflow (EveryAI's) neither starts workers nor sends reports then.
  bool get _onOutsideLead {
    final info = ref.read(codeSessionsProvider.notifier).byId(sessionId);
    return info != null && isOutsideLead(info.harness, info.workingDir);
  }

  /// Stops the run and waits (up to 5 s) until the agent says it stopped.
  /// False while it still runs.
  Future<bool> _stopAndSettle() async {
    if (!_busy) return true;
    await stop();
    final end = DateTime.now().add(const Duration(seconds: 5));
    while (ref.mounted && state.transcript.running && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return ref.mounted && !state.transcript.running;
  }

  /// The usage limit the lead stopped on, while the session offers to carry
  /// on with another harness: the last thing shown is the limit, nothing
  /// runs, and the user hasn't chosen Wait.
  UsageLimit? get leadOffer {
    final info = ref.read(codeSessionsProvider.notifier).byId(sessionId);
    if (info == null || info.isSubagent || isDemoPath(info.workingDir) || _busy) return null;
    return switch (state.transcript.items.lastOrNull) {
      NoticeItem(:final key, :final limit?) when key != state.waited => limit,
      _ => null,
    };
  }

  /// "Wait" on the offer: the session stays on its lead.
  void waitForLimit() {
    if (state.transcript.items.lastOrNull case NoticeItem(:final key, limit: _?)) {
      state = state.copyWith(waited: key);
    }
  }

  /// The model and effort [harness] leads with: what it ran on in this
  /// session, else what the user picked for new sessions on it.
  ({String model, String effort}) leadModelFor(String harness) {
    final info = ref.read(codeSessionsProvider.notifier).byId(sessionId);
    if (info?.leads[harness] case final rec?) return (model: rec.model, effort: rec.effort);
    if (harness == everyaiHarnessName) {
      final c = ref.read(codeAgentProvider);
      return (model: c.model, effort: c.effort);
    }
    return ref.read(codeLeadProvider).of(harness);
  }

  /// Moves the session to another lead harness [to]. The old lead stops (its
  /// conversation is kept), and the new one gets a handoff built from the
  /// session and the repository: everything the first time, only what it
  /// missed when it comes back to a conversation it can reopen. With [run]
  /// it carries on at once; otherwise the handoff goes with the user's next
  /// message. A busy session is stopped first only with [stopFirst] (the
  /// user agreed). The worktree, mode and permissions stay the session's.
  /// The handoff costs nothing: it is built from the session and the
  /// repository, with no model call (see `buildHandoff`).
  Future<LeadSwitchOutcome> switchLead(String to, {required bool run, bool stopFirst = false}) async {
    final sessions = ref.read(codeSessionsProvider.notifier);
    final info = sessions.byId(sessionId);
    if (info == null || _session == null) return const LeadSwitchOutcome.failed('The session is not connected.');
    if (info.isSubagent || isDemoPath(info.workingDir)) {
      return const LeadSwitchOutcome.failed("This session can't change harness.");
    }
    if (info.harness == to) return const LeadSwitchOutcome.failed('The session already runs on it.');
    if (_compacting || _switching) return const LeadSwitchOutcome.busy();
    final target = ref.read(driverRegistryProvider).resolve(to);
    if (target == null) return LeadSwitchOutcome.failed("This version of the app doesn't have $to.");
    // From here on, messages wait for the new lead (see [send]).
    _switching = true;
    state = state.copyWith(switching: true);
    var started = false;
    try {
      final Map<String, DriverStatus> statuses;
      try {
        statuses = await ref.read(driverStatusesProvider.future);
      } on Object catch (e) {
        return LeadSwitchOutcome.failed('$e');
      }
      final own = ref.read(codeSettingsProvider).ownClis;
      if (leadBlocked(target.info, statuses[to], consented: own.contains(target.info.consentId)) case final why?) {
        return LeadSwitchOutcome.failed('${target.info.label}: $why');
      }
      if (_busy && (!stopFirst || !await _stopAndSettle())) return const LeadSwitchOutcome.busy();
      // EveryAI spends nothing once it no longer leads: its background forks
      // and Ultra researchers stop too (the user agreed, see [leaveStopsChildren]).
      if (leaveStopsChildren(to)) {
        if (!stopFirst) return const LeadSwitchOutcome.busy();
        await _stopEveryaiChildren();
      }
      if (!ref.mounted) return const LeadSwitchOutcome.failed('The session was closed.');
      final outcome = await _switchLead(sessions.byId(sessionId) ?? info, target, run: run);
      started = run && !outcome.failed;
      return outcome;
    } finally {
      _switching = false;
      if (ref.mounted) {
        state = state.copyWith(switching: false);
        // A lead that carries on at once gets them when its turn ends.
        if (!started) _sendQueued();
      }
    }
  }

  Future<LeadSwitchOutcome> _switchLead(CodeSessionInfo info, HarnessDriver target, {required bool run}) async {
    final sessions = ref.read(codeSessionsProvider.notifier);
    final old = _session!;
    final from = info.harness;
    final to = target.info.id;
    final fromLabel = _leadLabel(from);
    final dir = await sessions.timelineDir(sessionId);
    final outside = isOutsideLead(to, info.workingDir);
    final rec = info.leads[to];
    final pick = rec == null ? leadModelFor(to) : (model: rec.model, effort: rec.effort);
    // Max, Ultra and Bug fix need the EveryAI harness's phase control.
    final tier = outside && info.tier.phased ? HarnessTier.thorough : info.tier;
    final harnessMode = outside ? HarnessMode.build : info.harnessMode;

    // The session's record: earlier leads' stints, then this one's own events.
    final current = [
      for (final e in _events)
        if (!_replayed.contains(e.id)) e,
    ];
    final record = [for (final s in _timeline) ...s.events, ...current];
    List<Handoff> stored;
    try {
      stored = await loadHandoffs(dir);
    } on Object {
      stored = const [];
    }
    final since = placedSince(_timeline, current, lastSeenBy(stored, to));
    final git = noLocalFolder(info.workingDir) ? null : await handoffGit(info);
    // The whole conversation as a file the new lead may read (and summarise for itself).
    final now = DateTime.now();
    var transcript = noLocalFolder(info.workingDir) ? '' : handoffTranscriptPath(now, to);
    if (transcript.isNotEmpty) {
      final stints = [
        for (final s in _timeline) (lead: _leadLabel(s.harness), conversationId: s.conversationId, events: s.events),
        (lead: fromLabel, conversationId: info.conversationId, events: current),
      ];
      try {
        if (!await writeHandoffTranscript(info.workingDir, transcript, handoffTranscript(stints, title: info.title))) {
          transcript = '';
        }
      } on Object {
        transcript = '';
      }
    }
    var resumable = rec != null && rec.conversationId.isNotEmpty && target.caps.contains(DriverCap.resume);

    // The old lead is kept for a return. One that never got its handoff (a
    // menu switch, then away before any message) hasn't seen the work, so its
    // next return starts afresh with everything.
    final leads = {
      ...info.leads,
      from: LeadRecord(
        conversationId: info.pendingHandoff.isEmpty ? info.conversationId : '',
        model: info.model,
        effort: info.effort,
      ),
    }..remove(to);
    sessions.update(info.copyWith(leads: leads));
    // The files as they are now, so the handoff turn can be rewound to.
    await _checkpoint();
    // The old lead keeps its token (and its tools) until the new one is up.
    final host = ref.read(hostServerProvider);
    final tokens = ref.read(_hostTokensProvider);
    final oldToken = tokens[sessionId];
    final ready = Completer<void>();
    HarnessSession? live;
    final Handoff handoff;
    var carryOn = '';
    try {
      // Its old conversation is tried first: a delta needs it.
      if (handoffScope(record, since: since, resumable: resumable).kind == HandoffKind.delta) {
        try {
          live = await sessions.attachSession(
            info.copyWith(harness: to, conversationId: rec!.conversationId, model: pick.model, effort: pick.effort),
            keepCurrent: true,
          );
        } on Object {
          // Its conversation can't be reopened: a new one, with everything.
          resumable = false;
        }
      }
      handoff = buildHandoff(
        record,
        from: from,
        fromConversation: info.conversationId,
        to: to,
        workingDir: info.workingDir,
        since: since,
        resumable: resumable,
        now: now,
        git: git?.git,
        diffs: git?.diffs ?? const {},
        transcript: transcript,
      );
      carryOn = carryOnMessage(fromLabel, cut: handoff.cut != null);
      live ??= await sessions._startLead(
        info,
        harness: to,
        model: pick.model,
        effort: pick.effort,
        mode: state.mode,
        tier: tier,
        harnessMode: harnessMode,
        initialMessage: run
            ? modeNote(state.mode, '${handoffMessage(handoff, fromName: fromLabel)}\n\n$carryOn')
            : null,
        ready: ready.future,
      );
    } on Object catch (e) {
      if (!ready.isCompleted) ready.complete();
      if (live != null) unawaited(live.close());
      // The old lead stays in charge, with its own token and briefing.
      final minted = tokens[sessionId];
      if (minted != null && minted != oldToken) await host.revoke(minted);
      if (oldToken != null) {
        tokens[sessionId] = oldToken;
      } else {
        tokens.remove(sessionId);
      }
      if (outside) await sessions._restoreBriefing(info);
      if (ref.mounted) sessions.update(sessions.byId(sessionId)?.copyWith(leads: info.leads) ?? info);
      return LeadSwitchOutcome.failed('$e');
    }
    final message = handoffMessage(handoff, fromName: fromLabel);
    if (!ref.mounted) {
      unawaited(live.close());
      ready.complete();
      return const LeadSwitchOutcome.failed('The session was closed.');
    }

    // The old lead stops for good before the new one runs (a CLI still
    // closing would otherwise take the next reopen of its conversation).
    // The new lead is up, so a failure here only leaves the old one to exit.
    try {
      await _sub?.cancel();
      await old.close().timeout(const Duration(seconds: 3), onTimeout: () {});
    } on Object {
      // Nothing listens to it any more.
    }
    final segment = (harness: from, conversationId: info.conversationId, events: current);
    _timeline = [..._timeline, segment];
    try {
      await appendSegment(dir, segment);
      await saveHandoff(dir, handoff);
    } on Object {
      // The next start shows only the current lead's turns; the handoff still went out.
    }
    // An outside lead's EveryAI tools end with it (a new outside lead has its own token).
    if (isOutsideLead(from, info.workingDir) && !outside) {
      await sessions._unbrief(sessionId);
    } else if (oldToken != null && oldToken != tokens[sessionId]) {
      await host.revoke(oldToken);
    }
    if (!ref.mounted) {
      unawaited(live.close());
      ready.complete();
      return const LeadSwitchOutcome.failed('The session was closed.');
    }
    final next = (sessions.byId(sessionId) ?? info).copyWith(
      harness: to,
      conversationId: live.id,
      model: pick.model,
      effort: pick.effort,
      leads: leads,
      tier: tier,
      harnessMode: harnessMode,
      pendingHandoff: run ? '' : message,
    );
    sessions.update(next);

    // Swap conversations as compaction does; the transcript stays one timeline.
    ref.read(_liveProvider)[sessionId] = live;
    _session = live;
    _events.clear();
    _markReplayed(live.id);
    if (!_mirror.isClosed) _mirror.add(null);
    _settleSegment();
    // It is at work from the start: messages typed meanwhile wait for its turn to end.
    if (run) _builder.add(_statusEvent('running'));
    _builder.lead = target.info.label;
    _carried = _builder.snapshot.items;
    _answered = '';
    _doom.reset();
    _doomOpen = false;
    _freshLead = true;
    state = state.copyWith(transcript: _builder.snapshot, waited: '');
    if (ref.exists(codeUsageProvider(sessionId))) ref.read(codeUsageProvider(sessionId).notifier).leadChanged();
    await _openContext(next);
    if (!ref.mounted) {
      ready.complete();
      return const LeadSwitchOutcome.failed('The session was closed.');
    }
    // Replayed history is already skipped through [_replayed], so the lead is live at once.
    _sub = live.events.listen(_onEvent);
    ready.complete();
    if (!outside) _syncFlow();
    if (run && handoff.kind == HandoffKind.delta) {
      await live.send(_noted('$message\n\n$carryOn'));
    } else if (run) {
      // It started with the whole note.
      _freshLead = false;
    }
    return LeadSwitchOutcome.switched(handoff.kind);
  }

  /// Takes the session back to just before user turn [turn] (1-based): the
  /// agent's conversation moves its head to before that message, so it
  /// forgets it and everything after (the server keeps the old branch), and
  /// the files go back to the turn's checkpoint when the session has a
  /// worktree. A running agent is stopped first. Turns from before a
  /// compaction live in an older conversation: only their files come back.
  Future<RewindOutcome> rewind(int turn) async {
    final info = ref.read(codeSessionsProvider.notifier).byId(sessionId);
    final session = _session;
    if (info == null || session == null) return const RewindOutcome.failed('The session is not connected.');
    // Before anything is stopped or restored.
    if (rewindRefusal(_driver.info, _driver.caps) case final refusal?) return RewindOutcome.failed(refusal);
    if (_compacting || _switching) return const RewindOutcome.busy();
    final turns = state.transcript.items.whereType<UserTurn>().toList();
    if (turn < 1 || turn > turns.length) return const RewindOutcome.nothing();
    if (_busy) {
      final settled = await _stopAndSettle();
      if (!ref.mounted) return const RewindOutcome.failed('The session was closed.');
      if (!settled) return const RewindOutcome.busy();
    }
    final message = turns[turn - 1].key;
    var conversation = false;
    var note = '';
    if (_events.any((e) => e.id == message) && !_replayed.contains(message)) {
      final head = rewindHead(_events, message);
      try {
        await session.rewindTo(head);
      } on Object catch (e) {
        return RewindOutcome.failed('$e');
      }
      if (!ref.mounted) return const RewindOutcome.failed('The session was closed.');
      final kept = rewound(_events, head);
      _events
        ..clear()
        ..addAll(kept);
      _refold();
      conversation = true;
      // Instruction files sent in the forgotten turns go out again when touched.
      await _openContext(info);
      for (final e in kept) {
        if (e is ChatMessage && e.fromUser) _trackContext(e);
      }
    } else {
      note =
          'The agent still remembers: that turn is from an earlier conversation (before the session was compacted '
          'or moved to another harness).';
    }
    var files = false;
    if (info.worktree != null) {
      try {
        await ref.read(codeGitProvider(sessionId).notifier).rewind(turn);
        files = true;
      } on Object catch (e) {
        note = "The files weren't restored: $e";
      }
    } else if (conversation && !isDemoPath(info.workingDir)) {
      note = 'The files stay as they are (the session has no checkpoints).';
    }
    return RewindOutcome(kind: RewindKind.done, conversation: conversation, files: files, message: note);
  }

  /// Folds the transcript again from [_events] (after a rewind), keeping
  /// what earlier conversations showed. Cards the app raised itself go.
  void _refold() {
    final lead = _builder.lead;
    _builder = TranscriptBuilder()
      ..carry(_carried)
      ..lead = lead;
    for (final e in _events) {
      if (!_replayed.contains(e.id)) _builder.add(e);
    }
    // The server is idle now, whatever the kept branch last said.
    if (_builder.snapshot.status case ExecutionStatus.running || ExecutionStatus.waitingForConfirmation) {
      _builder.add(
        HarnessEvent.decode({
          'id': '',
          'kind': 'ConversationStateUpdateEvent',
          'key': 'execution_status',
          'value': 'idle',
        }),
      );
    }
    _answered = '';
    _doom.reset();
    _doomOpen = false;
    if (!_mirror.isClosed) _mirror.add(null);
    state = state.copyWith(transcript: _builder.snapshot, queued: const []);
  }

  void unqueue(int index) => state = state.copyWith(queued: [...state.queued]..removeAt(index));

  @override
  int _asideIds = 0;

  /// Shows [aside]: in place when it is already shown (an answer arriving), else at the end.
  @override
  void _putAside(Aside aside) {
    final i = state.asides.indexWhere((a) => a.id == aside.id);
    state = state.copyWith(asides: i < 0 ? [...state.asides, aside] : ([...state.asides]..[i] = aside));
  }

  @override
  void dismissAside(int id) => state = state.copyWith(
    asides: [
      for (final a in state.asides)
        if (a.id != id) a,
    ],
  );

  /// Answers [question] off to the side, on the session's own model (the one
  /// picked in the composer), reading the session so far (`/btw`). The agent
  /// is neither interrupted nor told: the call is separate, and the answer
  /// shows as an aside card. Billed to the session (or the model's key).
  /// Off on an outside lead, where EveryAI spends nothing.
  /// [summarizer] replaces the gateway call (tests).
  Future<void> askAside(String question, {Summarizer? summarizer}) async {
    final info = ref.read(codeSessionsProvider.notifier).byId(sessionId);
    final aside = Aside(id: ++_asideIds, kind: AsideKind.btw, question: question.trim(), busy: true);
    _putAside(aside);
    if (info != null && isOutsideLead(info.harness, info.workingDir)) {
      _putAside(aside.failed(btwOff(_leadLabel(info.harness))));
      return;
    }
    if (info == null || (summarizer == null && isDemoPath(info.workingDir))) {
      _putAside(aside.failed('Side questions need a real session (the demo has no model).'));
      return;
    }
    try {
      final ask =
          summarizer ??
          gatewaySummarizer(
            baseUrl: gatewayBaseUrl(ref),
            apiKey: await gatewayKey(ref),
            sessionTag: info.id,
            model: info.model,
            onUnauthorized: (k) => remintGatewayKey(ref, k),
          );
      final answer = await ask(btwRequest(record: renderSessionRecord(_events), question: question));
      if (!ref.mounted) return;
      if (state.asides.any((a) => a.id == aside.id)) _putAside(aside.done(answer.trim()));
    } on Object catch (e) {
      if (ref.mounted && state.asides.any((a) => a.id == aside.id)) _putAside(aside.failed('$e'));
    }
  }

  /// Shows the session's tokens and spend as an aside card (`/cost`).
  void showCost() {
    if (state.asides.any((a) => a.kind == AsideKind.cost)) return;
    if (ref.exists(codeUsageProvider(sessionId))) {
      ref.read(codeUsageProvider(sessionId).notifier).refreshSoon(delay: Duration.zero, force: true);
    }
    _putAside(Aside(id: ++_asideIds, kind: AsideKind.cost));
  }

  /// Moves the session to [model] and/or [effort] ('' is the model's default)
  /// through the harness's `switchLlm`; the history stays. Applies
  /// from the agent's next model call. Returns a message for the user.
  Future<String> switchModel({String? model, String? effort}) async {
    final sessions = ref.read(codeSessionsProvider.notifier);
    final info = sessions.byId(sessionId);
    if (info == null) return 'The session is gone.';
    final next = info.copyWith(model: model, effort: effort);
    if (next.model == info.model && next.effort == info.effort) return 'Already using that.';
    if (isOutsideLead(info.harness, info.workingDir) && !_driver.caps.contains(DriverCap.switchModel)) {
      return "${_driver.info.label} can't change model during a session. Start a new session to use another.";
    }
    final session = _session;
    if (session == null) return 'The session is not connected yet.';
    final project = ref.read(codeProjectsProvider).where((p) => p.id == info.projectId).firstOrNull;
    final spec = await sessions.specFor(
      sessionId: info.id,
      projectDir: project?.path ?? info.workingDir,
      workingDir: info.workingDir,
      model: next.model,
      mode: state.mode,
      effort: next.effort,
      holdClientTools: info.holdClientTools,
    );
    await session.switchLlm(spec);
    if (!ref.mounted) return '';
    sessions.update(next);
    final name = ref.read(modelCatalogProvider)[ModelId(next.model)]?.name ?? next.model.split('/').last;
    return next.effort.isEmpty ? 'Now using $name.' : 'Now using $name · ${next.effort}.';
  }

  DateTime? _keyRenewedAt;

  /// The gateway refused the agent's key (revoked, another account, a reset
  /// dev database): mint a new one, hand it to the agent and run again. Once
  /// per few minutes, so a refusal the new key doesn't fix can't loop.
  /// An outside lead's auth error is its own login (`/login`), not our key:
  /// nothing is minted and its turn is not run again (EveryAI spends nothing
  /// on a session it doesn't lead).
  Future<void> _renewGatewayKey() async {
    final sessions = ref.read(codeSessionsProvider.notifier);
    final info = sessions.byId(sessionId);
    final session = _session;
    if (info == null || session == null || isDemoPath(info.workingDir)) return;
    if (isOutsideLead(info.harness, info.workingDir)) return;
    final last = _keyRenewedAt;
    if (last != null && DateTime.now().difference(last) < const Duration(minutes: 5)) return;
    _keyRenewedAt = DateTime.now();
    try {
      await ref.read(gatewayKeysProvider).renewAfterRefusal();
      if (!ref.mounted) return;
      final project = ref.read(codeProjectsProvider).where((p) => p.id == info.projectId).firstOrNull;
      final spec = await sessions.specFor(
        sessionId: info.id,
        projectDir: project?.path ?? info.workingDir,
        workingDir: info.workingDir,
        model: info.model,
        mode: state.mode,
        effort: info.effort,
        holdClientTools: info.holdClientTools,
        // A subagent bills to the session that started it; an Ultra child to itself.
        sessionTag: info.billingTag,
      );
      await session.switchLlm(spec);
      await session.resume();
    } on Object {
      // The error stays in the transcript; Retry is still there.
    }
  }

  /// Runs the agent again after a failed turn (a dropped connection, an
  /// upstream error); the conversation keeps everything so far. A stuck
  /// agent needs a new message: the server's stuck check reads the history
  /// and would stop a plain re-run at once.
  Future<void> retry() async {
    if (!_withinBudget()) return;
    if (state.transcript.status == ExecutionStatus.stuck) return send('Carry on from where you stopped.');
    await _session?.resume();
  }

  /// Sends a model call being retried now instead of after its wait.
  Future<void> retryNow() async {
    if (_session case final RetriesModelCalls s) s.retryNow();
  }

  Future<void> stop() async {
    _doomOpen = false;
    _pauseGoal('Stopped by you. Set the goal again to carry on.');
    state = state.copyWith(queued: const []);
    for (final w in [..._hostWaits]) {
      _answerHost(w, denialMessage(DenialKind.cancelled), isError: true);
    }
    await _stopSubagents();
    final pending = state.transcript.pending;
    final info = ref.read(codeSessionsProvider.notifier).byId(sessionId);
    // A subagent tells the session that started it, which carries on without it.
    if (info?.parentId case final parent?) {
      if (ref.exists(codeSessionProvider(parent))) {
        ref.read(codeSessionProvider(parent).notifier).subagentStopped(sessionId, stoppedReport(state.transcript));
      }
    }
    if (pending.isNotEmpty || state.transcript.held.any(isTaskCall)) {
      _answered = [...pending, ...state.transcript.held].map((c) => c.id).join(',');
      await _session?.respond(accept: false, reason: denialMessage(DenialKind.cancelled));
    }
    // Ctrl-C reaches only the terminal's foreground command; background jobs,
    // servers and commands left running after a timeout are ended here. A
    // subagent shares its parent's tag, so only the parent's Stop does this;
    // an Ultra child has its own tag (and maybe its own worktree), so it does.
    await Future.wait([
      ?_session?.interrupt(),
      if (info != null && killsOwnProcesses(info))
        killSessionProcesses(
          tag: info.id,
          workingDir: info.workingDir,
          ownsDir: ownsWorkingDir(info, parent: ref.read(codeSessionsProvider.notifier).byId(info.parentId ?? '')),
        ),
    ]);
  }

  /// Starts a child conversation for each new `run_subagent` call, or picks up the
  /// one already running for it (after a restart). Replayed history never
  /// starts one: only calls still open once the session is live.
  void _syncSubagents() {
    if (!_live || !ref.mounted) return;
    final sessions = ref.read(codeSessionsProvider.notifier);
    final info = sessions.byId(sessionId);
    if (info == null || info.isSubagent) return;
    if (!_resumedBackground) {
      _resumedBackground = true;
      // Forks left in the background before a restart: watch them again, so
      // their notification (and merge) still comes; one already done reports now.
      for (final MapEntry(key: callId, value: childId) in unreportedBackground(_events).entries) {
        if (_childOf.containsKey(callId) || _background.containsKey(callId)) continue;
        final child = sessions.byId(childId);
        if (child == null) continue;
        _background[callId] = (childId: childId, title: child.title);
        _watch(callId, childId);
      }
    }
    final t = state.transcript;
    for (final item in t.openSubagents) {
      final id = item.step.call.id;
      if (_childOf.containsKey(id) || _reports.containsKey(id) || _spawning.contains(id)) continue;
      // A held call runs its subagent while the server waits for the result.
      if (_holds && !t.held.any((c) => c.id == id)) continue;
      if (sessions.subagentFor(sessionId, id) case final child?) {
        _watch(id, child.id);
      } else if (_notBeforeBuild(item.step.call, t) case final reason?) {
        _ready(id, SubagentReport(SubagentStatus.notStarted, reason));
      } else if (_childOf.length + _spawning.length >= maxConcurrentSubagents) {
        _ready(
          id,
          const SubagentReport(
            SubagentStatus.notStarted,
            'Not started: at most $maxConcurrentSubagents subagents run at once. Start it again once the others '
            'have reported.',
          ),
        );
      } else {
        unawaited(_spawn(id, item.step.call, info));
      }
    }
  }

  /// Why a subagent [call] waits for Build in a Max/Ultra flow, or null.
  static String? _notBeforeBuild(ActionCall call, Transcript t) => switch (t.phase) {
    final p? => subagentBeforeBuild(SubagentTask.of(call).agent, p.phase, flowLabel(p.flow)),
    null => null,
  };

  Future<void> _spawn(String callId, ActionCall call, CodeSessionInfo parent, {bool onParentModel = false}) async {
    _spawning.add(callId);
    _calls[callId] = call;
    try {
      final child = await ref
          .read(codeSessionsProvider.notifier)
          .startSubagent(parent: parent, call: call, mode: subagentMode(state.mode), onParentModel: onParentModel);
      if (!ref.mounted || _abandoned.remove(callId)) {
        unawaited(ref.read(_liveProvider)[child.id]?.interrupt());
        return;
      }
      _spawning.remove(callId);
      // It asked for its own copy and couldn't have one (no git repository here).
      if (call.str('isolation') == 'worktree' && child.forkCopy == null) _fellBack[callId] = sharedFolderNote;
      if (call.action['run_in_background'] == true && !onParentModel) {
        _background[callId] = (childId: child.id, title: child.title);
        _reports[callId] = backgroundStarted(child.id, note: _fellBack.remove(callId));
        _deliver();
      }
      _watch(callId, child.id);
    } on Object catch (e) {
      _spawning.remove(callId);
      if (ref.mounted && !_abandoned.remove(callId)) {
        _ready(callId, SubagentReport(SubagentStatus.notStarted, "The subagent couldn't start: $e"));
      }
    }
  }

  void _watch(String callId, String childId) {
    _childOf[callId] = childId;
    final sub = ref.listen(codeSessionProvider(childId), (_, next) => _onSubagent(callId, next), fireImmediately: true);
    // It may have finished already (fireImmediately).
    if (_childOf.containsKey(callId)) {
      _childSubs[callId] = sub;
    } else {
      sub.close();
    }
  }

  void _onSubagent(String callId, CodeSessionState child) {
    if (!_childOf.containsKey(callId)) return;
    final outcome = subagentOutcome(child.transcript, error: child.error);
    if (outcome?.status == SubagentStatus.failed && _retryOnParentModel(callId, outcome!)) return;
    if (outcome != null) return _finishChild(callId, outcome);
    final question = child.transcript.openQuestion;
    final asked = question != null && child.transcript.held.any((c) => c.id == question.call.id);
    if (asked && _forwarded.add(question.call.id)) _forwardQuestion(callId, question);
    // A question is the orchestrator's to answer; only approvals need the user.
    final waiting = child.status == SessionStatus.needsInput && !asked;
    if (waiting ? _childWaiting.add(callId) : _childWaiting.remove(callId)) {
      state = state.copyWith(subagentNeedsInput: _childWaiting.isNotEmpty);
    }
  }

  // ------------------------------------------------- Ultra research workflow

  final _researchSubs = <String, ProviderSubscription<CodeSessionState>>{};
  final _researchReports = <String, ({String title, SubagentReport report})>{};

  /// The research round (`PhaseFlow.run`) whose workflow is starting, and
  /// the last one whose reports went out: one workflow per round.
  String? _researchStarting;
  String? _researchSent;

  /// The research round the workers below belong to.
  String _researchRun = '';

  /// Workers planned but not started yet: at most [maxResearchAtOnce] run at
  /// once. (A restart drops this queue; the workflow then reports what ran.)
  final _researchQueue = <({String callId, SubagentTask task, String model})>[];

  /// Workers being started right now.
  int _researchLaunching = 0;

  /// Ends the round's workers that are still going after [researchTimeout].
  Timer? _researchTimer;

  /// This round's Ultra research workers (started earlier, maybe before a
  /// restart); an earlier round's (an earlier task's) are not.
  List<CodeSessionInfo> get _researchers => [
    for (final s in ref.read(codeSessionsProvider))
      if (s.parentId == sessionId && isResearchWorker(s.parentCallId, _researchRun)) s,
  ];

  /// An Ultra session at research: start its workflow once per round (the
  /// session's own model sizes it and picks the models), run at most
  /// [maxResearchAtOnce] workers at a time, and send their reports together
  /// when the last one is in, or when [researchTimeout] runs out.
  void _ultraResearch(Transcript t) {
    final p = t.phase;
    final workflow = p != null && (p.flow == 'ultra' || p.flow == 'bugfix-ultra');
    if (!workflow || p.phase != Phase.research || _researchStarting == p.run || _researchSent == p.run) return;
    if (_onOutsideLead) return;
    if (_researchRun != p.run) {
      // A new round: the last one's watchers, queue and reports are done with.
      for (final sub in _researchSubs.values) {
        sub.close();
      }
      _researchSubs.clear();
      _researchReports.clear();
      _researchQueue.clear();
      _researchTimer?.cancel();
      _researchTimer = null;
      _researchRun = p.run;
    }
    final sessions = ref.read(codeSessionsProvider.notifier);
    final info = sessions.byId(sessionId);
    if (info == null || info.isSubagent) return;
    final running = _researchers;
    if (running.isNotEmpty) {
      for (final r in running) {
        if (!_researchSubs.containsKey(r.parentCallId) && !_researchReports.containsKey(r.parentCallId)) {
          _watchResearcher(r.parentCallId, r.id, r.title);
        }
      }
      // After a restart the clock counts from the first worker's start.
      if (_researchTimer == null) {
        final first = running.map((r) => r.createdAt).reduce((a, b) => a.isBefore(b) ? a : b);
        _armResearchTimer(researchTimeout - DateTime.now().difference(first));
      }
      return;
    }
    final session = _session;
    if (session is! AsksAside) return;
    _researchStarting = p.run;
    final run = p.run;
    final bug = p.flow == 'bugfix-ultra';
    unawaited(() async {
      try {
        // The orchestrator picks how many researchers and each one's model, from the user's models.
        final library = (ref.read(libraryProvider).value ?? const <ModelSpec>[]).where((m) => m.tools).take(8);
        final models = {
          for (final m in library)
            if (m.id.value != info.model) m.id.value: researchModelLine(m),
        };
        String reply;
        try {
          reply = await (session as AsksAside).askAside(
            researchAnglesQuestion(models: models, bug: bug),
            maxTokens: 3000,
          );
        } on Object {
          // The general angles below rather than no research at all.
          reply = '';
        }
        if (!ref.mounted || _researchRun != run || _researchStarting != run || _onOutsideLead) return;
        final angles = parseResearchAngles(reply, bug: bug);
        _researchQueue
          ..clear()
          ..addAll([
            for (final (i, a) in angles.indexed)
              (
                callId: '$researchCallPrefix$run-${i + 1}',
                task: SubagentTask(description: a.title, prompt: a.question, agent: 'researcher'),
                // Only a model it was offered; anything else runs on the orchestrator's.
                model: models.containsKey(a.model) ? a.model : '',
              ),
          ]);
        _armResearchTimer(researchTimeout);
        await _startQueuedResearchers();
      } on Object catch (e) {
        if (ref.mounted) state = state.copyWith(error: "The research workflow couldn't start: $e");
      } finally {
        if (_researchStarting == run) _researchStarting = null;
      }
      // Some may have finished while the rest were starting.
      if (ref.mounted) _researchMaybeDone();
    }());
  }

  /// Starts queued workers while fewer than [maxResearchAtOnce] run.
  Future<void> _startQueuedResearchers() async {
    final sessions = ref.read(codeSessionsProvider.notifier);
    final run = _researchRun;
    while (ref.mounted && _researchRun == run && _researchQueue.isNotEmpty) {
      final busy = _researchers.where((r) => !_researchReports.containsKey(r.parentCallId)).length;
      if (busy + _researchLaunching >= maxResearchAtOnce) return;
      final info = sessions.byId(sessionId);
      // Queued angles are EveryAI's: they never start on an outside lead.
      if (info == null || isOutsideLead(info.harness, info.workingDir)) return;
      final next = _researchQueue.removeAt(0);
      _researchLaunching++;
      try {
        final child = await sessions.startTask(
          parent: info,
          task: next.task,
          callId: next.callId,
          mode: subagentMode(state.mode),
          model: next.model,
        );
        if (ref.mounted && _researchRun == run) _watchResearcher(next.callId, child.id, child.title);
      } on Object catch (e) {
        _researchReports[next.callId] = (
          title: next.task.title,
          report: SubagentReport(SubagentStatus.notStarted, "The researcher couldn't start: $e"),
        );
      } finally {
        _researchLaunching--;
      }
    }
  }

  void _armResearchTimer(Duration after) {
    _researchTimer?.cancel();
    final run = _researchRun;
    _researchTimer = Timer(after.isNegative ? Duration.zero : after, () {
      if (!ref.mounted || _researchRun != run || _researchSent == run) return;
      // Out of time: what finished goes out; the rest are stopped and say so.
      for (final r in _researchers) {
        if (_researchReports.containsKey(r.parentCallId)) continue;
        _researchSubs.remove(r.parentCallId)?.close();
        unawaited(ref.read(_liveProvider)[r.id]?.interrupt());
        _researchReports[r.parentCallId] = (
          title: r.title,
          report: SubagentReport(
            SubagentStatus.stopped,
            'Stopped: the research workflow ran out of time (${researchTimeout.inMinutes} minutes).',
          ),
        );
      }
      _researchQueue.clear();
      _researchStarting = null;
      _researchMaybeDone();
    });
  }

  void _watchResearcher(String callId, String childId, String title) {
    _researchSubs[callId] = ref.listen(codeSessionProvider(childId), (_, next) {
      final outcome = subagentOutcome(next.transcript, error: next.error);
      if (outcome == null || _researchReports.containsKey(callId)) return;
      _researchReports[callId] = (title: title, report: outcome);
      _researchSubs.remove(callId)?.close();
      unawaited(_startQueuedResearchers().then((_) => _researchMaybeDone()));
      _researchMaybeDone();
    }, fireImmediately: true);
  }

  void _researchMaybeDone() {
    if (!ref.mounted || _researchSent == _researchRun || _researchStarting != null || _onOutsideLead) return;
    if (_researchQueue.isNotEmpty || _researchLaunching > 0) return;
    final all = _researchers;
    final ids = {for (final r in all) r.parentCallId, ..._researchReports.keys};
    if (ids.isEmpty || ids.any((id) => !_researchReports.containsKey(id))) return;
    _researchSent = _researchRun;
    _researchTimer?.cancel();
    _researchTimer = null;
    final reports = [for (final id in ids) _researchReports[id]!];
    unawaited(_session?.send(researchWorkflowMessage(reports)).catchError((Object _) {}));
  }

  /// Each subagent call, for starting it again.
  final _calls = <String, ActionCall>{};

  /// Calls already moved to the orchestrator's model, and why.
  final _fellBack = <String, String>{};

  /// A role on a model the user picked failed: run it once more on this
  /// session's model and effort. False when that doesn't apply.
  bool _retryOnParentModel(String callId, SubagentReport failed) {
    final sessions = ref.read(codeSessionsProvider.notifier);
    final parent = sessions.byId(sessionId);
    final child = _childOf[callId] == null ? null : sessions.byId(_childOf[callId]!);
    final call = _calls[callId];
    if (parent == null || child == null || call == null || child.model == parent.model) return false;
    if (_fellBack.containsKey(callId)) return false;
    // Out of credits is the account, not the model: another model on credits
    // fails the same way. Only one billed to the user's own key can help.
    if (isOutOfCredits(failed.text) && !ModelBilling.current.ownKey(ModelId(parent.model))) return false;
    final name = ref.read(modelCatalogProvider)[ModelId(child.model)]?.name ?? child.model;
    final reason = failed.text.length > 200 ? '${failed.text.substring(0, 200)}…' : failed.text;
    _fellBack[callId] = '[$name failed ($reason), so it was started again on this session\'s model.]';
    _childSubs.remove(callId)?.close();
    _childOf.remove(callId);
    unawaited(_spawn(callId, call, parent, onParentModel: true));
    return true;
  }

  /// Calls whose fork is being merged back, so its report waits.
  final _merging = <String>{};

  /// A subagent ended with [report]. A fork in its own worktree is merged
  /// into this session's folder first (when it completed) and the report says
  /// what came over; a stopped or failed one is kept under a ref unmerged.
  void _finishChild(String callId, SubagentReport report) {
    final childId = _childOf[callId];
    final sessions = ref.read(codeSessionsProvider.notifier);
    final info = childId == null ? null : sessions.byId(childId);
    final copy = info?.forkCopy;
    if (info == null || copy == null) return _ready(callId, report);
    if (!_merging.add(callId)) return;
    unawaited(() async {
      var out = report;
      final merge = report.status == SubagentStatus.completed;
      try {
        final m = await _mergeOneAtATime(
          () => GitService.mergeFork(copy, slug: copy.root.split('/').last, merge: merge),
        );
        out = merge
            ? withMergeNote(report, m)
            : SubagentReport(
                report.status,
                '${report.text}\n\n[Not merged into your folder; its work is kept at ${m.ref}]',
              );
        if (ref.mounted) sessions.update(info.copyWith(merged: true));
      } on Object catch (e) {
        out = SubagentReport(report.status, "${report.text}\n\n[Its changes couldn't be merged back: $e]");
      } finally {
        _merging.remove(callId);
      }
      if (ref.mounted) _ready(callId, out);
    }());
  }

  /// Forks finishing together merge one after another into the same folder.
  static Future<void> _mergeChain = Future.value();
  static Future<T> _mergeOneAtATime<T>(Future<T> Function() run) {
    final result = _mergeChain.then((_) => run());
    _mergeChain = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  void _ready(String callId, SubagentReport report) {
    _calls.remove(callId);
    if (_fellBack.remove(callId) case final note?) report = SubagentReport(report.status, '$note\n\n${report.text}');
    if (_background.remove(callId) case final bg?) {
      _childOf.remove(callId);
      _childSubs.remove(callId)?.close();
      _childWaiting.remove(callId);
      state = state.copyWith(subagentNeedsInput: _childWaiting.isNotEmpty);
      // While the agent works this joins its next step; when idle it wakes it.
      unawaited(_session?.send(taskNotification(bg.childId, bg.title, report)).catchError((Object _) {}));
      return;
    }
    _reports[callId] = report;
    _childOf.remove(callId);
    _childSubs.remove(callId)?.close();
    _childWaiting.remove(callId);
    state = state.copyWith(subagentNeedsInput: _childWaiting.isNotEmpty);
    _deliver();
  }

  // ------------------------------------------------------ orchestrating forks

  /// Fork questions already passed to this agent, by call id.
  final _forwarded = <String>{};

  /// Orchestrator tool calls already answered.
  final _forkToolsDone = <String>{};

  /// A fork stopped to ask: this agent (its orchestrator) gets the questions
  /// and answers them with answer_fork, asking the user first if it must. A
  /// held fork call returns at once with the question, and its siblings move
  /// to the background, so the agent is free to act; their reports come as
  /// task notifications.
  void _forwardQuestion(String callId, QuestionItem item) {
    final sessions = ref.read(codeSessionsProvider.notifier);
    final childId = _childOf[callId];
    if (childId == null) return;
    final title = sessions.byId(childId)?.title ?? 'fork';
    final text = forkQuestionsText([
      for (final q in item.questions)
        (
          question: q.question,
          options: [for (final o in q.options) o.description.isEmpty ? o.label : '${o.label}: ${o.description}'],
          multi: q.multiSelect,
        ),
    ]);
    if (_background.containsKey(callId)) {
      unawaited(_session?.send(forkQuestionMessage(childId, title, text)).catchError((Object _) {}));
      return;
    }
    for (final MapEntry<String, String>(key: id, value: kid) in [..._childOf.entries]) {
      if (_background.containsKey(id) || _reports.containsKey(id)) continue;
      final t = sessions.byId(kid)?.title ?? 'fork';
      _background[id] = (childId: kid, title: t);
      _reports[id] = id == callId ? forkAsks(kid, t, text) : movedToBackground(kid);
    }
    _deliver();
  }

  /// Answers the orchestrator's check_forks / answer_fork / stop_fork calls.
  void _syncForkTools() {
    final session = _session;
    if (session == null || !_live) return;
    for (final call in state.transcript.held) {
      if (!forkTools.contains(call.toolName) || !_forkToolsDone.add(call.id)) continue;
      unawaited(() async {
        final String out;
        try {
          out = await _forkTool(call);
        } on Object catch (e) {
          await session.respond(accept: false, reason: 'Error: $e', callIds: [call.id]);
          return;
        }
        _markDecided([call.id], accept: false);
        await session.respond(accept: false, reason: out, callIds: [call.id]);
      }());
    }
  }

  /// This session's forks still at work (or waiting), by child id.
  Map<String, String> get _activeForks => {
    for (final MapEntry(key: callId, value: childId) in _childOf.entries) childId: callId,
  };

  Future<String> _forkTool(ActionCall call) async {
    final sessions = ref.read(codeSessionsProvider.notifier);
    final forkId = call.str('fork_id').trim();
    switch (call.toolName) {
      case checkForksTool:
        if (_activeForks.isEmpty) return 'No forks are running. Every fork you started has reported.';
        return [for (final id in _activeForks.keys) _forkStatus(id)].join('\n\n');
      case answerForkTool:
        if (!_activeForks.containsKey(forkId)) return _noSuchFork(forkId);
        final ok = await ref.read(codeSessionProvider(forkId).notifier).answerFromOrchestrator(call.str('answer'));
        return ok
            ? 'Sent. The fork carries on; its report arrives as a <task-notification>.'
            : 'That fork has no open question now (it may have been answered in its own view).';
      case stopForkTool:
        if (!_activeForks.containsKey(forkId)) return _noSuchFork(forkId);
        final title = sessions.byId(forkId)?.title ?? forkId;
        await ref.read(codeSessionProvider(forkId).notifier).stop();
        return 'Stopped "$title". What it did so far arrives as its report.';
    }
    return 'Error: unknown tool ${call.toolName}.';
  }

  static String _noSuchFork(String id) => 'Error: no running fork has id "$id". check_forks lists them.';

  /// One fork's state, for check_forks.
  String _forkStatus(String childId) {
    final info = ref.read(codeSessionsProvider.notifier).byId(childId);
    final live = ref.exists(codeSessionProvider(childId)) ? ref.read(codeSessionProvider(childId)) : null;
    final t = live?.transcript;
    final minutes = info == null ? 0 : DateTime.now().difference(info.createdAt).inMinutes;
    final spent = ref.exists(codeUsageProvider(childId))
        ? ref.read(codeUsageProvider(childId)).value?.spentMicros
        : null;
    final status = switch (live) {
      null => 'not loaded',
      _ when t?.openQuestion != null => 'waiting on your answer to its question',
      _ when t!.pending.isNotEmpty => 'waiting for the user to approve ${t.pending.length} action(s)',
      _ when t.retry != null => 'retrying a failed model call',
      _ when live.error != null => 'failed: ${live.error}',
      _ => live.status.name,
    };
    final steps = ref.exists(codeSessionProvider(childId))
        ? [
            for (final e in ref.read(codeSessionProvider(childId).notifier).mirrorEvents.whereType<ActionCall>())
              '${e.toolName} ${_gist(e)}'.trim(),
          ]
        : const <String>[];
    final last = steps.length > 4 ? steps.sublist(steps.length - 4) : steps;
    return '- ${info?.title ?? childId} (fork_id $childId): $status; ${minutes}m, ${steps.length} steps'
        '${spent == null ? '' : ', ${formatMicros(spent)}'}'
        '${last.isEmpty ? '' : '\n  latest: ${last.join(' · ')}'}';
  }

  static String _gist(ActionCall c) {
    final s = c.str('command').isNotEmpty
        ? c.str('command')
        : c.str('path').isNotEmpty
        ? c.str('path')
        : c.str('file_path');
    final one = s.split('\n').first;
    return one.length > 80 ? '${one.substring(0, 80)}…' : one;
  }

  /// The orchestrator answers this fork's open question.
  Future<bool> answerFromOrchestrator(String answer) async {
    final item = state.transcript.openQuestion;
    final session = _session;
    if (item == null || session == null || !_isHeld(item.call)) return false;
    _markDecided([item.call.id], accept: false);
    await session.respond(accept: false, reason: forkAnswerReason(answer), callIds: [item.call.id]);
    return true;
  }

  /// A subagent of this session was stopped by the user: the agent gets what
  /// it had said so far and carries on.
  void subagentStopped(String childId, SubagentReport report) {
    if (_reviewOf.containsKey(childId)) return _reviewDone(childId, report);
    final callId = _childOf.entries.where((e) => e.value == childId).firstOrNull?.key;
    if (callId != null) _finishChild(callId, report);
  }

  /// Gives the agent its subagents' reports once every subagent it waits on
  /// has one: as the held calls' result, else as one message when it's idle.
  void _deliver() {
    final session = _session;
    if (_reports.isEmpty || _delivering || session == null) return;
    final t = state.transcript;
    final open = [for (final s in t.openSubagents) s.step.call.id];
    // Calls closed some other way (a reply in chat) no longer want a report.
    _reports.removeWhere((id, _) => !open.contains(id));
    if (_reports.isEmpty || !open.every(_reports.containsKey)) return;
    final reports = {for (final id in open) id: _reports[id]!};
    final Future<void> sent;
    if (_holds) {
      if (!t.held.any((c) => reports.containsKey(c.id))) return;
      sent = _replyInCall(session, subagentReason(reports));
    } else {
      if (t.running || t.pending.isNotEmpty) return;
      sent = session.send(_noted(subagentMessage(reports)));
    }
    _delivering = true;
    unawaited(
      sent
          .then((_) => reports.keys.forEach(_reports.remove), onError: (Object _) {})
          .whenComplete(() => _delivering = false),
    );
  }

  /// Stops every subagent this session waits on. Held calls are answered by
  /// the caller; the cards of calls that ended the turn close here.
  Future<void> _stopSubagents() async {
    final open = [for (final s in state.transcript.openSubagents) s.step.call.id];
    if (open.isEmpty) return;
    final children = [..._childOf.values];
    _abandoned.addAll(_spawning);
    for (final s in _childSubs.values) {
      s.close();
    }
    _childSubs.clear();
    _childOf.clear();
    _reports.clear();
    _childWaiting.clear();
    state = state.copyWith(subagentNeedsInput: false);
    await Future.wait([for (final c in children) ref.read(codeSessionProvider(c).notifier).stop()]);
    if (!_holds) {
      _builder.settleSubagents(open, const SubagentReport(SubagentStatus.stopped, 'Stopped by the user.'));
      state = state.copyWith(transcript: _builder.snapshot);
    }
  }

  /// The rules "allow for this session" / "always allow" would store for
  /// the pending actions, or null when any of them can't be remembered
  /// (compound commands, dangerous actions).
  List<String>? rememberable([List<ActionCall>? calls]) {
    final pending = calls ?? state.transcript.pending;
    if (pending.isEmpty) return null;
    final dir = policy.workingDir;
    final patterns = [for (final c in pending) rememberPattern(c, workingDir: dir)];
    if (patterns.any((p) => p == null)) return null;
    return {for (final p in patterns) p!}.toList();
  }

  /// What "for this session" / "always" would store for each pending call
  /// that can be remembered (call id → rule), for the card's per-call menus.
  Map<String, String> rememberBy() {
    final dir = policy.workingDir;
    return {for (final c in state.transcript.pending) c.id: ?rememberPattern(c, workingDir: dir)};
  }

  /// Approves the pending actions ([callIds], or every one not answered
  /// yet); with [scope] session or always, also what [rememberable] gives,
  /// so the same commands run without asking.
  Future<void> approve([ApprovalScope scope = ApprovalScope.once, List<String>? callIds]) async {
    final pending = state.transcript.pending;
    final targets = [
      for (final c in pending)
        if (callIds == null ? !_decided.containsKey(c.id) : callIds.contains(c.id)) c,
    ];
    if (scope != ApprovalScope.once) {
      final patterns = rememberable(targets) ?? const <String>[];
      if (scope == ApprovalScope.session) {
        _sessionAllowed.addAll(patterns);
      } else {
        final projectId = ref.read(codeSessionsProvider.notifier).byId(sessionId)?.projectId;
        final store = ref.read(codePermissionsProvider.notifier);
        for (final p in patterns) {
          store.allow(p, projectId: projectId);
        }
      }
    }
    if (!perCall || callIds == null) _answered = pending.map((c) => c.id).join(',');
    if (perCall) _markDecided([for (final c in targets) c.id], accept: true);
    await _session?.respond(accept: true, callIds: perCall ? callIds : null);
    // A rule just remembered may settle other calls in the batch.
    if (perCall && callIds != null && scope != ApprovalScope.once) _autoRespond(state.transcript);
  }

  /// Refuses the pending actions ([callIds], or every one not answered yet,
  /// which parks the run if none was allowed); the agent reads the fixed
  /// denial text with [reason] word for word.
  Future<void> deny([String? reason, List<String>? callIds]) async {
    final pending = state.transcript.pending;
    if (!perCall || callIds == null) _answered = pending.map((c) => c.id).join(',');
    if (perCall) {
      _markDecided([
        for (final c in pending)
          if (callIds == null ? !_decided.containsKey(c.id) : callIds.contains(c.id)) c.id,
      ], accept: false);
    }
    await _session?.respond(
      accept: false,
      reason: denialMessage(DenialKind.denied, reason: reason),
      callIds: perCall ? callIds : null,
    );
  }

  /// Sends the card's answers: as the held call's result when the server is
  /// holding it, else as a new user message.
  Future<void> answer(QuestionItem item, List<QuestionAnswer> answers) async {
    if (_hostFor(item.call.id) case final wait?) {
      _answerHost(wait, answersReason(item.questions, answers));
      _builder.settleLocal(item.call.id, answers);
      state = state.copyWith(transcript: _builder.snapshot);
      return;
    }
    final session = _session;
    if (session == null) return;
    if (item.call.id.startsWith('doom-')) return _answerDoomLoop(item, answers);
    if (_isHeld(item.call)) {
      await _replyInCall(session, answersReason(item.questions, answers));
    } else {
      await session.send(_noted(answersMessage(item.questions, answers)));
    }
  }

  bool _isHeld(ActionCall call) => state.transcript.held.any((c) => c.id == call.id);

  /// Rejects the held call(s) with [reason], which the agent reads as the
  /// call's result, then runs it again (a rejection parks the conversation).
  Future<void> _replyInCall(HarnessSession session, String reason) async {
    _answered = [...state.transcript.pending, ...state.transcript.held].map((c) => c.id).join(',');
    await session.respond(accept: false, reason: reason);
    await session.resume();
  }

  Future<void> setMode(AgentMode mode) async {
    state = state.copyWith(mode: mode);
    final sessions = ref.read(codeSessionsProvider.notifier);
    if (sessions.byId(sessionId) case final info?) sessions.update(info.copyWith(mode: mode));
    await _session?.setMode(mode, holdClientTools: _holds);
    _answered = '';
    _autoRespond(state.transcript);
  }

  /// Approves the plan and tells the agent to go; Plan mode moves to Auto-edit.
  Future<void> startBuilding() async {
    final open = state.transcript.openPlan;
    final held = open?.call;
    final switching = state.mode == AgentMode.plan ? setMode(AgentMode.autoEdit) : Future<void>.value();
    // An outside agent's plan: the approval is its host call's result, and the plan is kept with the project.
    // It is answered without waiting for the mode switch: an agent blocked on the plan request (Cursor's
    // `cursor/create_plan`) may only take the switch once the plan is answered.
    final wait = open == null ? null : _hostFor(open.call.id);
    if (open != null && wait != null) {
      final dir = ref.read(codeSessionsProvider.notifier).byId(sessionId)?.workingDir;
      if (dir != null) hostSavePlan(dir, open.markdown);
      _answerHost(wait, planApprovedReason);
      _builder.settlePlan(open.call.id, PlanVerdict.approved);
      state = state.copyWith(transcript: _builder.snapshot);
      await switching;
      return;
    }
    await switching;
    final session = _session;
    if (session != null && held != null && _isHeld(held)) {
      await _replyInCall(session, planApprovedReason);
    } else {
      await send(planApprovedMessage);
    }
  }
}

/// What the agent server reports for sessions whose view isn't open (they
/// have no live controller), refreshed every 10 s while a list shows them.
final codeStatusesProvider = NotifierProvider.autoDispose<CodeStatuses, Map<String, SessionStatus>>(CodeStatuses.new);

final class CodeStatuses extends Notifier<Map<String, SessionStatus>> {
  Timer? _timer;

  @override
  Map<String, SessionStatus> build() {
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => unawaited(_refresh()));
    ref.onDispose(() => _timer?.cancel());
    unawaited(Future.microtask(_refresh));
    return const {};
  }

  Future<void> _refresh() async {
    final sessions = [
      for (final s in ref.read(codeSessionsProvider))
        if (!isDemoPath(s.workingDir)) s,
    ];
    if (sessions.isEmpty) return;
    try {
      final byConversation = await _driverStatuses(ref, sessions);
      if (!ref.mounted) return;
      final before = state;
      state = {
        for (final s in sessions)
          if (byConversation[s.conversationId] case final status?) s.id: _sessionStatus(status),
      };
      // Sessions whose view is closed still tell the user when they need them.
      for (final s in sessions) {
        final now = state[s.id];
        if (now != null && !ref.exists(codeSessionProvider(s.id))) notifyStatusChange(ref, before[s.id], now, s.title);
      }
    } on Object {
      // The server isn't up yet; try again on the next tick.
    }
  }

  static SessionStatus _sessionStatus(ExecutionStatus s) => switch (s) {
    ExecutionStatus.running => SessionStatus.running,
    ExecutionStatus.waitingForConfirmation => SessionStatus.needsInput,
    ExecutionStatus.finished => SessionStatus.done,
    ExecutionStatus.error || ExecutionStatus.stuck => SessionStatus.failed,
    _ => SessionStatus.idle,
  };
}

/// What each of [sessions]' harnesses reports for them, by conversation id
/// (sessions on a harness the app no longer has are left out).
Future<Map<String, ExecutionStatus>> _driverStatuses(Ref ref, List<CodeSessionInfo> sessions) async {
  final registry = ref.read(driverRegistryProvider);
  final byHarness = <String, List<String>>{};
  for (final s in sessions) {
    if (!s.removedHarness) (byHarness[s.harness] ??= []).add(s.conversationId);
  }
  final out = <String, ExecutionStatus>{};
  for (final MapEntry(key: harness, value: ids) in byHarness.entries) {
    if (registry.resolve(harness) case final driver?) out.addAll(await driver.statuses(ids));
  }
  return out;
}

/// What every session is doing now, by session id: the live state of open
/// sessions, else what the agent server reports (missing when it can't be reached).
Future<Map<String, SessionStatus>> sessionStatusesNow(Ref ref, List<CodeSessionInfo> sessions) async {
  final out = <String, SessionStatus>{};
  final ask = <CodeSessionInfo>[];
  for (final s in sessions) {
    if (ref.exists(codeSessionProvider(s.id))) {
      out[s.id] = ref.read(codeSessionProvider(s.id)).status;
    } else if (!isDemoPath(s.workingDir)) {
      ask.add(s);
    }
  }
  if (ask.isEmpty) return out;
  try {
    final byConversation = await _driverStatuses(ref, ask);
    for (final s in ask) {
      if (byConversation[s.conversationId] case final status?) out[s.id] = CodeStatuses._sessionStatus(status);
    }
  } on Object {
    // The agent server isn't up: those sessions go without a status.
  }
  return out;
}

/// What [owner]'s budget has spent: its own ledger (subagents bill there
/// too) plus children billed under their own ids (Ultra steps and the
/// orchestrator), as far as [usage] has read them.
/// Whether a session runs under the own-key Ultra cap: the Ultra tier on a
/// model billed to one of the user's keys.
/// The model that reviews a Bug fix step the harness refused: one of the
/// user's models from another vendor than [model] (a featured one first),
/// so the session's model doesn't mark its own work; null when there is
/// none (the session's own model then reviews, with a fresh context).
String? bugReviewModel(String model, Iterable<ModelSpec> library) {
  String vendor(String id) => id.split('/').first;
  final others = [
    for (final m in library)
      if (m.tools && !m.free && m.id.value != 'everyai/auto' && vendor(m.id.value) != vendor(model)) m,
  ];
  return (others.where((m) => m.featured).firstOrNull ?? others.firstOrNull)?.id.value;
}

/// How the orchestrator sees a model it may give a researcher: its name and
/// price, so it can weigh cost against depth.
String researchModelLine(ModelSpec m) {
  String usd(double v) => v >= 10 ? v.toStringAsFixed(0) : v.toStringAsFixed(2);
  final price = m.free
      ? 'free'
      : (m.promptPrice != null && m.completionPrice != null)
      ? '\$${usd(m.promptPrice!)} in / \$${usd(m.completionPrice!)} out per million tokens'
      : 'price unknown';
  return '${m.name}, $price';
}

bool byokUltraCapped(HarnessTier tier, ModelId model, ModelBilling billing) =>
    tier == HarnessTier.ultra && billing.ownKey(model);

int budgetSpentMicros(
  String owner, {
  required List<CodeSessionInfo> sessions,
  required int? Function(String id) usage,
}) {
  var n = usage(owner) ?? 0;
  for (final s in sessions) {
    if (s.parentId == owner && s.ownTag) n += usage(s.id) ?? 0;
  }
  return n;
}

/// Whether Stop on [info] ends the background processes tagged with its id:
/// a top-level session, or a child with its own tag (an Ultra step). Other
/// subagents carry their parent's tag, so the parent's Stop ends theirs.
bool killsOwnProcesses(CodeSessionInfo info) => !noLocalFolder(info.workingDir) && (!info.isSubagent || info.ownTag);

/// Whether no other session works in [info]'s folder: a session worktree, or
/// an Ultra step's own worktree (a folder other than its [parent]'s).
bool ownsWorkingDir(CodeSessionInfo info, {CodeSessionInfo? parent}) =>
    info.worktree != null || (info.ownTag && parent != null && parent.workingDir != info.workingDir);

/// Tools that can change the worktree (file edits, shell commands).
bool editsFiles(String toolName) =>
    const {'file_editor', 'terminal', 'str_replace_editor', 'apply_patch'}.contains(toolName);

/// Prefs key prefix of what outside drivers reported per session (see [CodeUsage]).
const codeUsageReportsPrefix = 'code.usage_reports.';

/// Tokens and spend of a Code session, from the backend's ledger (the gateway
/// attributes every model call to the session). Demo sessions have none.
final codeUsageProvider = AsyncNotifierProvider.family<CodeUsage, UsageTotals, String>(CodeUsage.new);

final class CodeUsage extends AsyncNotifier<UsageTotals> {
  CodeUsage(this.sessionId);
  final String sessionId;
  Timer? _debounce;

  /// The backend's reading, and what an outside driver reported itself
  /// (by event id, so history replayed again isn't counted twice). The
  /// reported part is kept in prefs: no ledger has it, and a compaction into
  /// a fresh conversation never replays the old one's reports.
  UsageTotals _backend = UsageTotals.zero;
  UsageTotals _reported = UsageTotals.zero;
  final _reportIds = <String>{};

  /// [_reported] split by the harness that reported it (a session that
  /// changed leads shows one row each).
  final _byHarness = <String, UsageTotals>{};

  /// The lead changed and hasn't reported since: the context ring is empty.
  bool _freshLead = false;

  /// What each harness used: the drivers' own reports, plus the backend's
  /// ledger (calls on EveryAI credits or the user's keys) under
  /// [everyaiHarnessName].
  Map<String, UsageTotals> get byHarness => {
    if (!_backend.isEmpty) everyaiHarnessName: _backend,
    for (final MapEntry(:key, :value) in _byHarness.entries)
      key: key == everyaiHarnessName && !_backend.isEmpty ? _backend + value : value,
  };

  UsageTotals get _total => _freshLead ? (_backend + _reported).withContext(0) : _backend + _reported;

  String get _reportsKey => '$codeUsageReportsPrefix$sessionId';

  @override
  Future<UsageTotals> build() async {
    ref.onDispose(() {
      _debounce?.cancel();
      _later?.cancel();
    });
    _loadReports();
    _backend = await _fetch();
    return _total;
  }

  void _loadReports() {
    final raw = ref.read(preferencesProvider)[_reportsKey];
    if (raw == null) return;
    try {
      final j = jsonDecode(raw) as Map<String, Object?>;
      _reported = UsageTotals.fromJson(j['totals'] as Map<String, Object?>? ?? const {});
      _reportIds.addAll([...?(j['ids'] as List<Object?>?)?.whereType<String>()]);
      if (j['by_harness'] case final Map<String, Object?> by) {
        for (final MapEntry(:key, :value) in by.entries) {
          if (value case final Map<String, Object?> t) _byHarness[key] = UsageTotals.fromJson(t);
        }
      }
    } on Object {
      // A broken entry counts as none.
    }
  }

  /// Adds what a driver says a model call (or turn) used. A cost on the
  /// user's plan shows apart; one on their own key counts toward the budget.
  /// The context ring moves only when the report says how full the window is.
  void report(UsageReport r) {
    if (r.id.isNotEmpty && !_reportIds.add(r.id)) return;
    final cost = r.costMicros ?? 0;
    UsageTotals add(UsageTotals to) => to.addCall(
      prompt: r.input,
      completion: r.output,
      cached: r.cached,
      ownKey: r.onPlan ? 0 : cost,
      plan: r.onPlan ? cost : 0,
      onPlan: r.onPlan,
      context: false,
    );
    var next = add(_reported);
    if (r.contextTokens case final c?) {
      next = next.withContext(c);
      _freshLead = false;
    }
    _reported = next;
    final harness = ref.read(codeSessionsProvider.notifier).byId(sessionId)?.harness ?? everyaiHarnessName;
    _byHarness[harness] = add(_byHarness[harness] ?? UsageTotals.zero);
    ref.read(preferencesProvider)[_reportsKey] = jsonEncode({
      'totals': _reported.toJson(),
      'ids': [..._reportIds],
      'by_harness': {for (final MapEntry(:key, :value) in _byHarness.entries) key: value.toJson()},
    });
    state = AsyncData(_total);
  }

  /// The session moved to another lead: its context starts empty, so the
  /// ring shows nothing until the new lead's first reading.
  void leadChanged() {
    _freshLead = true;
    if (state.hasValue) state = AsyncData(_total);
  }

  Future<UsageTotals> _fetch() async {
    final info = ref.read(codeSessionsProvider.notifier).byId(sessionId);
    if (info == null || isDemoPath(info.workingDir)) return UsageTotals.zero;
    final json = await ref
        .read(apiClientProvider)
        .getJson('v1/usage/session/$sessionId', authenticated: !ref.read(appConfigProvider).devSkipAuth);
    return UsageTotals.fromJson(json);
  }

  Timer? _later;

  /// Refetches within [delay]. Calls while one is waiting join it (a steady
  /// stream of events must not push the reading back forever); [force] queues
  /// an extra, later read.
  void refreshSoon({Duration delay = const Duration(seconds: 1), bool force = false}) {
    if (force) {
      _later?.cancel();
      _later = Timer(delay, _read);
      return;
    }
    if (_debounce?.isActive ?? false) return;
    _debounce = Timer(delay, _read);
  }

  Future<void> _read() async {
    if (!ref.mounted) return;
    final next = await AsyncValue.guard(_fetch);
    // Keep the last reading if the server can't be reached.
    if (!ref.mounted || !next.hasValue) return;
    // A new call on the ledger is the new lead's (EveryAI) first reading.
    if (next.requireValue.calls != _backend.calls) _freshLead = false;
    _backend = next.requireValue;
    state = AsyncData(_total);
  }
}

/// A session's changes since its base commit, for the header and Diff pane.
@immutable
final class GitSnapshot {
  const GitSnapshot({this.files = const [], this.ahead = 0, this.behind = 0});

  final List<FileDiff> files;

  /// Commits on the session branch / on the base branch since it forked.
  final int ahead;
  final int behind;

  int get added => files.fold(0, (n, f) => n + f.hunks.fold(0, (m, h) => m + h.added));
  int get removed => files.fold(0, (n, f) => n + f.hunks.fold(0, (m, h) => m + h.removed));
}

final codeGitProvider = AsyncNotifierProvider.family<CodeGit, GitSnapshot, String>(CodeGit.new);

/// The session's worktree: its diff, and what the user can do with it.
final class CodeGit extends AsyncNotifier<GitSnapshot> {
  CodeGit(this.sessionId);
  final String sessionId;

  CodeSessionInfo? get _info => ref.read(codeSessionsProvider.notifier).byId(sessionId);
  SessionWorktree get _w => _info?.worktree ?? (throw const GitError('This session has no git worktree.'));

  @override
  Future<GitSnapshot> build() => _load();

  Future<GitSnapshot> _load() async {
    final info = _info;
    if (info?.worktree case final w?) {
      final (files, counts) = await (GitService.diff(w), GitService.aheadBehind(w)).wait;
      return GitSnapshot(files: files, ahead: counts.ahead, behind: counts.behind);
    }
    // In place: what changed since the session's snapshot of the checkout.
    if (info?.baseline case final b?) return GitSnapshot(files: await GitService.diff(b.diffView));
    return const GitSnapshot();
  }

  Future<void> refresh() async {
    final next = await AsyncValue.guard(_load);
    if (ref.mounted) state = next;
  }

  Future<void> revertHunk(FileDiff file, int hunk) async {
    final target = _info?.diffTarget ?? (throw const GitError('This session has no git history.'));
    await GitService.revertHunk(target, file, hunk);
    await refresh();
  }

  /// Commits everything on the session branch; false when nothing changed.
  Future<bool> commit(String message) async {
    final done = await GitService.commitAll(_w, message);
    await refresh();
    return done;
  }

  /// Squashes the session onto its base branch in the main checkout.
  Future<String> squashMerge(String message) async {
    final sha = await GitService.squashMerge(_w, message);
    await refresh();
    return sha;
  }

  Future<void> push() => GitService.push(_w);

  Future<String> createPr({required String title, required String body}) async {
    await GitService.push(_w);
    return GitService.createPr(_w, title: title, body: body);
  }

  /// Puts the files back to how they were before user turn [turn] (1-based).
  Future<void> rewind(int turn) async {
    final w = _w;
    await GitService.restoreCheckpoint(w, turn <= 1 ? w.baseCommit : checkpointRef(w, turn));
    await refresh();
  }

  /// Removes the session, its worktree, branch and checkpoints.
  Future<void> discard() async {
    final w = _w;
    final data = await GitService.dataDir();
    await ref.read(codeSessionsProvider.notifier).remove(sessionId);
    await GitService.removeWorktree(w, hooksDir: '$data/git-hooks');
  }
}

String checkpointRef(SessionWorktree w, int turn) => 'refs/everyai/${w.slug}/turn-$turn';
