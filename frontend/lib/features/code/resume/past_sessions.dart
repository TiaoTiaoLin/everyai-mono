// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import '../harness/events.dart';

/// A conversation a harness keeps on disk or behind its API for one folder, whether it was started inside EveryAI
/// or in the CLI on its own.
final class PastSession {
  const PastSession({
    required this.harness,
    required this.nativeId,
    required this.cwd,
    required this.title,
    required this.lastActive,
    this.turns,
    this.model,
    this.branch,
  });

  /// Driver id (`claude-code`, `codex`, `opencode`, `gemini`, an ACP registry id, ...).
  final String harness;

  /// The harness's own session id, the one its resume path takes.
  final String nativeId;

  /// The folder the session ran in (the picked folder or one of its worktrees).
  final String cwd;

  /// Its title, or the first user message cut short.
  final String title;
  final DateTime lastActive;
  final int? turns;
  final String? model;
  final String? branch;
}

/// Lists and reads one harness's earlier sessions. Reading never runs the CLI or calls a model.
abstract interface class PastSessionSource {
  /// The driver id the sessions resume on.
  String get harness;

  /// Sessions whose cwd is [folder] or one of [worktrees], newest first.
  Future<List<PastSession>> list(String folder, {List<String> worktrees = const []});

  /// The full history as our events, in the harness's own vocabulary (as its driver maps them).
  Future<List<HarnessEvent>> history(PastSession session);
}
