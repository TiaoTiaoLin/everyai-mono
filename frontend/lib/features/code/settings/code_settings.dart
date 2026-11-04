import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../skills/domain/skill_catalog.dart' show SkillSettings;
import '../domain/agent_mode.dart';
import '../domain/mcp_servers.dart';
import '../domain/permissions.dart';
import '../harness/everyai/research_sites.dart' show defaultResearchSites;
import 'agent_prompt.dart' show HarnessTier;
import 'script_caps.dart' show ScriptLevel;

export 'agent_prompt.dart' show HarnessTier;
import '../permissions_providers.dart' show StoredPermissions;

/// Where a Code setting lives. Later layers win: global, then the project,
/// then the session.
enum SettingsScope {
  global('Global', 'Every project'),
  project('Project', 'This project'),
  session('Session', 'This session only');

  const SettingsScope(this.label, this.blurb);
  final String label;
  final String blurb;

  static SettingsScope parse(Object? v) => values.where((s) => s.name == v).firstOrNull ?? global;
}

/// The settings the app keeps that no other store holds (Preferences
/// `code.settings`): the overarching system prompts and per-session
/// budgets.
///
/// ```json
/// {"global": {"systemPrompt": "Answer in British English."},
///  "projects": {"<project id>": {"systemPrompt": "Use pnpm, never npm."}},
///  "sessions": {"<session id>": {"budgetUsd": 5}}}
/// ```
@immutable
final class StoredCodeSettings {
  const StoredCodeSettings({
    this.globalPrompt = '',
    this.projectPrompts = const {},
    this.budgets = const {},
    this.autoCompactPercent = defaultAutoCompactPercent,
    this.tier = HarnessTier.efficient,
    this.forksIsolated = true,
    this.researchSites = defaultResearchSites,
    this.scripts = ScriptLevel.byTier,
    this.ownClis = const {},
  });

  /// "Use my own installed CLIs": the drivers (by id) that need the user's
  /// consent and have it. Global and kept in the app only, so no project file
  /// can turn one on. Empty (the default): none.
  final Set<String> ownClis;

  /// run_script for sessions started from now on: by tier, or one level.
  final ScriptLevel scripts;

  /// The only sites research jobs (researcher subagents) may fetch from.
  final List<String> researchSites;

  /// Efficiency ↔ Quality, for sessions started from now on.
  /// The tier new sessions start on.
  final HarnessTier tier;

  /// Writing forks work in a worktree of their own and merge back into the
  /// parent's folder when they finish (false: they share the parent's folder).
  final bool forksIsolated;

  /// Where most models still work well with a long history.
  static const defaultAutoCompactPercent = 60;

  final String globalPrompt;

  /// The share of the context window at which EveryAI-harness sessions
  /// compact their history (0: never on their own).
  final int autoCompactPercent;
  final Map<String, String> projectPrompts;

  /// Session id → spending cap in dollars.
  final Map<String, double> budgets;

  String promptFor(String? projectId) => projectId == null ? globalPrompt : projectPrompts[projectId] ?? '';

  StoredCodeSettings withPrompt(String? projectId, String prompt) {
    final p = prompt.trim();
    if (projectId == null) return _copy(globalPrompt: p);
    final next = {...projectPrompts}..remove(projectId);
    if (p.isNotEmpty) next[projectId] = p;
    return _copy(projectPrompts: next);
  }

  StoredCodeSettings withAutoCompact(int percent) => _copy(autoCompactPercent: percent.clamp(0, 95));

  StoredCodeSettings withTier(HarnessTier tier) => _copy(tier: tier);

  StoredCodeSettings withForksIsolated(bool on) => _copy(forksIsolated: on);

  StoredCodeSettings withScripts(ScriptLevel level) => _copy(scripts: level);

  StoredCodeSettings withOwnCli(String driverId, bool on) =>
      _copy(ownClis: on ? {...ownClis, driverId} : ({...ownClis}..remove(driverId)));

  /// [sites] cleaned up (no schemes or paths, lower case); empty restores the defaults.
  StoredCodeSettings withResearchSites(List<String> sites) {
    final clean = [
      for (final s in sites)
        if (s.trim().toLowerCase().replaceFirst(RegExp(r'^[a-z]+://'), '').split('/').first case final h
            when h.isNotEmpty)
          h,
    ];
    return _copy(researchSites: clean.isEmpty ? defaultResearchSites : clean.toSet().toList());
  }

