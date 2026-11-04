// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../code_providers.dart';
import '../code_settings_providers.dart';
import '../domain/code_session.dart';
import '../drivers/driver.dart';
import '../drivers/driver_policy.dart' show leadFix;
import '../drivers/driver_registry.dart';
import '../drivers/event_journal.dart';
import '../harness/events.dart';
import 'past_sessions.dart';

// New session → the picked folder's earlier sessions from every installed
// harness (read from the CLIs' own files or APIs; nothing runs, no model is
// asked), merged with EveryAI's own sessions for that folder.

/// Where each harness's earlier sessions come from. Filled in where the sources are wired; tests override it.
final pastSessionSourcesProvider = Provider<List<PastSessionSource>>((ref) => const []);

/// How long one harness may take to list a folder's sessions before it is left out.
final pastSessionTimeoutProvider = Provider<Duration>((ref) => const Duration(seconds: 5));

/// Why [driverId] has no earlier sessions to offer (it can't list or load them), for Settings → Code →
/// Harnesses; null when it can (or isn't known). Filled in where the sources are wired.
final resumeUnsupportedProvider = Provider<String? Function(String driverId)>(
  (ref) =>
      (_) => null,
);

/// One row of the list: one of EveryAI's own sessions ([ours]), or a harness's own ([past]) with what is in the
/// way of resuming it ([blocked], the picker's one-line fix; null when it can resume).
typedef EarlierSession = ({CodeSessionInfo? ours, PastSession? past, String? blocked, DateTime at});

/// The conversations [sessions] already holds for [projectId], by `harness|conversation id` (the current lead's
/// and every earlier lead's), so a harness's copy of one shows once, as ours.
Set<String> ownConversationKeys(List<CodeSessionInfo> sessions, String projectId) => {
  for (final s in sessions)
    if (s.projectId == projectId) ...[
      if (s.conversationId.isNotEmpty) '${s.harness}|${s.conversationId}',
      for (final MapEntry(:key, :value) in s.leads.entries)
        if (value.conversationId.isNotEmpty) '$key|${value.conversationId}',
    ],
};

/// The folders a project's sessions ran in besides the project itself (their worktrees).
List<String> projectWorktrees(List<CodeSessionInfo> sessions, CodeProject project) => {
  for (final s in sessions)
    if (s.projectId == project.id && s.workingDir != project.path && s.workingDir.isNotEmpty) s.workingDir,
}.toList();

/// The harnesses' own earlier sessions for [projectId]'s folder, newest first: every installed harness with a
/// source, in parallel; one that errs or takes longer than [pastSessionTimeoutProvider] is left out. Sessions
/// EveryAI already keeps are left out too ([ownConversationKeys]).
final pastSessionsProvider = FutureProvider.autoDispose.family<List<PastSession>, String>((ref, projectId) async {
  final project = ref.watch(codeProjectsProvider).where((p) => p.id == projectId).firstOrNull;
  if (project == null || isDemoPath(project.path)) return const [];
  final sources = ref.watch(pastSessionSourcesProvider);
  if (sources.isEmpty) return const [];
  final sessions = ref.watch(codeSessionsProvider);
  final timeout = ref.watch(pastSessionTimeoutProvider);
  Map<String, DriverStatus> statuses;
  try {
    statuses = await ref.watch(driverStatusesProvider.future);
  } on Object {
    statuses = const {};
  }
  final installed = [
    for (final s in sources)
      if (statuses[s.harness]?.installed ?? false) s,
  ];
  final worktrees = projectWorktrees(sessions, project);
  final lists = await Future.wait([
    for (final s in installed)
      s
          .list(project.path, worktrees: worktrees)
          .timeout(timeout)
          .then<List<PastSession>>((l) => l, onError: (Object _) => const <PastSession>[]),
  ]);
  final own = ownConversationKeys(sessions, project.id);
  return [
    for (final l in lists)
      for (final p in l)
        if (!own.contains('${p.harness}|${p.nativeId}')) p,
  ]..sort((a, b) => b.lastActive.compareTo(a.lastActive));
});

/// The rows under the New session composer for [projectId]: EveryAI's own sessions (marked) and the harnesses'
/// own, newest first; at most [limit].
final earlierSessionsProvider = Provider.autoDispose.family<List<EarlierSession>, String>((ref, projectId) {
  const limit = 12;
  final ours = [
    for (final s in ref.watch(codeSessionsProvider))
      if (s.projectId == projectId && !s.isSubagent) s,
  ];
  final past = ref.watch(pastSessionsProvider(projectId)).value ?? const <PastSession>[];
  final registry = ref.watch(driverRegistryProvider);
  final statuses = ref.watch(driverStatusesProvider).value;
  final own = ref.watch(codeSettingsProvider.select((s) => s.ownClis));
  String? blocked(String harness) {
    final d = registry.resolve(harness);
    if (d == null) return 'Not available in this version';
    if (d is! AdoptsNativeSession) return "${d.info.label} can't resume its sessions here";
    return leadFix(d.info, statuses?[harness], consented: own.contains(d.info.consentId));
  }

  final rows = <EarlierSession>[
    for (final s in ours) (ours: s, past: null, blocked: null, at: s.createdAt),
    for (final p in past) (ours: null, past: p, blocked: blocked(p.harness), at: p.lastActive),
  ]..sort((a, b) => b.at.compareTo(a.at));
  return rows.take(limit).toList();
});

/// The source that listed [past] (by harness), for reading its history.
PastSessionSource? sourceOf(List<PastSessionSource> sources, PastSession past) =>
    sources.where((s) => s.harness == past.harness).firstOrNull;

/// Where a resumed session keeps the history read from the harness's own files (shown before its own turns).
EventJournal resumedJournal(String timelineDir) => openEventJournal(timelineDir, resumedJournalName);

const resumedJournalName = 'resumed';

/// Saves [history] for a resumed session (streaming deltas aren't kept).
Future<void> saveResumedHistory(String timelineDir, List<HarnessEvent> history) async {
  final j = resumedJournal(timelineDir);
  for (final e in history) {
    j.add(e);
  }
  await j.close();
}
