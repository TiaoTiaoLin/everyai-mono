import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../code/domain/agent_mode.dart';
import '../../skills/domain/skill_format.dart' show parseFrontMatter;

/// Where an agent file was found.
enum AgentSource {
  /// Bundled with the app (`assets/agents/`); read-only, "Customize" copies it.
  builtin('Built-in'),

  /// App support `agents/`: the user's own, for every project.
  global('Global'),

  /// `<project>/.everyai/agents`: came with the repository, so it stays off
  /// until the user trusts it.
  project('Project');

  const AgentSource(this.label);
  final String label;
}

/// The OpenHands tools an agent may be limited to; `mcp` stands for the MCP
/// servers set up in Settings.
const agentToolNames = ['terminal', 'file_editor', 'task_tracker', 'mcp'];

const agentEfforts = ['low', 'medium', 'high', 'xhigh', 'max'];

/// The project's agent folder, and the file name rule (also the agent's id).
const projectAgentsDir = '.everyai/agents';
final agentNamePattern = RegExp(r'^[a-z0-9][a-z0-9_-]{0,47}$');
final _modelPattern = RegExp(r'^[a-z0-9._~-]+/[A-Za-z0-9._:~-]+$');

/// Agent files past this are skipped.
const maxAgentFileBytes = 64 * 1024;

/// A subagent definition: `.everyai/agents/<name>.md`.
///
/// ```
/// ---
/// name: reviewer
/// description: Reviews a diff for bugs and risky changes; read-only.
/// model: anthropic/claude-sonnet-5.5
/// effort: high
/// tools: terminal, file_editor
/// permissions: plan
/// ---
/// You review code changes...
/// ```
///
/// `model` and `effort` default to the calling session's (`inherit` says so
/// explicitly); `tools` defaults to all; `permissions` (or `mode`) is one of
/// ask, auto-edit, plan, full-auto and can only make a subagent more careful
/// than the session that starts it (see [childSetup]).
@immutable
final class AgentDefinition {
  const AgentDefinition({
    required this.name,
    required this.source,
    required this.digest,
    this.description = '',
    this.prompt = '',
    this.model,
    this.effort,
    this.tools,
    this.mode,
    this.path,
    this.projectId,
    this.text = '',
    this.errors = const [],
    this.warnings = const [],
  });

  final String name;
  final String description;

  /// The body: the agent's instructions.
  final String prompt;

  /// A gateway model id; null uses the caller's.
  final String? model;
  final String? effort;

  /// The tools it keeps, from [agentToolNames]; null keeps all.
  final List<String>? tools;
  final AgentMode? mode;

  final AgentSource source;

  /// The file; null for a built-in.
  final String? path;

  /// For [AgentSource.project].
  final String? projectId;

  /// The file as read.
  final String text;

  /// SHA-256 of [text]; a project agent's trust is bound to it.
  final String digest;
  final List<String> errors;
  final List<String> warnings;

  bool get usable => errors.isEmpty;

  /// Stable id for settings: `builtin:name`, `global:name`, `project:<id>:name`.
  String get key => source == AgentSource.project ? 'project:$projectId:$name' : '${source.name}:$name';

  /// Parses an agent file named [fileName] (`reviewer.md`). Problems that
  /// make it unusable go to [errors]; it never throws.
  static AgentDefinition parse(
    String text, {
    required String fileName,
    required AgentSource source,
    String? path,
    String? projectId,
  }) {
    final digest = sha256.convert(utf8.encode(text)).toString();
    final stem = fileName.replaceFirst(RegExp(r'\.md$'), '');
    final errors = <String>[];
    final warnings = <String>[];
    AgentDefinition broken(String why) => AgentDefinition(
      name: stem,
      source: source,
      digest: digest,
      path: path,
      projectId: projectId,
      text: text,
      errors: [why],
    );

    if (utf8.encode(text).length > maxAgentFileBytes) return broken('The file is larger than 64 KB.');
    final Map<String, Object> fields;
    final String body;
    try {
      (:fields, :body) = parseFrontMatter(text);
    } on FormatException catch (e) {
      return broken(e.message.replaceFirst('SKILL.md', 'An agent file'));
    }
    String? str(String key) => switch (fields[key]) {
      final String s when s.trim().isNotEmpty => s.trim(),
      _ => null,
    };

    var name = str('name') ?? stem;
    if (!agentNamePattern.hasMatch(name)) {
      if (agentNamePattern.hasMatch(stem)) {
        warnings.add('The name "$name" is not valid; using "$stem" from the file name.');
        name = stem;
      } else {
        errors.add('Use lowercase letters, digits, - and _ for the name (up to 48 characters).');
      }
    }
    final description = str('description') ?? '';
    if (description.isEmpty) errors.add('Add a description: it is how the agent is picked for a task.');

    var model = str('model');
    if (model == 'inherit') model = null;
    if (model != null && !_modelPattern.hasMatch(model)) {
      errors.add('The model "$model" is not a model id such as anthropic/claude-sonnet-5.5.');
    }
    var effort = str('effort')?.toLowerCase();
    if (effort == 'inherit') effort = null;
    if (effort != null && !agentEfforts.contains(effort)) {
      errors.add('The effort "$effort" is not one of ${agentEfforts.join(', ')}.');
    }

    List<String>? tools;
    if (str('tools') case final raw?) {
      final names = raw
          .replaceAll(RegExp(r'[\[\]]'), ' ')
          .split(RegExp(r'[\s,]+'))
          .where((s) => s.isNotEmpty && s != '*' && s != 'all');
      final unknown = names.where((n) => !agentToolNames.contains(n)).toList();
      if (unknown.isNotEmpty) errors.add('Unknown tools: ${unknown.join(', ')} (known: ${agentToolNames.join(', ')}).');
      tools = raw.contains('*') || raw.trim() == 'all' ? null : names.toSet().toList();
    }

    AgentMode? mode;
    if (str('permissions') ?? str('mode') case final raw?) {
      mode = parseAgentMode(raw);
      if (mode == null) errors.add('The permissions "$raw" is not one of ask, auto-edit, plan, full-auto.');
    }
    if (body.isEmpty) warnings.add('The body is empty, so the agent has no instructions of its own.');

    return AgentDefinition(
      name: name,
      description: description,
      prompt: body,
      model: model,
      effort: effort,
      tools: tools,
      mode: mode,
      source: source,
      path: path,
      projectId: projectId,
      text: text,
      digest: digest,
      errors: errors,
      warnings: warnings,
    );
  }