  StoredCodeSettings _copy({
    String? globalPrompt,
    Map<String, String>? projectPrompts,
    Map<String, double>? budgets,
    int? autoCompactPercent,
    HarnessTier? tier,
    bool? forksIsolated,
    List<String>? researchSites,
    ScriptLevel? scripts,
    Set<String>? ownClis,
  }) => StoredCodeSettings(
    ownClis: ownClis ?? this.ownClis,
    scripts: scripts ?? this.scripts,
    researchSites: researchSites ?? this.researchSites,
    tier: tier ?? this.tier,
    forksIsolated: forksIsolated ?? this.forksIsolated,
    globalPrompt: globalPrompt ?? this.globalPrompt,
    projectPrompts: projectPrompts ?? this.projectPrompts,
    budgets: budgets ?? this.budgets,
    autoCompactPercent: autoCompactPercent ?? this.autoCompactPercent,
  );

  StoredCodeSettings withBudget(String sessionId, double? usd) {
    final next = {...budgets}..remove(sessionId);
    if (usd != null && usd > 0) next[sessionId] = usd;
    return _copy(budgets: next);
  }

  factory StoredCodeSettings.fromJson(Object? json) {
    if (json is! Map<String, Object?>) return const StoredCodeSettings();
    String prompt(Object? v) =>
        v is Map<String, Object?> && v['systemPrompt'] is String ? v['systemPrompt']! as String : '';
    final projects = json['projects'];
    final sessions = json['sessions'];
    final global = json['global'];
    return StoredCodeSettings(
      tier: switch (global) {
        {'harnessTier': final Object t} => HarnessTier.parse(t),
        {'workStyle': final Object w} => HarnessTier.fromWorkStyle(w),
        _ => HarnessTier.efficient,
      },
      forksIsolated: !(global is Map<String, Object?> && global['forksIsolated'] == false),
      scripts: ScriptLevel.parse(global is Map<String, Object?> ? global['scripts'] : null),
      ownClis: switch (global) {
        {'ownClis': final List<Object?> ids} => {...ids.whereType<String>()},
        _ => const {},
      },
      researchSites: switch (global) {
        {'researchSites': final List<Object?> sites} when sites.isNotEmpty => [...sites.whereType<String>()],
        _ => defaultResearchSites,
      },
      autoCompactPercent: global is Map<String, Object?> && global['autoCompactPercent'] is num
          ? (global['autoCompactPercent']! as num).toInt()
          : defaultAutoCompactPercent,
      globalPrompt: prompt(json['global']),
      projectPrompts: {
        if (projects is Map<String, Object?>)
          for (final e in projects.entries)
            if (prompt(e.value) case final p when p.isNotEmpty) e.key: p,
      },
      budgets: {
        if (sessions is Map<String, Object?>)
          for (final e in sessions.entries)
            if (e.value case {'budgetUsd': final num usd} when usd > 0) e.key: usd.toDouble(),
      },
    );
  }

  Map<String, Object?> toJson() => {
    'global': {
      if (globalPrompt.isNotEmpty) 'systemPrompt': globalPrompt,
      if (autoCompactPercent != defaultAutoCompactPercent) 'autoCompactPercent': autoCompactPercent,
      if (tier != HarnessTier.efficient) 'harnessTier': tier.name,
      if (!forksIsolated) 'forksIsolated': false,
      if (scripts != ScriptLevel.byTier) 'scripts': scripts.name,
      if (ownClis.isNotEmpty) 'ownClis': [...ownClis]..sort(),
      if (!listEquals(researchSites, defaultResearchSites)) 'researchSites': researchSites,
    },
    'projects': {
      for (final e in projectPrompts.entries) e.key: {'systemPrompt': e.value},
    },
    'sessions': {
      for (final e in budgets.entries) e.key: {'budgetUsd': e.value},
    },
  };
}

/// What a session's settings layer holds. Model, effort and mode stay in the
/// session itself; the budget in [StoredCodeSettings].
typedef SessionLayer = ({String model, String effort, AgentMode mode, double? budgetUsd});

/// Everything the layered settings read from, as it is now.
@immutable
final class CodeSettingsSources {
  const CodeSettingsSources({
    this.settings = const StoredCodeSettings(),
    this.permissions = const StoredPermissions(),
    this.mcp = const StoredMcpServers(),
    this.skills = const SkillSettings(),
    this.session,
  });

