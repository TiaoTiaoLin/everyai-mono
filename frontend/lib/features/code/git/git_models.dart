import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Where a session's work lives: its own checkout of the project on its own
/// branch, created from the project's branch at [baseCommit].
@immutable
final class SessionWorktree {
  const SessionWorktree({
    required this.repoRoot,
    required this.path,
    required this.branch,
    required this.baseBranch,
    required this.baseCommit,
  });

  /// The user's main checkout.
  final String repoRoot;
  final String path;

  /// `everyai/<slug>`.
  final String branch;

  /// The branch the session started from (squash merges land there).
  final String baseBranch;
  final String baseCommit;

  String get slug => branch.split('/').last;

  factory SessionWorktree.fromJson(Map<String, Object?> json) => SessionWorktree(
    repoRoot: json['repo_root']! as String,
    path: json['path']! as String,
    branch: json['branch']! as String,
    baseBranch: json['base_branch'] as String? ?? '',
    baseCommit: json['base_commit'] as String? ?? '',
  );

  Map<String, Object?> toJson() => {
    'repo_root': repoRoot,
    'path': path,
    'branch': branch,
    'base_branch': baseBranch,
    'base_commit': baseCommit,
  };
}

/// Where an in-place session started: the user's own checkout, its branch and
/// commit, and a snapshot of the working tree (untracked files included) so
/// Changes shows only what the session did, not edits that were already there.
@immutable
final class GitBaseline {
  const GitBaseline({
    required this.repoRoot,
    required this.dir,
    required this.branch,
    required this.commit,
    required this.tree,
  });

  final String repoRoot;

  /// The folder the session works in (the project, maybe below the root).
  final String dir;
  final String branch;
  final String commit;
  final String tree;

  /// A read-only view for diffing and reverting hunks against the snapshot.
  /// Never pass it to anything that commits, merges or removes worktrees.
  SessionWorktree get diffView =>
      SessionWorktree(repoRoot: repoRoot, path: dir, branch: branch, baseBranch: branch, baseCommit: tree);

  factory GitBaseline.fromJson(Map<String, Object?> json) => GitBaseline(
    repoRoot: json['repo_root']! as String,
    dir: json['dir']! as String,
    branch: json['branch'] as String? ?? '',
    commit: json['commit'] as String? ?? '',
    tree: json['tree']! as String,
  );

  Map<String, Object?> toJson() => {
    'repo_root': repoRoot,
    'dir': dir,
    'branch': branch,
    'commit': commit,
    'tree': tree,
  };
}

/// What happened to a file since the session's base commit.
enum ChangeKind {
  added('A'),
  modified('M'),
  deleted('D'),
  renamed('R');

  const ChangeKind(this.letter);
  final String letter;
}

@immutable
final class FileChange {
  const FileChange(this.path, this.kind, {this.added = 0, this.removed = 0});
  final String path;
  final ChangeKind kind;
  final int added;
  final int removed;
}

/// One `@@` hunk of a unified diff.
@immutable
final class DiffHunk {
  const DiffHunk({required this.header, required this.oldStart, required this.newStart, required this.lines});

  /// The `@@ -a,b +c,d @@ context` line.
  final String header;
  final int oldStart;
  final int newStart;

  /// Lines with their ' ', '+' or '-' prefix (and `\ No newline` markers).
  final List<String> lines;

  int get added => lines.where((l) => l.startsWith('+')).length;
  int get removed => lines.where((l) => l.startsWith('-')).length;
}

/// The diff of one file: its `diff --git` header lines and hunks.
@immutable
final class FileDiff {
  const FileDiff({required this.path, required this.header, required this.hunks, this.binary = false});

  final String path;

  /// Everything before the first hunk (`diff --git`, index, ---/+++ lines).
  final List<String> header;
  final List<DiffHunk> hunks;
  final bool binary;

  ChangeKind get kind => header.any((l) => l.startsWith('new file mode'))
      ? ChangeKind.added
      : header.any((l) => l.startsWith('deleted file mode'))
      ? ChangeKind.deleted
      : header.any((l) => l.startsWith('rename from'))
      ? ChangeKind.renamed
      : ChangeKind.modified;

  int get added => hunks.fold(0, (n, h) => n + h.added);
  int get removed => hunks.fold(0, (n, h) => n + h.removed);

  /// A patch with only hunk [i], for `git apply`.
  String patchFor(int i) => '${[...header, hunks[i].header, ...hunks[i].lines].join('\n')}\n';
}

final _hunkHeader = RegExp(r'^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@');

