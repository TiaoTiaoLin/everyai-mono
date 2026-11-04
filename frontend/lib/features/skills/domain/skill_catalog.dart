import 'package:flutter/foundation.dart';

import 'skill_format.dart';

/// Where a skill was found.
enum SkillSource {
  /// The EveryAI skills folder in app support (imports land here).
  library('EveryAI'),

  /// `~/.agents/skills`, shared with other agent tools.
  shared('~/.agents/skills'),

  /// `<project>/.agents/skills`: came with the repository, so it is off until
  /// the user trusts it.
  project('Project');

  const SkillSource(this.label);
  final String label;
}

/// A skill folder on disk, checked.
@immutable
final class InstalledSkill {
  const InstalledSkill({
    required this.dirName,
    required this.dir,
    required this.source,
    required this.report,
    required this.digest,
    this.manifest,
    this.projectId,
    this.files = const [],
  });

  /// The folder's name (the skill's name when it is valid).
  final String dirName;

  /// Absolute folder path.
  final String dir;
  final SkillSource source;

  /// For [SkillSource.project].
  final String? projectId;
  final SkillManifest? manifest;
  final SkillReport report;

  /// SHA-256 over the folder's files; a project skill's trust is bound to it.
  final String digest;

  /// The skill's files, relative to [dir] (`/`-separated, sorted), without
  /// `SKILL.md` itself: what `read_skill_file` may open in Chat.
  final List<String> files;

  String get name => manifest?.name ?? dirName;
  String get skillMdPath => '$dir/SKILL.md';
  bool get usable => manifest != null && report.ok;

  /// Stable id for settings: `library:name`, `shared:name`, `project:<id>:name`.
  String get key => source == SkillSource.project ? 'project:$projectId:$dirName' : '${source.name}:$dirName';
}

/// The user's choices: which skills are off, and which project skills they
/// trusted (bound to the digest they saw). Preferences `code.skills`.
@immutable
final class SkillSettings {
  const SkillSettings({this.disabled = const {}, this.trusted = const {}});

  final Set<String> disabled;

  /// Skill key → digest trusted.
  final Map<String, String> trusted;

  factory SkillSettings.fromJson(Object? json) {
    if (json is! Map) return const SkillSettings();
    return SkillSettings(
      disabled: {...?(json['disabled'] as List?)?.whereType<String>()},
      trusted: {
        for (final e in ((json['trusted'] as Map?) ?? const {}).entries)
          if (e.key is String && e.value is String) e.key as String: e.value as String,
      },
    );
  }

  Map<String, Object?> toJson() => {
    'disabled': [...disabled]..sort(),
    'trusted': trusted,
  };

  SkillSettings withEnabled(String key, bool on) =>
      SkillSettings(disabled: on ? ({...disabled}..remove(key)) : {...disabled, key}, trusted: trusted);

  SkillSettings withTrust(String key, String? digest) => SkillSettings(
    disabled: disabled,
    trusted: digest == null ? ({...trusted}..remove(key)) : {...trusted, key: digest},
  );

  bool enabled(InstalledSkill s) => !disabled.contains(s.key);

  /// Library and shared skills are the user's own; a project skill needs
  /// trust for exactly the content on disk now.
  /// An empty digest (a folder that couldn't be read whole) is never trusted.
  bool trustedNow(InstalledSkill s) =>
      s.source != SkillSource.project || (s.digest.isNotEmpty && trusted[s.key] == s.digest);

  /// The user trusted an earlier version of this project skill.
  bool changedSinceTrusted(InstalledSkill s) =>
      s.source == SkillSource.project && trusted.containsKey(s.key) && trusted[s.key] != s.digest;

  bool active(InstalledSkill s) => s.usable && enabled(s) && trustedNow(s);
}

/// Why [s] doesn't reach the agent; null when it does.
String? skillStatus(InstalledSkill s, SkillSettings settings, {InstalledSkill? shadowedBy}) {
  if (!s.usable) return s.report.errors.firstOrNull ?? 'Not a valid skill.';
  if (shadowedBy != null) return 'Hidden by the ${shadowedBy.source.label} skill of the same name.';
  if (settings.changedSinceTrusted(s)) return 'Changed since you trusted it. Review it again to turn it on.';
  if (!settings.trustedNow(s)) return 'Came with the project. Review it and trust it to turn it on.';
  if (!settings.enabled(s)) return 'Off';
  return null;
}

/// The bundled Max approach skill. It reaches a session only when the
/// user picks Max for it, never by default (it starts forks).
const maxSkillName = 'everyai-max';

/// The skills a session in [projectId] gets: active ones, sorted by name so
/// the prompt stays the same between sessions (a cache-stable prefix). A
/// trusted project skill wins over a library or shared one of the same name,
/// and a library skill over a shared one. An untrusted project skill can't
/// hide the user's own skill. [maxSkillName] is left out unless [max].
List<InstalledSkill> sessionSkills(
  List<InstalledSkill> all,
  SkillSettings settings,
  String? projectId, {
  bool max = false,
}) {
  final byName = <String, InstalledSkill>{};
  for (final s in winnersFor(all, projectId, settings: settings).values) {
    if (s.name == maxSkillName && !max) continue;
    if (settings.active(s)) byName[s.name] = s;
  }
  return [...byName.values]..sort((a, b) => a.name.compareTo(b.name));
}

/// For each name, the skill that counts in [projectId] (active or not).
/// With [settings], project skills not trusted now are left out of the race.
Map<String, InstalledSkill> winnersFor(List<InstalledSkill> all, String? projectId, {SkillSettings? settings}) {
  int rank(InstalledSkill s) => switch (s.source) {
    SkillSource.project => 0,
    SkillSource.library => 1,
    SkillSource.shared => 2,
  };
  final out = <String, InstalledSkill>{};
  for (final s in all) {
    if (!s.usable) continue;
    if (s.source == SkillSource.project && s.projectId != projectId) continue;
    if (settings != null && !settings.trustedNow(s)) continue;
    final had = out[s.name];
    if (had == null || rank(s) < rank(had)) out[s.name] = s;
  }
  return out;
}

/// [s] as an OpenHands `Skill` for `agent_context.skills`. The agent-server
/// lists it in `<available_skills>` and loads the body through its
/// `invoke_skill` tool. Inline `!`command`` tokens are escaped: the server
/// would otherwise run them, unapproved, whenever the skill is invoked.
Map<String, Object?> openHandsSkill(InstalledSkill s) {
  final m = s.manifest!;
  return {
    'name': m.name,
    'content': escapeInlineCommands(m.body),
    'trigger': null,
    'source': s.skillMdPath,
    'is_agentskills_format': true,
    'description': m.description,
    'license': ?m.license,
    'compatibility': ?m.compatibility,
    if (m.metadata.isNotEmpty) 'metadata': m.metadata,
    // Advisory in OpenHands; the app's permission policy still decides.
    if (m.allowedTools case final t? when t.isNotEmpty) 'allowed_tools': t.split(RegExp(r'\s+')),
  };
}
