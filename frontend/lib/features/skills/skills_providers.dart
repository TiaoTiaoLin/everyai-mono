import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/preferences.dart';
import '../code/code_providers.dart' show codeProjectsProvider;
import 'data/skill_import.dart';
import 'data/skill_store.dart';
import 'domain/builtin_skills.dart';
import 'domain/chat_skills.dart';
import 'domain/skill_catalog.dart';

export 'domain/chat_skills.dart';
export 'domain/skill_catalog.dart';

/// The user's skill choices (Preferences `code.skills`, see [SkillSettings]).
final skillSettingsProvider = NotifierProvider<SkillSettingsNotifier, SkillSettings>(SkillSettingsNotifier.new);

final class SkillSettingsNotifier extends Notifier<SkillSettings> {
  static const key = 'code.skills';

  @override
  SkillSettings build() {
    final raw = ref.read(preferencesProvider)[key];
    if (raw == null) return const SkillSettings();
    try {
      return SkillSettings.fromJson(jsonDecode(raw));
    } on FormatException {
      return const SkillSettings();
    }
  }

  void _set(SkillSettings next) {
    state = next;
    ref.read(preferencesProvider)[key] = jsonEncode(next.toJson());
  }

  void setEnabled(InstalledSkill s, bool on) => _set(state.withEnabled(s.key, on));

  /// Trusts [s] as it is on disk now; a later change turns it off again.
  void trust(InstalledSkill s) => _set(state.withTrust(s.key, s.digest).withEnabled(s.key, true));

  void untrust(InstalledSkill s) => _set(state.withTrust(s.key, null));

  void forget(InstalledSkill s) => _set(state.withTrust(s.key, null).withEnabled(s.key, true));
}

/// Every skill folder: the EveryAI library, `~/.agents/skills`, and each Code
/// project's `.agents/skills`.
final installedSkillsProvider = AsyncNotifierProvider<InstalledSkills, List<InstalledSkill>>(InstalledSkills.new);

final class InstalledSkills extends AsyncNotifier<List<InstalledSkill>> {
  @override
  Future<List<InstalledSkill>> build() async {
    final roots = await _roots();
    if (roots.library case final dir?) {
      try {
        await seedBuiltinSkills(dir, await loadBuiltinSkills());
      } on Object {
        // Without the bundled skills the rest still works.
      }
    }
    return scanSkills(roots);
  }

  Future<SkillRoots> _roots() =>
      skillRoots([for (final p in ref.watch(codeProjectsProvider)) (id: p.id, path: p.path)]);

  Future<void> reload() async {
    state = await AsyncValue.guard(build);
  }

  /// Copies [c] into the library, or into [projectPath]'s `.agents/skills`.
  /// What the user imports is theirs, so a project import is trusted at once.
  Future<InstalledSkill?> import(ImportCandidate c, {String? projectId, String? projectPath}) async {
    final roots = await skillRoots(const []);
    final dest = projectPath == null ? roots.library : '$projectPath/$projectSkillsDir';
    if (dest == null) throw StateError('Skills need a file system.');
    final dir = await installSkill(c, dest);
    await reload();
    final added = (state.value ?? const []).where((s) => s.dir == dir).firstOrNull;
    if (added != null && added.source == SkillSource.project) ref.read(skillSettingsProvider.notifier).trust(added);
    return added;
  }

  Future<void> remove(InstalledSkill s) async {
    await deleteSkill(s);
    ref.read(skillSettingsProvider.notifier).forget(s);
    await reload();
  }
}

/// An empty skill library, for tests (no scan of the real folders) and
/// hosts without skills.
base class NoInstalledSkills extends InstalledSkills {
  @override
  Future<List<InstalledSkill>> build() async => const [];
}

/// The skills a new Code session in [projectId] gets, read from disk now
/// so a project skill changed since it was trusted stays out. The Max skill
/// comes only with [max] (the session's workflow is Max).
Future<List<InstalledSkill>> codeInstalledSkillsFor(Ref ref, String? projectId, {bool max = false}) async {
  final projects = [
    for (final p in ref.read(codeProjectsProvider))
      if (p.id == projectId) (id: p.id, path: p.path),
  ];
  final all = await scanSkills(await skillRoots(projects));
  return sessionSkills(all, ref.read(skillSettingsProvider), projectId, max: max);
}

/// [codeInstalledSkillsFor] as `agent_context.skills`.
Future<List<Map<String, Object?>>> codeSkillsFor(Ref ref, String? projectId) async => [
  for (final s in await codeInstalledSkillsFor(ref, projectId)) openHandsSkill(s),
];

/// The skills Chat offers (library and shared, active, sorted), from the
/// last scan; empty until it finished. See [chatSkillsNow].
final chatSkillsProvider = Provider<List<ChatSkill>>(
  (ref) => chatSkills(ref.watch(installedSkillsProvider).value ?? const [], ref.watch(skillSettingsProvider)),
);

/// The chat skills for a turn about to start: waits briefly for the first
/// scan, so the first message after launch still gets the catalog.
Future<List<ChatSkill>> chatSkillsNow(Ref ref) async {
  try {
    await ref.read(installedSkillsProvider.future).timeout(const Duration(seconds: 2));
  } on Object {
    // No file system, or a slow disk: go on with what there is.
  }
  return ref.read(chatSkillsProvider);
}

/// Runs the skill tools for Chat against [chatSkillsProvider].
final skillChatToolsProvider = Provider<SkillChatTools>(
  (ref) => SkillChatTools(ref.watch(chatSkillsProvider), readFile: readSkillFileBytes),
);