/// Splits `git diff` output into per-file diffs.
List<FileDiff> parseUnifiedDiff(String diff) {
  final files = <FileDiff>[];
  List<String>? header;
  var hunks = <DiffHunk>[];
  String? hunkHeader;
  var oldStart = 0, newStart = 0;
  var lines = <String>[];
  var path = '';
  var binary = false;

  void endHunk() {
    if (hunkHeader != null) {
      hunks.add(DiffHunk(header: hunkHeader!, oldStart: oldStart, newStart: newStart, lines: lines));
    }
    hunkHeader = null;
    lines = <String>[];
  }

  void endFile() {
    endHunk();
    if (header != null) files.add(FileDiff(path: path, header: header!, hunks: hunks, binary: binary));
    header = null;
    hunks = <DiffHunk>[];
    binary = false;
  }

  for (final line in diff.split('\n')) {
    if (line.startsWith('diff --git ')) {
      endFile();
      header = [line];
      // "diff --git a/x b/x": the b/ side is the current path.
      final b = line.lastIndexOf(' b/');
      path = b >= 0 ? line.substring(b + 3) : line;
      continue;
    }
    if (header == null) continue;
    final m = _hunkHeader.firstMatch(line);
    if (m != null) {
      endHunk();
      hunkHeader = line;
      oldStart = int.parse(m.group(1)!);
      newStart = int.parse(m.group(2)!);
      continue;
    }
    if (hunkHeader != null) {
      if (line.isEmpty) continue;
      lines.add(line);
    } else {
      if (line.startsWith('Binary files ')) binary = true;
      if (line.startsWith('+++ ') && !line.startsWith('+++ /dev/null')) {
        path = line.substring(4).replaceFirst(RegExp(r'^b/'), '');
      }
      header!.add(line);
    }
  }
  endFile();
  return files;
}

/// A branch-safe slug for a session: a few words of its title and a short id.
String sessionSlug(String title, String id) {
  final words = title
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .trim()
      .split(' ')
      .where((w) => w.isNotEmpty)
      .take(5)
      .join('-');
  final short = id.replaceAll('-', '');
  final tail = short.substring(short.length - 6);
  return words.isEmpty ? tail : '${words.length > 40 ? words.substring(0, 40) : words}-$tail';
}

/// Lines that credit an AI tool, which the commit-msg hook removes:
/// Co-authored-by/Signed-off-by trailers naming one, and "Generated with"
/// lines.
final brandingLine = RegExp(
  r'^\s*(co-authored-by|signed-off-by)\s*:.*(openhands|all-hands|claude|anthropic|everyai|openai|chatgpt|gpt-|copilot|cursor|gemini|codex|\[bot\])'
  r'|generated (with|by) .*(openhands|claude|everyai|copilot|chatgpt|codex|cursor|gemini)'
  '|🤖',
  caseSensitive: false,
);

/// [message] without AI-credit lines, and without the blank lines they leave
/// at the end.
String stripBranding(String message) {
  final kept = [
    for (final l in message.split('\n'))
      if (!brandingLine.hasMatch(l)) l,
  ];
  while (kept.isNotEmpty && kept.last.trim().isEmpty) {
    kept.removeLast();
  }
  return '${kept.join('\n')}\n';
}

/// A fork's own copy of its parent's folder: a detached worktree at [root],
/// made from a snapshot ([base]) of the parent's working tree, uncommitted
/// and untracked files included. [path] is the parent's folder inside it.
@immutable
final class ForkCopy {
  const ForkCopy({
    required this.repoRoot,
    required this.root,
    required this.path,
    required this.base,
    this.links = const [],
  });

  /// The parent's repository (where the changes are merged back).
  final String repoRoot;
  final String root;
  final String path;
  final String base;

  /// Dependency folders linked in from the parent (node_modules, .venv):
  /// never committed or merged.
  final List<String> links;

  Map<String, Object?> toJson() => {'repo_root': repoRoot, 'root': root, 'path': path, 'base': base, 'links': links};

  static ForkCopy? fromJson(Object? j) => switch (j) {
    {'repo_root': final String r, 'root': final String root, 'path': final String p, 'base': final String b} =>
      ForkCopy(
        repoRoot: r,
        root: root,
        path: p,
        base: b,
        links: [for (final l in j['links'] as List<Object?>? ?? const []) '$l'],
      ),
    _ => null,
  };
}

/// What merging a fork back did: files brought over cleanly, files where
/// both sides changed the same lines (left with conflict markers, or the
/// parent's version kept when they can't be merged as text), and the ref
/// that keeps the fork's work either way.
typedef ForkMerge = ({List<String> merged, List<String> conflicts, String ref});

/// A branch's open pull request.
typedef OpenPr = ({int number, String url});

/// The open pull request in `gh pr view --json number,url,state` output; null for a merged or closed one, or
/// output that isn't that JSON.
OpenPr? parsePrView(String stdout) {
  try {
    return switch (jsonDecode(stdout)) {
      {'number': final int number, 'url': final String url, 'state': 'OPEN'} => (number: number, url: url),
      _ => null,
    };
  } on FormatException {
    return null;
  }
}
