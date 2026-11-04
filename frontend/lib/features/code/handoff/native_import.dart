// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import '../domain/agent_mode.dart';
import 'handoff.dart';
import 'native/claude_import.dart';
import 'native/codex_import.dart';
import 'native/opencode_import.dart';

/// What a native import is given: every lead's stint so far, the handoff facts, and the worktree; and what the
/// incoming driver's own record of the session needs to reopen it (its tag, model, effort and mode). Without a
/// [sessionTag] nothing is imported.
final class NativeImportSource {
  const NativeImportSource({
    required this.stints,
    required this.handoff,
    required this.cwd,
    required this.title,
    this.sessionTag = '',
    this.model = '',
    this.effort,
    this.mode = AgentMode.ask,
  });

  final List<HandoffStint> stints;
  final Handoff handoff;
  final String cwd;
  final String title;

  /// The Code session's tag (`info.billingTag`), which owns the CLI's processes.
  final String sessionTag;

  /// The model and effort the user picked for the new lead ('' and null: the CLI's own default).
  final String model;
  final String? effort;
  final AgentMode mode;
}

/// A conversation written into the incoming CLI's own session format. The lead switch attaches the driver to
/// [nativeId] (its resume path) and sends a short carry-on instead of the full handoff message.
final class ImportedSession {
  const ImportedSession({required this.nativeId, this.note});

  final String nativeId;

  /// Optional line for the transcript (e.g. "Imported 41 turns into Claude Code").
  final String? note;
}

abstract interface class NativeImporter {
  /// The driver id this importer writes for (`claude-code`, `codex`, `opencode`).
  String get harness;

  /// Writes the session; null when this conversation can't be imported (the facts handoff is used instead).
  Future<ImportedSession?> write(NativeImportSource source);
}

/// The importer for [harness], or null (facts + transcript file): Claude Code, Codex and OpenCode take a written
/// conversation (docs/research/batches/multi-harness/run5/i1.md); ACP agents and terminal CLIs have no way to.
NativeImporter? nativeImporterFor(String harness) => switch (harness) {
  'claude-code' => ClaudeImporter(),
  'codex' => CodexImporter(),
  'opencode' => OpenCodeImporter(),
  _ => null,
};
