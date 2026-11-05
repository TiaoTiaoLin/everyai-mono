// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import '../../../../core/security/untrusted.dart';
import '../../domain/permissions.dart' show commandParts;

// What the tools do with text the user didn't write (see core/security/
// untrusted.dart): content from outside (the web, other people's commit
// messages, files outside the project) goes in an untrusted block; the
// user's own files and command output only lose their hidden characters,
// with a note saying so. Never conditional on the mode.

/// Programs whose output is text from the network.
const _networkPrograms = {'curl', 'wget', 'gh', 'http', 'https', 'xh', 'lynx', 'w3m', 'aria2c'};

/// git subcommands that print text written by others (commit messages, remote output).
const _gitOthersText = {'log', 'show', 'blame', 'fetch', 'pull', 'clone'};

/// git options that take the next word as their value.
const _gitValueOptions = {'-C', '-c', '--git-dir', '--work-tree', '--namespace', '--exec-path'};

/// The source to mark [command]'s output with when it prints text from
/// outside the user (`command output: curl`, `command output: git log`), or
/// null for other commands. Best-effort: a script that fetches on its own
/// (`python -c …`, `node …`) isn't recognised.
String? untrustedCommand(String command) {
  for (final part in commandParts(command)) {
    final words = part.split(' ');
    final program = words.first.split('/').last;
    if (_networkPrograms.contains(program)) return 'command output: $program';
    if (program != 'git') continue;
    for (var i = 1; i < words.length; i++) {
      final w = words[i];
      if (_gitValueOptions.contains(w)) {
        i++;
      } else if (!w.startsWith('-')) {
        if (_gitOthersText.contains(w)) return 'command output: git $w';
        break;
      }
    }
  }
  return null;
}

/// The labels of [kinds], for a note.
String hiddenLabels(Set<HiddenKind> kinds) => kinds.map((k) => k.label).join(', ');

/// [text] without hidden characters and, when any were removed, a note in
/// front naming them ([what]: what the text is). The user's own text: the
/// characters ordinary writing uses stay (see `stripHidden`'s `keepWriting`).
/// Clean text comes back as it is.
String stripHiddenNoted(String text, {String what = 'the output'}) {
  final hidden = hiddenIn(text, keepWriting: true);
  if (hidden.isEmpty) return text;
  return '[Hidden characters removed from $what: ${hiddenLabels(hidden)}.]\n${stripHidden(text, keepWriting: true)}';
}

/// [replacement] for [original] lines, where every new line that equals an
/// original line with its hidden characters removed keeps that original line.
/// The model saw the lines stripped (read removes the hidden characters
/// ordinary text never needs), so a line it copied unchanged keeps what it
/// had; only lines it rewrote lose them. A copy that also lost the writing
/// marks (an emoji joiner, a direction mark) still counts as unchanged.
List<String> keepHidden(List<String> original, List<String> replacement) {
  // Stripped text → the original lines that strip to it, in order (each kept once).
  final left = <String, List<int>>{};
  for (var i = 0; i < original.length; i++) {
    final l = original[i];
    for (final s in {stripHidden(l, keepWriting: true), stripHidden(l)}) {
      if (s != l) (left[s] ??= []).add(i);
    }
  }
  if (left.isEmpty) return replacement;
  final used = <int>{};
  final out = <String>[];
  for (final line in replacement) {
    final i = left[line]?.where((i) => !used.contains(i)).firstOrNull;
    if (i == null) {
      out.add(line);
    } else {
      used.add(i);
      out.add(original[i]);
    }
  }
  return out;
}

/// Folders inside a project that hold other people's code (dependencies).
const _dependencyFolders = {'node_modules', 'vendor', 'Pods', '.venv', 'site-packages', '.pub-cache', '.cargo'};

/// Folders under `.everyai/` that hold text from outside: spilled tool output, other agents' transcripts, research
/// notes and downloads.
const _outsideNotes = {'spill', 'handoffs', 'scratch'};

/// Whether [path] (absolute, normalised) is outside the user's own files in
/// [root]: elsewhere on the machine, in a dependency folder, or in one of
/// EveryAI's folders of outside text. Folders in [own] (the session's skills,
/// which the prompt tells the model to follow) count as the user's.
bool outsideProject(String root, String path, {Iterable<String> own = const []}) {
  if (own.any((d) => path == d || path.startsWith('$d/'))) return false;
  if (!path.startsWith('$root/')) return path != root;
  final parts = path.substring(root.length + 1).split('/');
  if (parts.length > 2 && parts.first == '.everyai' && _outsideNotes.contains(parts[1])) return true;
  return parts.take(parts.length - 1).any(_dependencyFolders.contains);
}

/// The folders of [skills] (SessionSpec.skills, whose `source` is a SKILL.md path).
List<String> skillFolders(List<Map<String, Object?>> skills) => [
  for (final s in skills)
    if (s['source'] case final String p when p.endsWith('/SKILL.md')) p.substring(0, p.length - '/SKILL.md'.length),
];
