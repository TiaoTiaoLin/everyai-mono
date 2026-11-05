import 'package:flutter/foundation.dart';

import '../../harness/harness.dart' show ContextKind, ContextPart;

/// Tokens in [text], estimated from its length (characters / 4, as compaction estimates them). No tokenizer.
int estimateTokens(String text) => (text.length / 4).ceil();

/// One row of Session info's context breakdown. [estimated] rows are sized from text length and show "≈"; the
/// others are real numbers the harness reported, or settings.
@immutable
final class ContextRow {
  const ContextRow(this.label, this.tokens, {this.estimated = false, this.note, this.children = const []});

  final String label;
  final int tokens;
  final bool estimated;

  /// What the row is, when the label alone doesn't say ("the rest of what was used").
  final String? note;

  /// The row's parts, by name (MCP tools by server).
  final List<({String name, int tokens})> children;
}

/// The context breakdown: [used] and [limit] are real (the last call's tokens and the model's window; 0: not
/// reported), [rows] what can be said about them.
typedef ContextBreakdown = ({int used, int limit, List<ContextRow> rows});

/// Splits [used] tokens of a [limit]-token window into what we can measure ([parts], each an estimate), the rest
/// as one row named for what it is, then the autocompact buffer ([autoCompactPercent], EveryAI only; 0: off) and
/// the free space. An [outside] lead's own prompt and tools are its business: the rest is "Harness (not itemised)".
/// Kinds a session can't tell us (deferred tools, an outside lead's custom agents) have no row, rather than a guess.
ContextBreakdown contextRows({
  required int used,
  required int limit,
  required List<ContextPart> parts,
  required bool outside,
  int autoCompactPercent = 0,
}) {
  final rows = <ContextRow>[];
  var measured = 0;
  for (final kind in ContextKind.values) {
    final mine = [
      for (final p in parts)
        if (p.kind == kind) p,
    ];
    if (mine.isEmpty) continue;
    final tokens = mine.fold(0, (n, p) => n + estimateTokens(p.text));
    measured += tokens;
    final byName = <String, int>{};
    if (kind == ContextKind.mcpTools) {
      for (final p in mine) {
        byName.update(p.name ?? 'MCP', (n) => n + estimateTokens(p.text), ifAbsent: () => estimateTokens(p.text));
      }
    }
    rows.add(
      ContextRow(
        kind.label,
        tokens,
        estimated: true,
        children: [for (final e in byName.entries) (name: e.key, tokens: e.value)],
      ),
    );
  }
  if (used > 0) {
    rows.add(
      ContextRow(
        outside ? 'Harness (not itemised)' : 'Messages and tool results',
        (used - measured).clamp(0, used),
        estimated: true,
        note: 'The rest of what the last call used',
      ),
    );
  }
  var buffer = 0;
  if (!outside && limit > 0 && autoCompactPercent > 0) {
    buffer = (limit * (100 - autoCompactPercent) / 100).round();
    rows.add(ContextRow('Autocompact buffer', buffer, note: 'Compaction starts at $autoCompactPercent% of the window'));
  }
  if (limit > 0) rows.add(ContextRow('Free space', (limit - used - buffer).clamp(0, limit)));
  return (used: used, limit: limit, rows: rows);
}
