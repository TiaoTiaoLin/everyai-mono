import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/preferences.dart';

/// Preferences key: `{projectId: {leadId: [skill name]}}`, the skills of an outside lead (Claude Code) turned off
/// in a project. The names are the lead's own, so they are not keyed by our `InstalledSkill`s.
const leadSkillsOffKey = 'code.skills.lead_off';

/// Preferences key: `{leadId: [skill name]}`, the skills each lead listed when it last started, so Settings can
/// show them before a session runs.
const leadSkillsSeenKey = 'code.skills.seen';

Map<String, Object?> _read(Preferences prefs, String key) {
  try {
    if (jsonDecode(prefs[key] ?? '') case final Map<String, Object?> m) return m;
  } on FormatException {
    // Unset or damaged: none.
  }
  return const {};
}

List<String> _names(Object? v) => [
  if (v is List<Object?>)
    for (final n in v)
      if (n is String) n,
];

/// The skills of [lead] turned off in [projectId] (null: no project, none).
Set<String> leadSkillsOff(Preferences prefs, String? projectId, String lead) =>
    projectId == null ? const {} : {..._names((_read(prefs, leadSkillsOffKey)[projectId] as Map?)?[lead])};

/// The skills [lead] listed last, sorted.
List<String> leadSkillsSeen(Preferences prefs, String lead) => _names(_read(prefs, leadSkillsSeenKey)[lead]);

/// Bumped when either list changes, so the screens and sessions look again.
final leadSkillsProvider = NotifierProvider<LeadSkills, int>(LeadSkills.new);

final class LeadSkills extends Notifier<int> {
  @override
  int build() => 0;

  Preferences get _prefs => ref.read(preferencesProvider);

  Set<String> off(String? projectId, String lead) => leadSkillsOff(_prefs, projectId, lead);

  List<String> seen(String lead) => leadSkillsSeen(_prefs, lead);

  /// Turns [name] on or off for [lead] in [projectId].
  void setOff(String projectId, String lead, String name, {required bool off}) {
    final all = {..._read(_prefs, leadSkillsOffKey)};
    final project = {...?all[projectId] as Map<String, Object?>?};
    final now = {..._names(project[lead])};
    if (off ? !now.add(name) : !now.remove(name)) return;
    if (now.isEmpty) {
      project.remove(lead);
    } else {
      project[lead] = (now.toList()..sort());
    }
    if (project.isEmpty) {
      all.remove(projectId);
    } else {
      all[projectId] = project;
    }
    _prefs[leadSkillsOffKey] = jsonEncode(all);
    state++;
  }

  /// [lead] listed [names] at start.
  void sawSkills(String lead, List<String> names) {
    final sorted = ({...names}.toList()..sort());
    if (sorted.join('\n') == seen(lead).join('\n')) return;
    _prefs[leadSkillsSeenKey] = jsonEncode({..._read(_prefs, leadSkillsSeenKey), lead: sorted});
    state++;
  }
}
