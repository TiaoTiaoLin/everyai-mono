// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import '../domain/agent_mode.dart';
import 'handoff.dart';

/// What a native import is given: every lead's stint so far, the handoff facts, and the worktree. The session's
/// [mode], [model], [effort] and [sessionTag] are what the new lead runs with: an importer writes them wherever the
/// driver's reopen reads them (its session meta), as a start would. The switch also sets the mode and model on the
/// attached session, and sends any `<cut-turn>` itself.
final class NativeImportSource {
  const NativeImportSource({
    required this.stints,
    required this.handoff,
    required this.cwd,
    required this.title,
    this.mode = AgentMode.ask,
    this.model = '',
    this.effort = '',
    this.sessionTag = '',
  });

  final List<HandoffStint> stints;
  final Handoff handoff;
  final String cwd;
  final String title;
  final AgentMode mode;
  final String model;
  final String effort;

  /// The EveryAI session id the driver's processes carry (Stop finds them by it).
  final String sessionTag;
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

/// The importer for [harness], or null (facts + transcript file). Filled in by the native-import item.
NativeImporter? nativeImporterFor(String harness) => null;
