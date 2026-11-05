// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

// The `apply_patch` tool's patch format (the "V4A" envelope OpenAI's models
// are trained to write), parsed and applied by our own code:
//
//   *** Begin Patch
//   *** Add File: path/new.py
//   +line
//   *** Update File: path/old.py
//   *** Move to: path/renamed.py        (optional)
//   @@ def some_function():             (optional anchor: a line above the change)
//    context line
//   -removed line
//   +added line
//   *** Delete File: path/gone.py
//   *** End Patch
//
// Context lines are matched exactly first, then ignoring trailing
// whitespace, then ignoring indentation, so a patch written from a slightly
// stale memory of the file still lands where it was meant to.

import '../../../../core/security/untrusted.dart';
import 'untrusted_tools.dart' show keepHidden;

/// One file change in a patch.
sealed class PatchOp {
  const PatchOp(this.path);

  /// As written in the patch (relative or absolute).
  final String path;
}

final class AddFile extends PatchOp {
  const AddFile(super.path, this.content);
  final String content;
}

final class DeleteFile extends PatchOp {
  const DeleteFile(super.path);
}

final class UpdateFile extends PatchOp {
  const UpdateFile(super.path, this.hunks, {this.moveTo});
  final List<PatchHunk> hunks;
  final String? moveTo;
}

/// One `@@` section: the lines it expects ([before]) and what replaces them.
final class PatchHunk {
  const PatchHunk({this.anchor = '', required this.before, required this.after, this.atEnd = false});

  /// The text after `@@`: a line at or above the change that places it.
  final String anchor;
  final List<String> before;
  final List<String> after;

  /// Marked `*** End of File`: the change is at the end of the file.
  final bool atEnd;
}

final class PatchError implements Exception {
  const PatchError(this.message);
  final String message;

  @override
  String toString() => message;
}

const _begin = '*** Begin Patch';
const _end = '*** End Patch';
const _add = '*** Add File: ';
const _delete = '*** Delete File: ';
const _update = '*** Update File: ';
const _move = '*** Move to: ';
const _eof = '*** End of File';

/// The file changes in [patch], in order. Throws [PatchError] when it isn't
/// a well-formed patch.
List<PatchOp> parsePatch(String patch) {
  final lines = patch.replaceAll('\r\n', '\n').split('\n');
  // Some models wrap the patch in a heredoc or code fence; take what is between the markers.
  final start = lines.indexWhere((l) => l.trim() == _begin);
  if (start < 0) throw const PatchError('The patch must start with "*** Begin Patch".');
  final end = lines.lastIndexWhere((l) => l.trim() == _end);
  if (end <= start) throw const PatchError('The patch must end with "*** End Patch".');
  final body = lines.sublist(start + 1, end);
  final ops = <PatchOp>[];
  var i = 0;
  while (i < body.length) {
    final line = body[i];
    if (line.trim().isEmpty) {
      i++;
      continue;
    }
    if (line.startsWith(_add)) {
      final path = line.substring(_add.length).trim();
      final content = <String>[];
      i++;
      while (i < body.length && !body[i].startsWith('*** ')) {
        final l = body[i];
        if (!l.startsWith('+')) {
          throw PatchError('In "Add File: $path", every line must start with "+" (found "${_short(l)}").');
        }
        content.add(l.substring(1));
        i++;
      }
      ops.add(AddFile(_need(path, 'Add File'), content.isEmpty ? '' : '${content.join('\n')}\n'));
    } else if (line.startsWith(_delete)) {
      ops.add(DeleteFile(_need(line.substring(_delete.length).trim(), 'Delete File')));
      i++;
    } else if (line.startsWith(_update)) {
      final path = _need(line.substring(_update.length).trim(), 'Update File');
      i++;
      String? moveTo;
      if (i < body.length && body[i].startsWith(_move)) {
        moveTo = _need(body[i].substring(_move.length).trim(), 'Move to');
        i++;
      }
      final hunks = <PatchHunk>[];
      var anchor = '';
      var before = <String>[];
      var after = <String>[];
      var changed = false;
      var atEnd = false;
      void flush() {
        if (before.isNotEmpty || after.isNotEmpty) {
          if (!changed) throw PatchError('A hunk in "Update File: $path" has no - or + lines.');
          hunks.add(PatchHunk(anchor: anchor, before: before, after: after, atEnd: atEnd));
        }
        anchor = '';
        before = <String>[];
        after = <String>[];
        changed = false;
        atEnd = false;
      }

      while (i < body.length && !(body[i].startsWith('*** ') && body[i].trim() != _eof)) {
        final l = body[i];
        if (l.trim() == _eof) {
          atEnd = true;
        } else if (l.startsWith('@@')) {
          flush();
          anchor = l.substring(2).trim();
        } else if (l.startsWith('-')) {
          before.add(l.substring(1));
          changed = true;
        } else if (l.startsWith('+')) {
          after.add(l.substring(1));
          changed = true;
        } else {
          // Context: " line", or a bare empty line for an empty one.
          final text = l.startsWith(' ') ? l.substring(1) : l;
          before.add(text);
          after.add(text);
        }
        i++;
      }
      flush();
      if (hunks.isEmpty && moveTo == null) throw PatchError('"Update File: $path" has no changes.');
      ops.add(UpdateFile(path, hunks, moveTo: moveTo));
    } else {
      throw PatchError(
        'Unexpected line "${_short(line)}": each change starts with "*** Add File:", "*** Update File:" or '
        '"*** Delete File:".',
      );
    }
  }
  if (ops.isEmpty) throw const PatchError('The patch has no changes.');
  return ops;
}

