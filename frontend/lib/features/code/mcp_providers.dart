import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/preferences.dart';
import 'domain/mcp_servers.dart';

export 'domain/mcp_servers.dart';

/// The user's MCP servers for Code sessions (Preferences `code.mcp_servers`,
/// see [StoredMcpServers]). Sessions read them when they start.
final codeMcpServersProvider = NotifierProvider<CodeMcpServers, StoredMcpServers>(CodeMcpServers.new);

final class CodeMcpServers extends Notifier<StoredMcpServers> {
  static const key = 'code.mcp_servers';

  @override
  StoredMcpServers build() {
    final raw = ref.read(preferencesProvider)[key];
    if (raw == null) return const StoredMcpServers();
    try {
      return StoredMcpServers.fromJson(jsonDecode(raw));
    } on FormatException {
      return const StoredMcpServers();
    }
  }

  void _set(StoredMcpServers next) {
    state = next;
    ref.read(preferencesProvider)[key] = jsonEncode(next.toJson());
  }

  /// Adds [server] to [projectId]'s list (null: global), or replaces the
  /// entry called [replacing] (default: the same name).
  void put(McpServer server, {String? projectId, String? replacing}) {
    final old = replacing ?? server.name;
    final list = state.listFor(projectId);
    final at = list.indexWhere((s) => s.name == old);
    // A rename onto another entry's name replaces that entry too.
    final next = [...list.where((s) => s.name != old && s.name != server.name)];
    next.insert(at < 0 ? next.length : at.clamp(0, next.length), server);
    _set(state.withList(projectId, next));
  }

  void remove(String name, {String? projectId}) =>
      _set(state.withList(projectId, [...state.listFor(projectId).where((s) => s.name != name)]));

  void setEnabled(String name, bool enabled, {String? projectId}) => _set(
    state.withList(projectId, [
      for (final s in state.listFor(projectId)) s.name == name ? s.copyWith(enabled: enabled) : s,
    ]),
  );

  /// Records the user's approval of [name] as it stands now.
  void approve(String name, {String? projectId}) =>
      _set(state.withList(projectId, [for (final s in state.listFor(projectId)) s.name == name ? s.approve() : s]));

  /// What a session in [projectId] found about its servers' tools (see
  /// [StoredMcpServers.withReports]).
  void recordTools(Map<String, McpToolsReport> reports, {String? projectId}) {
    if (reports.isEmpty) return;
    _set(state.withReports(projectId, reports));
  }

  /// Allows [name]'s tools that wait for review, as they were seen: the next
  /// session (or a reopened one) gets them.
  void allowTools(String name, {String? projectId}) => _set(
    state.withList(projectId, [for (final s in state.listFor(projectId)) s.name == name ? s.allowPending() : s]),
  );
}