  /// A starting file for a new agent called [name].
  static String template(String name) =>
      '''
---
name: $name
description: Say in one sentence what this agent does and when to use it
model: inherit
effort: inherit
permissions: ask
---
Write the agent's instructions here: what it focuses on, how it works, and what its final report contains.
''';

  /// The description as it goes into a prompt: one line, at most 200 characters.
  String get oneLine {
    final s = description.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s.length <= 200 ? s : '${s.substring(0, 197)}...';
  }
}

/// `ask`, `auto-edit`, `plan`, `full-auto` (any case, `_`/space/`-`
/// tolerant); null for anything else.
AgentMode? parseAgentMode(String raw) => switch (raw.toLowerCase().replaceAll(RegExp(r'[\s_-]'), '')) {
  'ask' || 'default' => AgentMode.ask,
  'autoedit' || 'acceptedits' => AgentMode.autoEdit,
  'plan' || 'readonly' => AgentMode.plan,
  'fullauto' => AgentMode.fullAuto,
  _ => null,
};

/// The more careful of two modes: Plan, then Ask, Auto-edit, Full auto.
AgentMode stricterMode(AgentMode a, AgentMode b) {
  int rank(AgentMode m) => switch (m) {
    AgentMode.plan => 0,
    AgentMode.ask => 1,
    AgentMode.autoEdit => 2,
    AgentMode.fullAuto => 3,
    AgentMode.bypass => 4,
  };
  return rank(a) <= rank(b) ? a : b;
}

/// The user's choices: which agents are off, and which project agents they
/// trusted (bound to the digest they saw). Preferences `code.agent_library`.
@immutable
final class AgentLibrarySettings {
  const AgentLibrarySettings({this.disabled = const {}, this.trusted = const {}, this.preferred = const {}});

  final Set<String> disabled;

  /// Agent name → the model and effort the user wants it on ('' for the
  /// orchestrator's), over what its file says.
  final Map<String, ({String model, String effort})> preferred;

  ({String model, String effort}) preferredFor(String name) => preferred[name] ?? (model: '', effort: '');

  AgentLibrarySettings withPreferred(String name, {String? model, String? effort}) {
    final was = preferredFor(name);
    final next = (model: model ?? was.model, effort: effort ?? was.effort);
    final all = {...preferred}..remove(name);
    if (next.model.isNotEmpty || next.effort.isNotEmpty) all[name] = next;
    return AgentLibrarySettings(disabled: disabled, trusted: trusted, preferred: all);
  }

  /// Agent key → digest trusted.
  final Map<String, String> trusted;

  factory AgentLibrarySettings.fromJson(Object? json) {
    if (json is! Map) return const AgentLibrarySettings();
    return AgentLibrarySettings(
      disabled: {...?(json['disabled'] as List?)?.whereType<String>()},
      trusted: {
        for (final e in ((json['trusted'] as Map?) ?? const {}).entries)
          if (e.key is String && e.value is String) e.key as String: e.value as String,
      },
      preferred: {
        for (final e in ((json['preferred'] as Map?) ?? const {}).entries)
          if (e.key is String && e.value is Map)
            e.key as String: (
              model: (e.value as Map)['model'] as String? ?? '',
              effort: (e.value as Map)['effort'] as String? ?? '',
            ),
      },
    );
  }

  Map<String, Object?> toJson() => {
    'disabled': [...disabled]..sort(),
    'trusted': trusted,
    if (preferred.isNotEmpty)
      'preferred': {
        for (final MapEntry(:key, :value) in preferred.entries) key: {'model': value.model, 'effort': value.effort},
      },
  };

