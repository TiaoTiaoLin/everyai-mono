// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/preferences.dart';
import 'workflow_files_stub.dart' if (dart.library.io) 'workflow_files_io.dart' as files;
import 'workflow_meta.dart';

// The workflows a session can run: the ones bundled with the app
// (`assets/workflows/`), then the project's own `.everyai/workflows/*.js`.
// A project file came with the repository, so like project commands and
// agents it stays off until the user trusts it, bound to its digest.

enum WorkflowOrigin { bundled, project }

final class WorkflowEntry {
  const WorkflowEntry({
    required this.id,
    required this.title,
    required this.source,
    required this.digest,
    required this.origin,
    this.description = '',
    this.whenToUse = '',
    this.args = '',
    this.phases = const [],
    this.projectDir,
    this.path,
  });

  /// Its prompt name (`/mcp__everyai__<id>` in Claude Code): `[a-z0-9_-]`.
  final String id;
  final String title;
  final String source;
  final String digest;
  final WorkflowOrigin origin;
  final String description;
  final String whenToUse;
  final String args;
  final List<({String title, String detail})> phases;
  final String? projectDir;
  final String? path;

  String get trustKey => '$projectDir::$id';
}

/// The bundled workflows, in the order they are listed.
const bundledWorkflowIds = ['ultra', 'bugfix', 'security_review'];

const _assetDir = 'assets/workflows/';

/// [stem] as a workflow id: lowercase, runs of other characters as `-`.
String workflowId(String stem) =>
    stem.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_-]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');

/// Meta by digest, so listing a file again doesn't parse it again.
final _metaCache = <String, WorkflowMeta?>{};

WorkflowEntry _entry(String source, String id, WorkflowOrigin origin, {String? projectDir, String? path}) {
  final digest = sha256.convert(utf8.encode(source)).toString();
  final meta = _metaCache.putIfAbsent(digest, () => parseWorkflowMeta(source));
  return WorkflowEntry(
    id: id,
    title: meta?.name ?? id,
    source: source,
    digest: digest,
    origin: origin,
    description: meta?.description ?? '',
    whenToUse: meta?.whenToUse ?? '',
    args: meta?.args ?? '',
    phases: meta?.phases ?? const [],
    projectDir: projectDir,
    path: path,
  );
}

/// The bundled workflows, in [bundledWorkflowIds] order.
Future<List<WorkflowEntry>> loadBundledWorkflows([AssetBundle? bundle]) async {
  final b = bundle ?? rootBundle;
  return [
    for (final id in bundledWorkflowIds) _entry(await b.loadString('$_assetDir$id.js'), id, WorkflowOrigin.bundled),
  ];
}

/// [projectDir]'s own workflows, by id. The id is the file's stem, never
/// its meta's, so a file can't pass itself off as a bundled one.
Future<List<WorkflowEntry>> loadProjectWorkflows(String projectDir) async {
  final out = <WorkflowEntry>[];
  for (final f in await files.projectWorkflowFiles(projectDir)) {
    final id = workflowId(f.stem);
    if (id.isEmpty) continue;
    try {
      out.add(_entry(f.source, id, WorkflowOrigin.project, projectDir: projectDir, path: f.path));
    } on Object {
      // One bad file is left out; it never hides the others.
    }
  }
  return out..sort((a, b) => a.id.compareTo(b.id));
}

/// Which project workflows the user has reviewed: trust key → digest.
/// The same rules as `CommandTrust` (features/slash), kept apart because
/// that one is typed to commands; fold them together later.
final class WorkflowTrust {
  const WorkflowTrust([this.trusted = const {}]);

  final Map<String, String> trusted;

  factory WorkflowTrust.fromJson(Object? json) => WorkflowTrust(<String, String>{
    for (final e in (json is Map ? json : const <String, String>{}).entries)
      if (e.key is String && e.value is String) e.key as String: e.value as String,
  });

  Map<String, String> toJson() => trusted;

  bool trustedNow(WorkflowEntry w) => w.origin == WorkflowOrigin.bundled || trusted[w.trustKey] == w.digest;

  bool changedSinceTrusted(WorkflowEntry w) =>
      w.origin != WorkflowOrigin.bundled && trusted.containsKey(w.trustKey) && !trustedNow(w);

  WorkflowTrust withTrust(WorkflowEntry w, bool on) =>
      WorkflowTrust(on ? {...trusted, w.trustKey: w.digest} : ({...trusted}..remove(w.trustKey)));

  /// Why a workflow is locked, for the list.
  String? lockedNote(WorkflowEntry w) {
    if (trustedNow(w)) return null;
    return changedSinceTrusted(w)
        ? 'Changed since you trusted it. Review it again to turn it on.'
        : 'Came with the project. Review it and trust it to turn it on.';
  }
}

/// What a project can run, and what is shown but off.
typedef WorkflowLibrary = ({List<WorkflowEntry> active, List<({WorkflowEntry entry, String note})> locked});

/// [bundled] first, then the trusted [project] ones. A project id equal to a
/// bundled one is locked with a note: a cloned repo can't take over `/ultra`.
WorkflowLibrary workflowLibrary(List<WorkflowEntry> bundled, List<WorkflowEntry> project, WorkflowTrust trust) {
  final taken = {for (final w in bundled) w.id};
  final active = [...bundled];
  final locked = <({WorkflowEntry entry, String note})>[];
  for (final w in project) {
    if (taken.contains(w.id)) {
      locked.add((entry: w, note: "Can't replace the built-in ${w.id} workflow. Rename the file to turn it on."));
    } else if (trust.lockedNote(w) case final note?) {
      locked.add((entry: w, note: note));
    } else {
      active.add(w);
    }
  }
  return (active: active, locked: locked);
}

/// The workflows [projectDir] can run now (bundled, then trusted project ones).
/// An unreadable project folder leaves the bundled ones.
Future<List<WorkflowEntry>> activeWorkflows(String projectDir, WorkflowTrust trust, {AssetBundle? bundle}) async {
  final bundled = await loadBundledWorkflows(bundle);
  List<WorkflowEntry> project;
  try {
    project = await loadProjectWorkflows(projectDir);
  } on Object {
    project = const [];
  }
  return workflowLibrary(bundled, project, trust).active;
}

/// Which project workflows are trusted. Preferences `code.workflows`.
final workflowTrustProvider = NotifierProvider<WorkflowTrustNotifier, WorkflowTrust>(WorkflowTrustNotifier.new);

final class WorkflowTrustNotifier extends Notifier<WorkflowTrust> {
  static const key = 'code.workflows';

  @override
  WorkflowTrust build() {
    final raw = ref.read(preferencesProvider)[key];
    if (raw == null) return const WorkflowTrust();
    try {
      return WorkflowTrust.fromJson(jsonDecode(raw));
    } on FormatException {
      return const WorkflowTrust();
    }
  }

  /// Trusts or locks [w]. A workflow the user made in the app is trusted
  /// this way as it is saved.
  void set(WorkflowEntry w, bool trusted) {
    state = state.withTrust(w, trusted);
    ref.read(preferencesProvider)[key] = jsonEncode(state.toJson());
  }
}

/// The workflows [projectDir] can run, read afresh each time it is watched.
final workflowsProvider = FutureProvider.autoDispose.family<List<WorkflowEntry>, String>(
  (ref, projectDir) => activeWorkflows(projectDir, ref.watch(workflowTrustProvider)),
);

/// [ref] names a commit in the git repository at [dir].
Future<bool> isGitCommit(String dir, String ref) => files.isGitCommit(dir, ref);