String _need(String path, String what) {
  if (path.isEmpty) throw PatchError('"$what" needs a path.');
  return path;
}

String _short(String s) => s.length > 80 ? '${s.substring(0, 80)}…' : s;

/// [text] with [hunks] applied, in order. Throws [PatchError] naming the hunk
/// whose context can't be found.
String applyHunks(String text, List<PatchHunk> hunks, {String path = ''}) {
  final trailingNewline = text.endsWith('\n');
  final lines = text.isEmpty ? <String>[] : (trailingNewline ? text.substring(0, text.length - 1) : text).split('\n');
  var cursor = 0;
  for (final h in hunks) {
    if (h.anchor.isNotEmpty) {
      final at = _find(lines, [h.anchor], cursor) ?? _findContaining(lines, h.anchor, cursor);
      if (at == null) throw PatchError('In $path, the @@ line "${_short(h.anchor)}" was not found.');
      // The anchor is above the change; if the hunk's own context starts with it, it is the first line.
      cursor = _sameLine(lines[at], h.before.firstOrNull ?? '\u0000') ? at : at + 1;
    }
    final int at;
    if (h.before.isEmpty) {
      // Only added lines: after the anchor, else at the end of the file.
      at = h.anchor.isNotEmpty && !h.atEnd ? cursor : lines.length;
    } else {
      final found = h.atEnd
          ? _find(lines, h.before, (lines.length - h.before.length).clamp(0, lines.length))
          : _find(lines, h.before, cursor) ?? _uniqueFrom(lines, h.before);
      if (found == null) {
        throw PatchError(
          'In $path, these lines were not found${h.anchor.isEmpty ? '' : ' after "${_short(h.anchor)}"'}:\n'
          '${h.before.take(6).join('\n')}${h.before.length > 6 ? '\n…' : ''}\n'
          'Read the file again and copy the context lines exactly.',
        );
      }
      at = found;
    }
    lines.replaceRange(at, at + h.before.length, keepHidden(lines.sublist(at, at + h.before.length), h.after));
    cursor = at + h.after.length;
  }
  if (lines.isEmpty) return '';
  return '${lines.join('\n')}${trailingNewline || text.isEmpty ? '\n' : ''}';
}

bool _sameLine(String a, String b) =>
    a == b || a.trimRight() == b.trimRight() || a.trim() == b.trim() || stripHidden(a).trim() == stripHidden(b).trim();

/// Where [want] starts in [lines] at or after [from]: exact, then ignoring
/// trailing whitespace, then ignoring all surrounding whitespace, then also
/// hidden characters (read leaves them out of what the model saw).
int? _find(List<String> lines, List<String> want, int from) {
  for (final same in <bool Function(String, String)>[
    (a, b) => a == b,
    (a, b) => a.trimRight() == b.trimRight(),
    (a, b) => a.trim() == b.trim(),
    (a, b) => stripHidden(a).trim() == stripHidden(b).trim(),
  ]) {
    for (var i = from; i + want.length <= lines.length; i++) {
      var ok = true;
      for (var j = 0; j < want.length; j++) {
        if (!same(lines[i + j], want[j])) {
          ok = false;
          break;
        }
      }
      if (ok) return i;
    }
  }
  return null;
}

/// [want] anywhere in the file, when it occurs exactly once (a hunk written
/// out of order).
int? _uniqueFrom(List<String> lines, List<String> want) {
  final first = _find(lines, want, 0);
  if (first == null) return null;
  return _find(lines, want, first + 1) == null ? first : null;
}

int? _findContaining(List<String> lines, String anchor, int from) {
  final a = stripHidden(anchor).trim();
  for (var i = from; i < lines.length; i++) {
    if (stripHidden(lines[i]).contains(a)) return i;
  }
  return null;
}
