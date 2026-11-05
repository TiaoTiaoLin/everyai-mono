import 'dart:convert';

import '../harness/events.dart';

/// Output above either limit is shown as a preview, with the whole text saved
/// to a file under `.everyai/spill/` that can be read in parts.
const spillMaxLines = 2000;
const spillMaxBytes = 50 * 1024;
const spillDir = '.everyai/spill';

/// Lines kept from the start and the end of a spilled result.
const _headLines = 60;
const _tailLines = 20;
const _previewBytes = 12 * 1024;

/// A result too long to show whole.
final class Spill {
  const Spill({required this.text, required this.lines, required this.bytes});
  final String text;
  final int lines;
  final int bytes;

  /// The saved file's name for the result [id].
  static String fileName(String id) => '${id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}.txt';
}

/// The result's text when it is over the limits, else null.
Spill? spillOf(ToolResult r) => spillText(r.text);

/// [text] when it is over the limits, else null.
Spill? spillText(String text) {
  final bytes = utf8.encode(text).length;
  final lines = '\n'.allMatches(text).length + 1;
  if (lines <= spillMaxLines && bytes <= spillMaxBytes) return null;
  return Spill(text: text, lines: lines, bytes: bytes);
}

/// The first and last lines of [spill], with a line saying where the rest is.
/// [wrap] (an untrusted block, say) goes around the head and the tail each,
/// so our note stays outside it.
String spillPreview(Spill spill, String path, {String Function(String part)? wrap}) {
  final all = spill.text.split('\n');
  final head = all.take(_headLines).toList();
  final tail = all.length > _headLines + _tailLines ? all.sublist(all.length - _tailLines) : const <String>[];
  var h = head.join('\n');
  if (h.length > _previewBytes) h = h.substring(0, _previewBytes);
  var t = tail.join('\n');
  if (t.length > _previewBytes) t = t.substring(t.length - _previewBytes);
  final omitted = spill.lines - head.length - tail.length;
  final kb = (spill.bytes / 1024).round();
  return [
    wrap == null ? h : wrap(h),
    '… ${omitted > 0 ? '$omitted lines' : 'the rest'} omitted. Full output ($kb KB, ${spill.lines} lines) saved to '
        '$path; read it in parts with sed -n, head, tail or grep …',
    if (t.isNotEmpty) wrap == null ? t : wrap(t),
  ].join('\n');
}

/// [r] with its content replaced by [preview].
ToolResult withPreview(ToolResult r, String preview) => ToolResult(
  id: r.id,
  raw: r.raw,
  actionId: r.actionId,
  toolCallId: r.toolCallId,
  toolName: r.toolName,
  outcome: r.outcome,
  observation: {
    ...r.observation,
    'content': [
      {'type': 'text', 'text': preview},
    ],
  },
);
