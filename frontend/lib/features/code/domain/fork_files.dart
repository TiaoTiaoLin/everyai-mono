import '../harness/events.dart';
import 'agent_mode.dart';
import 'phases.dart';

// Files a session's running subagents work on, so the session leaves them
// alone until they report, and what a phase of the Max/Ultra flow lets the
// agent change before its plan is approved.

/// The file [call] writes or edits, as the agent gave it; null for any other action.
/// A patch names its first file here; [writeTargets] has them all.
String? writeTarget(ActionCall call) => writeTargets(call).firstOrNull;

/// Every file [call] writes or edits: one for a write or an edit, each file
/// of a patch (added, updated, deleted, or moved and where to). Empty for
/// any other action.
List<String> writeTargets(ActionCall call) {
  if (!AgentMode.isFileEdit(call) || AgentMode.isReadOnly(call)) return const [];
  if (call.actionKind == 'ApplyPatchAction') {
    final paths = [...?(call.action['paths'] as List<Object?>?)?.whereType<String>()];
    if (paths.isNotEmpty) return paths;
  }
  final path = call.str('file_path').isNotEmpty ? call.str('file_path') : call.str('path');
  return path.isEmpty ? const [] : [path];
}

/// [path] relative to [dir] (an absolute path inside it, or a relative one);
/// null when it lies outside.
String? relativeTo(String path, String dir) {
  final base = dir.endsWith('/') ? dir.substring(0, dir.length - 1) : dir;
  final String rel;
  if (path.startsWith('/')) {
    if (!path.startsWith('$base/')) return null;
    rel = path.substring(base.length + 1);
  } else {
    rel = path;
  }
  final parts = <String>[];
  for (final part in rel.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (parts.isEmpty) return null;
      parts.removeLast();
    } else {
      parts.add(part);
    }
  }
  return parts.isEmpty ? null : parts.join('/');
}

/// Files [events] wrote or edited, relative to [dir] (the subagent's folder:
/// its own copy of the parent's, or the parent's itself). A call that was
/// refused or failed wrote nothing, so it claims nothing; one still running
/// does.
Set<String> filesWritten(Iterable<HarnessEvent> events, String dir) {
  final list = events.toList(growable: false);
  final failed = <String>{
    for (final e in list)
      if (e is ToolResult && e.outcome != ToolOutcome.ok) ...[
        if (e.actionId.isNotEmpty) e.actionId,
        if (e.toolCallId.isNotEmpty) e.toolCallId,
      ],
  };
  return _written(
    list.where((e) => e is! ActionCall || !(failed.contains(e.id) || failed.contains(e.toolCallId))),
    dir,
  );
}

Set<String> _written(Iterable<HarnessEvent> events, String dir) => {
  for (final e in events)
    if (e is ActionCall)
      for (final path in writeTargets(e)) ?relativeTo(path, dir),
};

/// File names a task's text mentions ("index.html", "src/games.js").
Set<String> filesNamed(String text) => {for (final m in _fileName.allMatches(text)) ?relativeTo(m[0]!, '')};

final _fileName = RegExp(r'(?<![\w/.:@-])(?:\.?/)?(?:[\w-]+/)*[\w-]+\.[A-Za-z][A-Za-z0-9]{0,7}(?![\w/-])');

/// Why [call] has to wait: it changes a file a running subagent works on.
/// [owned] maps each running subagent's title to its files, relative to [dir].
String? waitForSubagent(ActionCall call, Map<String, Set<String>> owned, String dir) {
  if (owned.isEmpty) return null;
  final targets = writeTargets(call);
  if (targets.isNotEmpty) {
    for (final path in targets) {
      final rel = relativeTo(path, dir);
      if (rel == null) continue;
      for (final MapEntry(key: title, value: files) in owned.entries) {
        if (files.contains(rel)) return _wait(rel, title);
      }
    }
    return null;
  }
  // A shell command that changes things and names one of those files.
  if (call.actionKind != 'TerminalAction' || AgentMode.isReadOnly(call)) return null;
  final command = call.str('command');
  for (final MapEntry(key: title, value: files) in owned.entries) {
    for (final file in files) {
      final name = file.split('/').last;
      if (RegExp('(?<![\\w.-])${RegExp.escape(name)}(?![\\w-])').hasMatch(command)) return _wait(file, title);
    }
  }
  return null;
}

String _wait(String file, String title) =>
    'Not run: $file is being changed by the subagent "$title", which is still working. Leave it alone until '
    'its report arrives (its result, or a <task-notification>): work on other files, or end your turn and the '
    'report wakes you. Then read the file again before you change it.';

/// Phases of the Max/Ultra flow in which the project isn't built yet. (Bug
/// fix's reproduce and triage are gated by the harness itself.)
bool beforeBuild(Phase? phase) => phase == Phase.research || phase == Phase.questions || phase == Phase.plan;

/// Why [call] is refused in [phase] of [flow], before the plan is approved:
/// it writes a project file (the agent's own `.everyai/` notes are fine).
String? refusedBeforeBuild(ActionCall call, Phase? phase, String flow, String dir) {
  if (!beforeBuild(phase)) return null;
  // Every file of a patch counts, not just its first.
  final project = [
    for (final path in writeTargets(call))
      if (relativeTo(path, dir) case final rel? when rel != '.everyai' && !rel.startsWith('.everyai/')) rel,
  ];
  if (project.isEmpty) return null;
  return 'Not written: the $flow flow is in its ${phase!.name} phase, and project files change in Build, once '
      'the plan is approved. Until then write only under .everyai/scratch/ (the plan goes in '
      '.everyai/scratch/plan.md).';
}

/// Why a `run_subagent` [task] doesn't start in [phase]: only researchers and
/// reviewers run before the plan is approved; forks that build wait for Build.
String? subagentBeforeBuild(String role, Phase? phase, String flow) {
  if (!beforeBuild(phase) || _lookers.contains(role)) return null;
  return 'Not started: the $flow flow is in its ${phase!.name} phase. Forks that build start in Build, once the '
      'plan is approved; until then only "researcher", "explorer" and "reviewer" subagents run.';
}

const _lookers = {'researcher', 'explorer', 'reviewer'};