  final StoredCodeSettings settings;
  final StoredPermissions permissions;
  final StoredMcpServers mcp;
  final SkillSettings skills;
  final SessionLayer? session;
}

/// One layer of the settings kept in the app, as "View as JSON" shows it.
///
/// - global: `systemPrompt`, `permissions {allow, deny}`, `mcpServers [...]`,
///   `skills {disabled: [skill keys]}`
/// - project: `systemPrompt`, `permissions`, `mcpServers`
/// - session: `model`, `effort`, `mode`, `budgetUsd`
///
/// MCP approvals and skill trust are left out: they are given in their own
/// screens, after the user has seen what they approve.
Map<String, Object?> layerJson(SettingsScope scope, CodeSettingsSources s, {String? projectId}) {
  List<Object?> servers(String? id) => [
    for (final m in s.mcp.listFor(id)) {...m.toJson()}..remove('approved'),
  ];
  return switch (scope) {
    SettingsScope.global => {
      'systemPrompt': s.settings.globalPrompt,
      'permissions': s.permissions.global.toJson(),
      'mcpServers': servers(null),
      'skills': {
        'disabled': [...s.skills.disabled]..sort(),
      },
    },
    SettingsScope.project => {
      'systemPrompt': s.settings.promptFor(projectId),
      'permissions': (s.permissions.projects[projectId] ?? PermissionRules.none).toJson(),
      'mcpServers': servers(projectId),
    },
    SettingsScope.session => {
      if (s.session case final session?) ...{
        'model': session.model,
        'effort': session.effort,
        'mode': session.mode.name,
        'budgetUsd': session.budgetUsd,
      },
    },
  };
}

/// The settings a session in [projectId] runs with, every layer merged:
/// prompts join (global first), permission rules add up, a project MCP server
/// replaces a global one of the same name, the session's own values last.
Map<String, Object?> effectiveJson(CodeSettingsSources s, {String? projectId}) => {
  'systemPrompt': joinSystemPrompts(
    global: s.settings.globalPrompt,
    project: projectId == null ? '' : s.settings.promptFor(projectId),
  ),
  'permissions': s.permissions.rulesFor(projectId).toJson(),
  'mcpServers': [
    for (final m in s.mcp.serversFor(projectId)) {...m.toJson()..remove('approved'), 'active': m.active},
  ],
  'skills': {
    'disabled': [...s.skills.disabled]..sort(),
  },
  ...layerJson(SettingsScope.session, s),
};

/// [json] indented for reading.
String prettyJson(Object? json) => const JsonEncoder.withIndent('  ').convert(json);

/// The user's standing instructions (global, then for the project), as a
/// block for the end of the agent's system prompt; '' when there are none.
String joinSystemPrompts({required String global, required String project}) =>
    [global.trim(), project.trim()].where((p) => p.isNotEmpty).join('\n\n');

/// [suffix] with the user's system prompts appended. They go last and stay
/// fixed for the session, so the cached prompt prefix still holds.
String withSystemPrompts(String suffix, {required String global, required String project}) {
  final g = global.trim();
  final p = project.trim();
  if (g.isEmpty && p.isEmpty) return suffix;
  final out = StringBuffer(suffix)
    ..write('\n\n<USER_SYSTEM_PROMPT>\n')
    ..write('The user wrote these standing instructions in EveryAI settings. Follow them in every turn; ')
    ..write('a later message from the user overrides them where the two disagree.\n');
  if (g.isNotEmpty) out.write('\n$g\n');
  if (p.isNotEmpty) out.write('\nFor this project:\n$p\n');
  out.write('</USER_SYSTEM_PROMPT>');
  return out.toString();
}

/// How much of [budgetUsd] the session has spent ([chargedMicros] is in
/// millionths of a dollar); null without a budget.
double? budgetFill(int chargedMicros, double? budgetUsd) =>
    budgetUsd == null || budgetUsd <= 0 ? null : chargedMicros / (budgetUsd * 1e6);

/// Whether spending went from under [budgetUsd] to at or over it between
/// [beforeMicros] and [afterMicros]: the moment the session is stopped.
bool crossedBudget(int beforeMicros, int afterMicros, double? budgetUsd) {
  if (budgetUsd == null || budgetUsd <= 0) return false;
  final cap = budgetUsd * 1e6;
  return beforeMicros < cap && afterMicros >= cap;
}

/// The budget picks the top bar offers, in dollars.
const budgetPresets = [1.0, 2.0, 5.0, 10.0, 25.0];
