// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'workflow_bridge_stub.dart' if (dart.library.io) 'workflow_bridge_io.dart' as impl;

/// A running workflow script: what it asks for, and how to answer it.
abstract interface class WorkflowBridge {
  /// Its calls (`{id, fn, args}`) and notes (`{fn, args}`, no id), in order.
  Stream<Map<String, Object?>> get requests;

  /// Lines it printed outside the bridge (stderr, a stray write).
  Stream<String> get output;

  /// Answers call [id] with [result], or rejects it with [error].
  void reply(Object? id, {Object? result, String? error});

  /// The process's exit code.
  Future<int> get exit;

  void kill();
}

/// Starts [source] (a workflow `.js`) with [args] in Deno, its files in
/// [dir] (removed when it exits; the Deno cache is shared by every run).
/// Throws a [StateError] when there is no Deno here.
Future<WorkflowBridge> startWorkflowBridge({
  required String dir,
  required String source,
  required Map<String, Object?> args,
}) => impl.startWorkflowBridge(dir: dir, source: source, args: args);

/// The journal lines of [path] ('' when it doesn't exist yet).
Future<String> readJournalFile(String path) => impl.readJournalFile(path);

/// Appends [line] to the journal at [path], creating it.
Future<void> appendJournalFile(String path, String line) => impl.appendJournalFile(path, line);

/// The journals of unfinished runs in [dir] (`*.jsonl`), oldest first.
Future<List<String>> listJournalFiles(String dir) => impl.listJournalFiles(dir);

/// The run of the journal at [path] ended: it becomes `<run>.done.jsonl`,
/// kept to look at but no longer read when the session opens.
Future<void> retireJournalFile(String path) => impl.retireJournalFile(path);
