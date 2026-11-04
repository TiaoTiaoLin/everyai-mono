// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'handoff.dart';

/// What a native import is given: every lead's stint so far, the handoff facts, and the worktree.
final class NativeImportSource {
  const NativeImportSource({required this.stints, required this.handoff, required this.cwd, required this.title});

  final List<HandoffStint> stints;
  final Handoff handoff;
  final String cwd;
  final String title;
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
