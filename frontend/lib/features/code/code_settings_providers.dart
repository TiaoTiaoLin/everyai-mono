import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/preferences.dart';
import '../skills/skills_providers.dart' show skillSettingsProvider;
import 'mcp_providers.dart';
import 'permissions_providers.dart';
import 'settings/code_settings.dart';
import 'settings/settings.dart' show readLayer, userSettingsPath;

export 'settings/code_settings.dart';

/// The overarching system prompts and session budgets (Preferences
/// `code.settings`, see [StoredCodeSettings]).
final codeSettingsProvider = NotifierProvider<CodeSettings, StoredCodeSettings>(CodeSettings.new);

final class CodeSettings extends Notifier<StoredCodeSettings> {
  static const key = 'code.settings';

  @override
  StoredCodeSettings build() {
    final raw = ref.read(preferencesProvider)[key];
    if (raw == null) return const StoredCodeSettings();
    try {
      return StoredCodeSettings.fromJson(jsonDecode(raw));
    } on FormatException {
      return const StoredCodeSettings();
    }
  }

  void _set(StoredCodeSettings next) {
    state = next;
    ref.read(preferencesProvider)[key] = jsonEncode(next.toJson());
  }

  /// Replaces every value at once (the Code settings editor).
  void replace(StoredCodeSettings next) => _set(next);

  /// The prompt for [projectId] (null: every project).
  void setPrompt(String? projectId, String prompt) => _set(state.withPrompt(projectId, prompt));

  /// Compact EveryAI sessions at [percent] of the context window (0: off).
  void setAutoCompact(int percent) => _set(state.withAutoCompact(percent));

  void setTier(HarnessTier tier) => _set(state.withTier(tier));

  void setResearchSites(List<String> sites) => _set(state.withResearchSites(sites));

  void setForksIsolated(bool on) => _set(state.withForksIsolated(on));

  /// Lets driver [driverId] run the user's own installed CLI (or stops it).
  void setOwnCli(String driverId, bool on) => _set(state.withOwnCli(driverId, on));

  /// Caps session [sessionId]'s spending at [usd] dollars (null: no cap).
  void setBudget(String sessionId, double? usd) => _set(state.withBudget(sessionId, usd));
}

/// Where the Global `settings.json` lives (null without an app folder).
final userSettingsPathProvider = FutureProvider<String?>((ref) => userSettingsPath());

/// The JSON object in a `settings.json` layer file, by path. Invalidate it
/// after a write. Errors when the file isn't a JSON object.
final settingsLayerProvider = FutureProvider.family<Map<String, Object?>, String>((ref, path) => readLayer(path));

/// Every store the layered settings read; [session] adds the
/// session layer. [watch] (in build methods) rebuilds the caller on changes.
CodeSettingsSources codeSettingsSources(WidgetRef ref, {SessionLayer? session, bool watch = false}) => watch
    ? CodeSettingsSources(
        settings: ref.watch(codeSettingsProvider),
        permissions: ref.watch(codePermissionsProvider),
        mcp: ref.watch(codeMcpServersProvider),
        skills: ref.watch(skillSettingsProvider),
        session: session,
      )
    : CodeSettingsSources(
        settings: ref.read(codeSettingsProvider),
        permissions: ref.read(codePermissionsProvider),
        mcp: ref.read(codeMcpServersProvider),
        skills: ref.read(skillSettingsProvider),
        session: session,
      );