  AgentLibrarySettings withEnabled(String key, bool on) => AgentLibrarySettings(
    disabled: on ? ({...disabled}..remove(key)) : {...disabled, key},
    trusted: trusted,
    preferred: preferred,
  );

  AgentLibrarySettings withTrust(String key, String? digest) => AgentLibrarySettings(
    disabled: disabled,
    trusted: digest == null ? ({...trusted}..remove(key)) : {...trusted, key: digest},
    preferred: preferred,
  );

  bool enabled(AgentDefinition a) => !disabled.contains(a.key);

  /// Built-in and global agents are the user's own; a project agent needs
  /// trust for exactly the file on disk now.
  bool trustedNow(AgentDefinition a) => a.source != AgentSource.project || trusted[a.key] == a.digest;

  bool changedSinceTrusted(AgentDefinition a) =>
      a.source == AgentSource.project && trusted.containsKey(a.key) && trusted[a.key] != a.digest;

  bool active(AgentDefinition a) => a.usable && enabled(a) && trustedNow(a);
}

/// Why [a] isn't offered to the agent; null when it is.
String? agentStatus(AgentDefinition a, AgentLibrarySettings settings, {AgentDefinition? shadowedBy}) {
  if (!a.usable) return a.errors.first;
  if (shadowedBy != null) return 'Hidden by the ${shadowedBy.source.label.toLowerCase()} agent of the same name.';
  if (settings.changedSinceTrusted(a)) return 'Changed since you trusted it. Review it again to turn it on.';
  if (!settings.trustedNow(a)) return 'Came with the project. Review it and trust it to turn it on.';
  if (!settings.enabled(a)) return 'Off';
  return null;
}

/// For each name, the agent that counts in [projectId]: a project agent over
/// a global one over a built-in. With [settings], project agents not trusted
/// now are left out, so a repository can't hide the user's own agent.
Map<String, AgentDefinition> agentWinners(
  List<AgentDefinition> all,
  String? projectId, {
  AgentLibrarySettings? settings,
}) {
  int rank(AgentDefinition a) => switch (a.source) {
    AgentSource.project => 0,
    AgentSource.global => 1,
    AgentSource.builtin => 2,
  };
  final out = <String, AgentDefinition>{};
  for (final a in all) {
    if (!a.usable) continue;
    if (a.source == AgentSource.project && a.projectId != projectId) continue;
    if (settings != null && !settings.trustedNow(a)) continue;
    final had = out[a.name];
    if (had == null || rank(a) < rank(had)) out[a.name] = a;
  }
  return out;
}

/// The agents a session in [projectId] may start, sorted by name so the
/// prompt that lists them stays the same between sessions.
List<AgentDefinition> sessionAgents(List<AgentDefinition> all, AgentLibrarySettings settings, String? projectId) => [
  for (final a in agentWinners(all, projectId, settings: settings).values)
    if (settings.active(a)) a,
]..sort((a, b) => a.name.compareTo(b.name));

/// How a subagent started with [agent] runs.
typedef ChildSetup = ({AgentMode mode, String model, String? effort, List<String>? tools, String? rolePrompt});

/// What [agent] changes for a child of a session in [parentMode] on
/// [parentModel] at [parentEffort]. The agent can make the child more careful
/// than its parent, never less. The user's [preferred] model and effort for
/// the role win over the file's; a model [modelKnown] says no to (one the
/// catalog doesn't list, or that can't call tools) falls back to the
/// parent's, the orchestrator's.
ChildSetup childSetup(
  AgentDefinition? agent, {
  required AgentMode parentMode,
  required String parentModel,
  String? parentEffort,
  bool Function(String model)? modelKnown,
  ({String model, String effort})? preferred,
}) {
  if (agent == null) return (mode: parentMode, model: parentModel, effort: parentEffort, tools: null, rolePrompt: null);
  final wanted = preferred != null && preferred.model.isNotEmpty ? preferred.model : agent.model;
  final model = switch (wanted) {
    final m? when modelKnown?.call(m) ?? true => m,
    _ => parentModel,
  };
  final effort = preferred != null && preferred.effort.isNotEmpty ? preferred.effort : agent.effort;
  return (
    mode: agent.mode == null ? parentMode : stricterMode(parentMode, agent.mode!),
    model: model,
    // A model it fell back to keeps the orchestrator's effort.
    effort: model == parentModel && wanted != null && wanted != parentModel ? parentEffort : effort ?? parentEffort,
    tools: agent.tools,
    rolePrompt: agentRolePrompt(agent),
  );
}

/// The agent's instructions for the child's system prompt (after the
/// subagent rules); null when it has none.
String? agentRolePrompt(AgentDefinition agent) {
  final body = agent.prompt.trim();
  if (body.isEmpty) return null;
  return '<AGENT name="${agent.name}">\nYou are the "${agent.name}" agent: ${agent.oneLine}\n\n'
      '${body.replaceAll('</AGENT>', '</ AGENT>')}\n</AGENT>';
}
