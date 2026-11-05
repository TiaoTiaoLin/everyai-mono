import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/preferences.dart';
import 'domain/permissions.dart';

export 'domain/permissions.dart';

/// Permission rules kept in the app (Preferences `code.permissions`): one
/// global set and one per project, by project id. "Always allow" on an
/// approval card adds to the project's set. Rules in `settings.json` files
/// are merged on top when a session starts.
///
/// ```json
/// {"global": {"allow": [], "deny": ["git push *"]},
///  "projects": {"<project id>": {"allow": ["npm test *", "Edit(lib/**)"], "deny": []}}}
/// ```
@immutable
final class StoredPermissions {
  const StoredPermissions({this.global = PermissionRules.none, this.projects = const {}});

  final PermissionRules global;
  final Map<String, PermissionRules> projects;

  /// The global rules, then [projectId]'s.
  PermissionRules rulesFor(String? projectId) => global + (projects[projectId] ?? PermissionRules.none);

  factory StoredPermissions.fromJson(Object? json) {
    if (json is! Map<String, Object?>) return const StoredPermissions();
    final projects = json['projects'];
    return StoredPermissions(
      global: PermissionRules.fromJson(json['global']),
      projects: {
        if (projects is Map<String, Object?>)
          for (final e in projects.entries) e.key: PermissionRules.fromJson(e.value),
      },
    );
  }

  Map<String, Object?> toJson() => {
    'global': global.toJson(),
    'projects': {
      for (final e in projects.entries)
        if (!e.value.isEmpty) e.key: e.value.toJson(),
    },
  };
}

final codePermissionsProvider = NotifierProvider<CodePermissions, StoredPermissions>(CodePermissions.new);

final class CodePermissions extends Notifier<StoredPermissions> {
  static const key = 'code.permissions';

  @override
  StoredPermissions build() {
    final raw = ref.read(preferencesProvider)[key];
    if (raw == null) return const StoredPermissions();
    try {
      return StoredPermissions.fromJson(jsonDecode(raw));
    } on FormatException {
      return const StoredPermissions();
    }
  }

  void _set(StoredPermissions next) {
    state = next;
    ref.read(preferencesProvider)[key] = jsonEncode(next.toJson());
  }

  PermissionRules _of(String? projectId) =>
      projectId == null ? state.global : state.projects[projectId] ?? PermissionRules.none;

  void _put(String? projectId, PermissionRules rules) => _set(
    projectId == null
        ? StoredPermissions(global: rules, projects: state.projects)
        : StoredPermissions(global: state.global, projects: {...state.projects, projectId: rules}),
  );

  /// Adds an allow rule, for [projectId] or (null) everywhere.
  void allow(String pattern, {String? projectId}) {
    final r = _of(projectId);
    if (r.allow.contains(pattern)) return;
    _put(projectId, PermissionRules(allow: [...r.allow, pattern], deny: r.deny));
  }

  /// Adds a deny rule, for [projectId] or (null) everywhere.
  void deny(String pattern, {String? projectId}) {
    final r = _of(projectId);
    if (r.deny.contains(pattern)) return;
    _put(projectId, PermissionRules(allow: r.allow, deny: [...r.deny, pattern]));
  }

  /// Removes [pattern] from both lists.
  void remove(String pattern, {String? projectId}) {
    final r = _of(projectId);
    _put(projectId, PermissionRules(allow: [...r.allow]..remove(pattern), deny: [...r.deny]..remove(pattern)));
  }
}

/// Bumped whenever Settings writes a `settings.json` layer, so running sessions read their rules again.
final settingsFilesRevisionProvider = NotifierProvider<SettingsFilesRevision, int>(SettingsFilesRevision.new);

final class SettingsFilesRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}
